import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import 'package:money_mate/models/scope_models.dart';

/// Kinds of notification MoneyMate shows. Each is an Android notification
/// channel, so people can also mute one kind in the system settings. The
/// IDs match the channels the Cloud Functions send to
/// (functions/src/notify_logic.js).
enum NotificationChannel {
  householdActivity(
    'household_activity',
    'Household activity',
    'Shared transactions added, edited or deleted, and members joining '
        'or leaving',
  ),
  budgetAlerts(
    'budget_alerts',
    'Budget alerts',
    'Budgets reaching 80%, 90% and 100%',
  ),
  savingsUpdates(
    'savings_updates',
    'Savings goals',
    'Contributions to shared savings goals and goals reaching their target',
  ),
  recurring(
    'recurring',
    'Recurring transactions',
    'Salary, rent and other repeats added automatically',
  ),
  loanReminders(
    'loan_reminders',
    'Repayment reminders',
    'Money you lent: repayments coming up, due today or overdue',
  );

  const NotificationChannel(this.id, this.label, this.description);

  final String id;
  final String label;
  final String description;

  static NotificationChannel fromId(String? id) => values.firstWhere(
    (c) => c.id == id,
    orElse: () => NotificationChannel.householdActivity,
  );
}

/// One notification to show on this device.
@immutable
class AppNotification {
  const AppNotification({
    required this.title,
    required this.body,
    required this.channel,
    this.tag,
    this.data = const {},
  });

  final String title;
  final String body;
  final NotificationChannel channel;

  /// Notifications with the same tag replace each other (e.g. a budget
  /// going from 90% to 100% in the same period).
  final String? tag;

  /// The push's data (type, householdId, goalId, …): where a tap leads.
  final Map<String, String> data;

  /// What a tap on this notification hands back to the app.
  Map<String, String> get tapData => {...data, 'channel': channel.id};

  @override
  bool operator ==(Object other) =>
      other is AppNotification &&
      other.title == title &&
      other.body == body &&
      other.channel == channel &&
      other.tag == tag &&
      mapEquals(other.data, data);

  @override
  int get hashCode => Object.hash(
    title,
    body,
    channel,
    tag,
    Object.hashAllUnordered(
      data.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  @override
  String toString() => 'AppNotification(${channel.id}, $title: $body)';
}

/// The screens a notification tap can open.
enum NotificationDestination {
  dashboard,
  transactions,
  budget,
  household,
  savings,
  goal,

  /// The money lent overview.
  lending,

  /// One lending record (and instalment).
  loan,
}

/// Where tapping a notification takes the user.
@immutable
class NotificationTarget {
  const NotificationTarget(
    this.destination, {
    this.goalId,
    this.ownership,
    this.scope,
    this.loanId,
    this.installmentId,
  });

  final NotificationDestination destination;

  /// For [NotificationDestination.loan].
  final String? loanId;

  /// The instalment a repayment reminder is about.
  final String? installmentId;

  /// For [NotificationDestination.goal].
  final String? goalId;

  /// Which savings tab to open: 'household' or 'shared'
  /// ([NotificationDestination.savings]).
  final String? ownership;

  /// Whose data to show: the personal view or a household's shared view
  /// (transactions, dashboard and budgets). Null keeps the current view.
  final DataScope? scope;

  /// Reads the data of a tapped notification: the `type` the Cloud
  /// Functions send (functions/src/notifications.js) and, for
  /// notifications made on this device, the channel.
  factory NotificationTarget.fromData(Map<String, String> data) {
    final goalId = data['goalId'];
    final hasGoal = goalId != null && goalId.isNotEmpty;
    final householdId = data['householdId'];
    final household = householdId == null || householdId.isEmpty
        ? null
        : DataScope.household(householdId);
    switch (data['type']) {
      case 'household_transaction':
        return NotificationTarget(
          NotificationDestination.transactions,
          scope: household,
        );
      case 'household_member':
      case 'household_removed':
        return const NotificationTarget(NotificationDestination.household);
      case 'household_budget':
        return NotificationTarget(
          NotificationDestination.budget,
          scope: household,
        );
      case 'personal_budget':
        return const NotificationTarget(
          NotificationDestination.budget,
          scope: DataScope.personal(),
        );
      case 'loan_reminder':
        final loanId = data['loanId'];
        if (loanId == null || loanId.isEmpty) {
          return const NotificationTarget(NotificationDestination.lending);
        }
        final installmentId = data['installmentId'];
        return NotificationTarget(
          NotificationDestination.loan,
          loanId: loanId,
          installmentId: installmentId == null || installmentId.isEmpty
              ? null
              : installmentId,
        );
      case 'household_savings':
      case 'shared_goal':
        return hasGoal
            ? NotificationTarget(NotificationDestination.goal, goalId: goalId)
            : NotificationTarget(
                NotificationDestination.savings,
                ownership: data['type'] == 'shared_goal'
                    ? 'shared'
                    : 'household',
              );
    }
    return switch (NotificationChannel.fromId(data['channel'])) {
      NotificationChannel.budgetAlerts => const NotificationTarget(
        NotificationDestination.budget,
      ),
      NotificationChannel.recurring => const NotificationTarget(
        NotificationDestination.transactions,
      ),
      NotificationChannel.savingsUpdates => const NotificationTarget(
        NotificationDestination.savings,
      ),
      NotificationChannel.householdActivity => const NotificationTarget(
        NotificationDestination.dashboard,
      ),
      NotificationChannel.loanReminders => const NotificationTarget(
        NotificationDestination.lending,
      ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is NotificationTarget &&
      other.destination == destination &&
      other.goalId == goalId &&
      other.ownership == ownership &&
      other.scope == scope &&
      other.loanId == loanId &&
      other.installmentId == installmentId;

  @override
  int get hashCode =>
      Object.hash(destination, goalId, ownership, scope, loanId, installmentId);

  @override
  String toString() =>
      'NotificationTarget(${destination.name}, goal: $goalId, '
      'ownership: $ownership, scope: $scope, loan: $loanId, '
      'installment: $installmentId)';
}

/// Whether the system lets MoneyMate show notifications.
enum NotificationPermission {
  granted,
  denied,

  /// Not asked yet (Android 13+ / iOS).
  notDetermined,

  /// This platform has no push notifications (desktop builds).
  unsupported;

  bool get isGranted => this == NotificationPermission.granted;
}

/// Firebase Cloud Messaging, behind an interface so tests use a fake.
abstract class PushMessaging {
  /// 'android', 'ios', … as stored on the device registration.
  String get platform;

  Future<NotificationPermission> permission();

  /// Shows the system prompt (Android 13+ / iOS) when not decided yet.
  Future<NotificationPermission> requestPermission();

  /// This installation's FCM token, or null when unavailable (no Google
  /// Play services, offline on first start).
  Future<String?> token();

  /// New tokens issued by FCM while the app runs.
  Stream<String> get tokenRefreshes;

  /// Pushes received while the app is in the foreground (also those the
  /// system shows itself, see [showsForegroundPushes]), so the app can
  /// fetch what they are about.
  Stream<AppNotification> get foregroundMessages;

  /// True when the system shows pushes itself while the app is open (iOS,
  /// with the presentation options set); elsewhere the app shows them.
  bool get showsForegroundPushes;

  /// Invalidates this installation's token (on sign-out), so pushes for
  /// the previous account can never reach the device.
  Future<void> deleteToken();

  /// The data of the push whose tap started the app, if one did.
  Future<Map<String, String>?> launchTap();

  /// Taps on pushes the system showed while the app was in the background.
  Stream<Map<String, String>> get taps;
}

/// A notification to show later, at [fireAt] (local wall-clock time).
@immutable
class ScheduledNotification {
  const ScheduledNotification({
    required this.id,
    required this.fireAt,
    required this.notification,
  });

  /// Stable ID: scheduling the same ID again replaces the earlier one.
  final int id;
  final DateTime fireAt;
  final AppNotification notification;

  @override
  bool operator ==(Object other) =>
      other is ScheduledNotification &&
      other.id == id &&
      other.fireAt == fireAt &&
      other.notification == notification;

  @override
  int get hashCode => Object.hash(id, fireAt, notification);
}

/// Shows notifications on this device (flutter_local_notifications).
abstract class LocalNotifier {
  Future<void> show(AppNotification notification);

  /// Schedules [notification]; one with the same ID is replaced. Works
  /// without a connection and while the app is closed; the system keeps it
  /// across restarts.
  Future<void> schedule(ScheduledNotification notification);

  /// Cancels a scheduled notification (nothing happens when there is none).
  Future<void> cancelScheduled(int id);

  /// IDs of scheduled, not yet shown notifications of [channel].
  Future<Set<int>> scheduledIds(NotificationChannel channel);

  /// [AppNotification.tapData] of the notification whose tap started the
  /// app, if one did.
  Future<Map<String, String>?> launchTap();

  /// [AppNotification.tapData] of notifications tapped while the app runs.
  Stream<Map<String, String>> get taps;
}

/// [PushMessaging] backed by Firebase Cloud Messaging (Android and iOS).
class FirebasePushMessaging implements PushMessaging {
  FirebasePushMessaging({FirebaseMessaging? messaging})
    : _messaging = messaging ?? FirebaseMessaging.instance;

  final FirebaseMessaging _messaging;

  // The Cloud Functions send with the Admin SDK to FCM registration tokens,
  // so this uses the token API (deprecated in favour of installation-ID
  // direct send, which the backend does not use).

  /// Push notifications need Google Play services (Android) or APNs (iOS).
  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  String get platform => Platform.isIOS ? 'ios' : 'android';

  static NotificationPermission _map(AuthorizationStatus status) =>
      switch (status) {
        AuthorizationStatus.authorized ||
        AuthorizationStatus.provisional => NotificationPermission.granted,
        AuthorizationStatus.denied ||
        AuthorizationStatus.deniedPermanently => NotificationPermission.denied,
        AuthorizationStatus.notDetermined =>
          NotificationPermission.notDetermined,
      };

  @override
  Future<NotificationPermission> permission() async =>
      _map((await _messaging.getNotificationSettings()).authorizationStatus);

  @override
  Future<NotificationPermission> requestPermission() async {
    final settings = await _messaging.requestPermission();
    if (Platform.isIOS) {
      // Show pushes as banners while the app is open as well.
      await _messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
    return _map(settings.authorizationStatus);
  }

  @override
  Future<String?> token() async {
    try {
      // ignore: deprecated_member_use
      return await _messaging.getToken();
    } catch (e) {
      // No Play services, or FCM unreachable: try again on the next start.
      debugPrint('FCM token unavailable: $e');
      return null;
    }
  }

  @override
  // ignore: deprecated_member_use
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  // iOS shows foreground pushes itself (presentation options above).
  bool get showsForegroundPushes => Platform.isIOS;

  @override
  Stream<AppNotification> get foregroundMessages => FirebaseMessaging.onMessage
      .map(_toNotification)
      .where((n) => n != null)
      .cast<AppNotification>();

  static AppNotification? _toNotification(RemoteMessage message) {
    final n = message.notification;
    if (n == null || (n.title == null && n.body == null)) return null;
    return AppNotification(
      title: n.title ?? '',
      body: n.body ?? '',
      channel: NotificationChannel.fromId(
        message.data['channel'] as String? ?? n.android?.channelId,
      ),
      tag: n.android?.tag,
      data: _stringData(message),
    );
  }

  static Map<String, String> _stringData(RemoteMessage message) => {
    for (final e in message.data.entries)
      if (e.value != null) e.key: e.value.toString(),
  };

  @override
  Future<Map<String, String>?> launchTap() async {
    try {
      final message = await _messaging.getInitialMessage();
      return message == null ? null : _stringData(message);
    } catch (e) {
      debugPrint('Initial push unavailable: $e');
      return null;
    }
  }

  @override
  Stream<Map<String, String>> get taps =>
      FirebaseMessaging.onMessageOpenedApp.map(_stringData);

  @override
  Future<void> deleteToken() async {
    try {
      // ignore: deprecated_member_use
      await _messaging.deleteToken();
    } catch (e) {
      debugPrint('FCM token not deleted: $e');
    }
  }
}

/// [LocalNotifier] backed by flutter_local_notifications.
class SystemLocalNotifier implements LocalNotifier {
  SystemLocalNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  Future<bool>? _ready;
  final _taps = StreamController<Map<String, String>>.broadcast();

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  /// Brand teal (AppTheme.primary), the notification accent on Android.
  static const Color _accent = Color(0xFF0F766E);

  Future<bool> _init() => _ready ??= () async {
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_notify'),
          // Permission is asked by PushMessaging.requestPermission.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final data = decodeTapPayload(response.payload);
          if (data != null) _taps.add(data);
        },
      );
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      for (final c in NotificationChannel.values) {
        await android?.createNotificationChannel(
          AndroidNotificationChannel(
            c.id,
            c.label,
            description: c.description,
            importance: c == NotificationChannel.recurring
                ? Importance.defaultImportance
                : Importance.high,
          ),
        );
      }
      return true;
    } catch (e) {
      debugPrint('Local notifications unavailable: $e');
      return false;
    }
  }();

  /// Creates the Android channels early, so pushes that arrive while the
  /// app is closed use them too.
  Future<void> prepare() => _init();

  @override
  Future<void> show(AppNotification n) async {
    if (!await _init()) return;
    final tag = n.tag;
    await _plugin.show(
      // Same tag, same ID: a newer notification replaces the older one.
      id: (tag ?? '${n.channel.id}:${n.title}:${n.body}').hashCode & 0x7fffffff,
      title: n.title,
      body: n.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          n.channel.id,
          n.channel.label,
          channelDescription: n.channel.description,
          importance: n.channel == NotificationChannel.recurring
              ? Importance.defaultImportance
              : Importance.high,
          priority: n.channel == NotificationChannel.recurring
              ? Priority.defaultPriority
              : Priority.high,
          tag: tag,
          color: _accent,
          styleInformation: BigTextStyleInformation(n.body),
        ),
        iOS: DarwinNotificationDetails(threadIdentifier: n.channel.id),
        macOS: DarwinNotificationDetails(threadIdentifier: n.channel.id),
      ),
      payload: jsonEncode(n.tapData),
    );
  }

  static NotificationDetails _details(AppNotification n) => NotificationDetails(
    android: AndroidNotificationDetails(
      n.channel.id,
      n.channel.label,
      channelDescription: n.channel.description,
      importance: Importance.high,
      priority: Priority.high,
      tag: n.tag,
      color: _accent,
      styleInformation: BigTextStyleInformation(n.body),
    ),
    iOS: DarwinNotificationDetails(threadIdentifier: n.channel.id),
    macOS: DarwinNotificationDetails(threadIdentifier: n.channel.id),
  );

  @override
  Future<void> schedule(ScheduledNotification s) async {
    if (!await _init()) return;
    final n = s.notification;
    // Scheduled as an instant in UTC, worked out from the local wall-clock
    // time when scheduling. Reminders are planned again whenever the app
    // starts or resumes, so a new time zone or a daylight-saving change is
    // picked up then.
    await _plugin.zonedSchedule(
      id: s.id,
      title: n.title,
      body: n.body,
      scheduledDate: tz.TZDateTime.from(s.fireAt.toUtc(), tz.UTC),
      notificationDetails: _details(n),
      // Inexact: no exact-alarm permission is needed, and a reminder a few
      // minutes late is fine.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: jsonEncode(n.tapData),
    );
  }

  @override
  Future<void> cancelScheduled(int id) async {
    if (!await _init()) return;
    await _plugin.cancel(id: id);
  }

  @override
  Future<Set<int>> scheduledIds(NotificationChannel channel) async {
    if (!await _init()) return const {};
    try {
      final pending = await _plugin.pendingNotificationRequests();
      return {
        for (final p in pending)
          if (decodeTapPayload(p.payload)?['channel'] == channel.id) p.id,
      };
    } catch (e) {
      debugPrint('Scheduled notifications unavailable: $e');
      return const {};
    }
  }

  @override
  Future<Map<String, String>?> launchTap() async {
    if (!await _init()) return null;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      return decodeTapPayload(details!.notificationResponse?.payload);
    } catch (e) {
      debugPrint('Notification launch details unavailable: $e');
      return null;
    }
  }

  @override
  Stream<Map<String, String>> get taps => _taps.stream;
}

/// Reads [AppNotification.tapData] back from a local notification's
/// payload. Null when it is missing or not ours.
@visibleForTesting
Map<String, String>? decodeTapPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return null;
    return {
      for (final e in decoded.entries)
        if (e.key is String && e.value != null) e.key as String: '${e.value}',
    };
  } on FormatException {
    return null;
  }
}

/// Used where notifications are not available (desktop, tests).
class NoopLocalNotifier implements LocalNotifier {
  const NoopLocalNotifier();

  @override
  Future<void> show(AppNotification notification) async {}

  @override
  Future<void> schedule(ScheduledNotification notification) async {}

  @override
  Future<void> cancelScheduled(int id) async {}

  @override
  Future<Set<int>> scheduledIds(NotificationChannel channel) async => const {};

  @override
  Future<Map<String, String>?> launchTap() async => null;

  @override
  Stream<Map<String, String>> get taps => const Stream.empty();
}
