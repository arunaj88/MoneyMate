import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/notification_cloud.dart';
import 'package:money_mate/core/services/notification_events.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';

/// Push and on-device notifications.
///
/// * Registers this installation for pushes (FCM token, currency and which
///   pushes it wants) at users/{uid}/devices/{deviceId} while signed in and
///   notifications are allowed, and removes the registration on sign-out.
/// * Shows pushes that arrive while the app is open (the system shows them
///   when it is in the background).
/// * Shows budget alerts and automatically added recurring transactions as
///   system notifications, and hands shared budget alerts to the cloud so
///   the other household members are told.
///
/// Without [push] (desktop builds, tests) only local notifications work.
class NotificationProvider extends ChangeNotifier
    implements BudgetAlertSink, RecurringSink {
  NotificationProvider({
    required SharedPreferences preferences,
    PushMessaging? push,
    LocalNotifier local = const NoopLocalNotifier(),
    NotificationCloud? cloud,
    Uuid uuid = const Uuid(),
  }) : _prefs = preferences,
       _push = push,
       _local = local,
       _cloud = cloud,
       _uuid = uuid {
    _start();
  }

  final SharedPreferences _prefs;
  final PushMessaging? _push;
  final LocalNotifier _local;
  final NotificationCloud? _cloud;
  final Uuid _uuid;

  final List<StreamSubscription<Object>> _subscriptions = [];
  AuthProvider? _auth;
  SettingsProvider? _settings;
  CategoryProvider? _categories;

  NotificationPermission _permission = NotificationPermission.unsupported;
  bool _permissionKnown = false;
  String? _token;
  DeviceRegistration? _registered;
  Future<void> _queue = Future.value();
  bool _disposed = false;

  /// Whether pushes can work on this platform.
  bool get pushSupported => _push != null;

  NotificationPermission get permission => _permission;

  // ------------------------------------------------------------ wiring

  void _start() {
    final push = _push;
    if (push == null) return;
    _subscriptions
      ..add(
        push.foregroundMessages.listen(
          (n) => unawaited(_local.show(n)),
          onError: (Object e) => debugPrint('Foreground push error: $e'),
        ),
      )
      ..add(
        push.tokenRefreshes.listen((token) {
          _token = token;
          _scheduleSync();
        }, onError: (Object e) => debugPrint('Token refresh error: $e')),
      );
    _serialised(() async {
      _permission = await push.permission();
      _permissionKnown = true;
      _notify();
    });
  }

  /// Called by the ProxyProvider whenever auth, settings or categories
  /// change.
  void attach(
    AuthProvider auth,
    SettingsProvider settings,
    CategoryProvider categories,
  ) {
    if (!identical(auth, _auth)) {
      _auth?.removeSignOutHook(_beforeSignOut);
      auth.addSignOutHook(_beforeSignOut);
    }
    _auth = auth;
    _settings = settings;
    _categories = categories;
    _scheduleSync();
  }

  /// Asks the system for permission (Android 13+ / iOS). Returns the
  /// resulting permission.
  Future<NotificationPermission> requestPermission() async {
    final push = _push;
    if (push == null) return NotificationPermission.unsupported;
    await _prefs.setBool(PrefKeys.notificationPermissionAsked, true);
    _permission = await push.requestPermission();
    _permissionKnown = true;
    _notify();
    _scheduleSync();
    return _permission;
  }

  /// Re-reads the permission, e.g. after the user returns from the system
  /// settings.
  Future<void> refreshPermission() async {
    final push = _push;
    if (push == null) return;
    final value = await push.permission();
    if (value == _permission && _permissionKnown) return;
    _permission = value;
    _permissionKnown = true;
    _notify();
    _scheduleSync();
  }

  // ------------------------------------------------------ registration

  void _scheduleSync() {
    if (_disposed) return;
    _serialised(_sync);
  }

  Future<void> _sync() async {
    final push = _push;
    final cloud = _cloud;
    final uid = _auth?.isAuthenticated == true ? _auth!.user?.uid : null;
    final settings = _settings;
    if (push == null || cloud == null || settings == null) return;

    // A registration left behind for another account (sign-out offline).
    final previousUid = _prefs.getString(PrefKeys.notificationRegisteredUid);
    if (previousUid != null && previousUid != uid && uid != null) {
      await _unregister(previousUid);
    }
    if (uid == null || !_permissionKnown) return;

    // Ask once, the first time someone signed in uses the app.
    if (_permission == NotificationPermission.notDetermined &&
        _prefs.getBool(PrefKeys.notificationPermissionAsked) != true) {
      await _prefs.setBool(PrefKeys.notificationPermissionAsked, true);
      _permission = await push.requestPermission();
      _notify();
    }
    if (!_permission.isGranted) {
      if (previousUid == uid) await _unregister(uid);
      return;
    }

    final token = _token ??= await push.token();
    if (token == null) return;
    final registration = DeviceRegistration(
      deviceId: _deviceId(),
      token: token,
      platform: push.platform,
      currencyCode: settings.currencyCode,
      householdActivity: settings.householdActivityNotifications,
      householdBudgets: settings.householdBudgetNotifications,
      savingsUpdates: settings.savingsNotifications,
    );
    if (registration == _registered && previousUid == uid) return;
    try {
      await cloud.register(uid, registration);
      _registered = registration;
      await _prefs.setString(PrefKeys.notificationRegisteredUid, uid);
    } catch (e) {
      // Offline, or rules not deployed yet: retried on the next change or
      // start-up.
      debugPrint('Push registration failed: $e');
    }
  }

  Future<void> _unregister(String uid) async {
    try {
      await _cloud?.unregister(uid, _deviceId());
    } catch (e) {
      // The token is rotated on sign-out anyway, so a registration left
      // behind only ever points at a dead token (removed by the server).
      debugPrint('Push unregistration failed: $e');
    }
    _registered = null;
    if (_prefs.getString(PrefKeys.notificationRegisteredUid) == uid) {
      await _prefs.remove(PrefKeys.notificationRegisteredUid);
    }
  }

  /// Runs while still signed in, so the registration can be deleted.
  Future<void> _beforeSignOut(String uid) => _serialised(() async {
    if (_push == null) return;
    await _unregister(uid);
    await _push.deleteToken();
    _token = null;
  });

  String _deviceId() {
    final existing = _prefs.getString(PrefKeys.notificationDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _uuid.v4().replaceAll('-', '');
    unawaited(_prefs.setString(PrefKeys.notificationDeviceId, id));
    return id;
  }

  // ------------------------------------------------- local notifications

  @override
  Future<void> budgetAlertRaised(BudgetAlertEvent event) async {
    final alert = event.local;
    final household = event.household;
    if (alert != null) {
      await _safeShow(
        AppNotification(
          title: household == null
              ? alert.title
              : 'Household ${_lower(alert.title)}',
          body: alert.message,
          channel: NotificationChannel.budgetAlerts,
          // A higher level for the same budget and period replaces it.
          tag: 'budget-${household?.key ?? alert.key}',
        ),
      );
    }
    final uid = _auth?.user?.uid;
    if (household != null && uid != null) {
      await _cloud?.publishBudgetAlert(
        household,
        uid: uid,
        userName: _auth?.user?.name,
      );
    }
  }

  @override
  Future<void> recurringAdded(List<RecurringAddition> additions) async {
    final settings = _settings;
    final relevant = additions.where((a) => a.count > 0).toList();
    if (settings == null || relevant.isEmpty) return;
    if (!settings.recurringNotifications) return;
    final total = relevant.fold<int>(0, (sum, a) => sum + a.count);
    String describe(RecurringAddition a) {
      final rule = a.rule;
      final label = rule.note.isNotEmpty
          ? rule.note
          : _categories?.byIdOrNull(rule.categoryId)?.name ??
                (rule.type == TransactionType.income ? 'Income' : 'Expense');
      final amount = settings.formatter.format(rule.amountMinor);
      final signed = rule.type == TransactionType.income ? '+$amount' : amount;
      final shared = rule.isShared ? ' (household)' : '';
      return a.count > 1
          ? '$label$shared · $signed × ${a.count}'
          : '$label$shared · $signed';
    }

    final single = relevant.length == 1 && total == 1;
    await _safeShow(
      AppNotification(
        title: single
            ? 'Recurring ${relevant.first.rule.type == TransactionType.income ? 'income' : 'expense'} added'
            : '$total recurring transactions added',
        body: relevant.map(describe).join('\n'),
        channel: NotificationChannel.recurring,
      ),
    );
  }

  Future<void> _safeShow(AppNotification n) async {
    try {
      await _local.show(n);
    } catch (e) {
      debugPrint('Notification not shown: $e');
    }
  }

  static String _lower(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  // -------------------------------------------------------------- misc

  Future<void> _serialised(Future<void> Function() action) {
    final result = _queue.then((_) => _disposed ? null : action());
    _queue = result.then<void>(
      (_) {},
      onError: (Object e) => debugPrint('Notifications: $e'),
    );
    return _queue;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _auth?.removeSignOutHook(_beforeSignOut);
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    super.dispose();
  }
}
