import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
  });

  final String title;
  final String body;
  final NotificationChannel channel;

  /// Notifications with the same tag replace each other (e.g. a budget
  /// going from 90% to 100% in the same period).
  final String? tag;

  @override
  bool operator ==(Object other) =>
      other is AppNotification &&
      other.title == title &&
      other.body == body &&
      other.channel == channel &&
      other.tag == tag;

  @override
  int get hashCode => Object.hash(title, body, channel, tag);

  @override
  String toString() => 'AppNotification(${channel.id}, $title: $body)';
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

  /// Pushes received while the app is in the foreground. The system shows
  /// pushes itself only while the app is in the background.
  Stream<AppNotification> get foregroundMessages;

  /// Invalidates this installation's token (on sign-out), so pushes for
  /// the previous account can never reach the device.
  Future<void> deleteToken();
}

/// Shows notifications on this device (flutter_local_notifications).
abstract class LocalNotifier {
  Future<void> show(AppNotification notification);
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
  Stream<AppNotification> get foregroundMessages => FirebaseMessaging.onMessage
      // iOS shows foreground pushes itself (presentation options above).
      .where((_) => !Platform.isIOS)
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
    );
  }

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
    );
  }
}

/// Used where notifications are not available (desktop, tests).
class NoopLocalNotifier implements LocalNotifier {
  const NoopLocalNotifier();

  @override
  Future<void> show(AppNotification notification) async {}
}
