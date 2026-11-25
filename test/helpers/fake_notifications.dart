import 'dart:async';

import 'package:money_mate/core/services/notification_cloud.dart';
import 'package:money_mate/core/services/notification_service.dart';

/// In-memory [PushMessaging]: the permission prompt answers with
/// [answer], and tests push foreground messages and token refreshes.
class FakePushMessaging implements PushMessaging {
  FakePushMessaging({
    this.current = NotificationPermission.notDetermined,
    this.answer = NotificationPermission.granted,
    this.currentToken = 'token-1',
  });

  NotificationPermission current;

  /// What the system prompt returns.
  NotificationPermission answer;
  String? currentToken;
  int prompts = 0;
  int deletedTokens = 0;

  /// The next prompt fails like it does without a visible activity.
  bool failNextPrompt = false;

  /// Like iOS: the system shows foreground pushes itself.
  @override
  bool showsForegroundPushes = false;

  final _messages = StreamController<AppNotification>.broadcast();
  final _tokens = StreamController<String>.broadcast();
  final _taps = StreamController<Map<String, String>>.broadcast();

  /// The push whose tap started the app.
  Map<String, String>? launchData;

  /// A tap on a push the system showed in the background.
  void tap(Map<String, String> data) => _taps.add(data);

  @override
  Future<Map<String, String>?> launchTap() async => launchData;

  @override
  Stream<Map<String, String>> get taps => _taps.stream;

  void receive(AppNotification n) => _messages.add(n);

  void refreshToken(String token) {
    currentToken = token;
    _tokens.add(token);
  }

  @override
  String get platform => 'android';

  @override
  Future<NotificationPermission> permission() async => current;

  @override
  Future<NotificationPermission> requestPermission() async {
    prompts++;
    if (failNextPrompt) {
      failNextPrompt = false;
      throw StateError('Unable to detect current Android Activity.');
    }
    if (current == NotificationPermission.notDetermined) current = answer;
    return current;
  }

  @override
  Future<String?> token() async => currentToken;

  @override
  Stream<String> get tokenRefreshes => _tokens.stream;

  @override
  Stream<AppNotification> get foregroundMessages => _messages.stream;

  @override
  Future<void> deleteToken() async {
    deletedTokens++;
    currentToken = 'token-after-${deletedTokens + 1}';
  }
}

/// Records what would be shown on the device.
class RecordingLocalNotifier implements LocalNotifier {
  final List<AppNotification> shown = [];
  final _taps = StreamController<Map<String, String>>.broadcast();

  /// The notification whose tap started the app.
  Map<String, String>? launchData;

  /// Taps a notification shown earlier, like the system would.
  void tap(AppNotification n) => _taps.add(n.tapData);

  @override
  Future<Map<String, String>?> launchTap() async => launchData;

  @override
  Stream<Map<String, String>> get taps => _taps.stream;

  @override
  Future<void> show(AppNotification notification) async =>
      shown.add(notification);

  /// Scheduled notifications by ID, like the system keeps them.
  final Map<int, ScheduledNotification> scheduled = {};
  int scheduleCalls = 0;
  int cancelCalls = 0;

  @override
  Future<void> schedule(ScheduledNotification notification) async {
    scheduleCalls++;
    scheduled[notification.id] = notification;
  }

  @override
  Future<void> cancelScheduled(int id) async {
    cancelCalls++;
    scheduled.remove(id);
  }

  @override
  Future<Set<int>> scheduledIds(NotificationChannel channel) async => {
    for (final s in scheduled.values)
      if (s.notification.channel == channel) s.id,
  };
}

/// In-memory [NotificationCloud] keyed like Firestore.
class FakeNotificationCloud implements NotificationCloud {
  /// users/{uid}/devices/{deviceId}
  final Map<String, DeviceRegistration> devices = {};

  /// households/{hid}/budgetAlerts/{id} → createdBy
  final Map<String, String> budgetAlerts = {};
  final List<HouseholdBudgetAlert> published = [];
  int registrations = 0;
  bool offline = false;

  @override
  Future<void> register(String uid, DeviceRegistration registration) async {
    if (offline) throw TimeoutException('offline');
    registrations++;
    devices['$uid/${registration.deviceId}'] = registration;
  }

  @override
  Future<void> unregister(String uid, String deviceId) async {
    if (offline) throw TimeoutException('offline');
    devices.remove('$uid/$deviceId');
  }

  @override
  Future<void> publishBudgetAlert(
    HouseholdBudgetAlert alert, {
    required String uid,
    String? userName,
  }) async {
    published.add(alert);
    // Like the rules: the first writer wins.
    budgetAlerts.putIfAbsent('${alert.householdId}/${alert.id}', () => uid);
  }
}
