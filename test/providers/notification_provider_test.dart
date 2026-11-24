import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/notification_cloud.dart';
import 'package:money_mate/core/services/notification_events.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/notification_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_notifications.dart';
import '../helpers/fakes.dart';

class NotificationSetup {
  NotificationSetup(
    this.prefs,
    this.authService,
    this.auth,
    this.settings,
    this.categories,
  );

  final SharedPreferences prefs;
  final FakeAuthService authService;
  final AuthProvider auth;
  final SettingsProvider settings;
  final CategoryProvider categories;
  final push = FakePushMessaging();
  final local = RecordingLocalNotifier();
  final cloud = FakeNotificationCloud();
  late NotificationProvider provider;

  Future<NotificationProvider> start({bool withPush = true}) async {
    provider = NotificationProvider(
      preferences: prefs,
      push: withPush ? push : null,
      local: local,
      cloud: cloud,
    );
    attach();
    await pumpEventQueue();
    return provider;
  }

  void attach() => provider.attach(auth, settings, categories);

  String get deviceId => prefs.getString(PrefKeys.notificationDeviceId)!;

  void dispose() {
    provider.dispose();
    auth.dispose();
  }
}

Future<NotificationSetup> setup({Map<String, Object> prefs = const {}}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final preferences = await SharedPreferences.getInstance();
  final service = FakeAuthService(signedIn: testUser);
  final auth = AuthProvider(service, preferences);
  final categories = CategoryProvider(InMemoryCategoryRepository());
  await categories.load();
  await pumpEventQueue();
  return NotificationSetup(
    preferences,
    service,
    auth,
    SettingsProvider(preferences),
    categories,
  );
}

RecurringRule rule({
  String id = 'r1',
  TransactionType type = TransactionType.income,
  int amountMinor = 1000000,
  String categoryId = 'inc_salary',
  String note = '',
}) => RecurringRule(
  id: id,
  type: type,
  amountMinor: amountMinor,
  categoryId: categoryId,
  frequency: RecurrenceFrequency.monthly,
  startDate: DateTime(2026, 11, 1),
  note: note,
  createdAt: DateTime(2026, 11, 1),
  updatedAt: DateTime(2026, 11, 1),
);

void main() {
  test('asks once after sign-in and registers this device', () async {
    final s = await setup();
    await s.start();

    expect(s.push.prompts, 1);
    expect(s.provider.permission, NotificationPermission.granted);
    final registration = s.cloud.devices['${testUser.uid}/${s.deviceId}']!;
    expect(registration.token, 'token-1');
    expect(registration.platform, 'android');
    expect(registration.currencyCode, 'AED');
    expect(registration.householdActivity, isTrue);
    expect(registration.householdBudgets, isTrue);
    expect(registration.savingsUpdates, isTrue);
    expect(s.prefs.getString(PrefKeys.notificationRegisteredUid), testUser.uid);

    // Nothing changed: no rewrite on later attaches.
    final writes = s.cloud.registrations;
    s.attach();
    await pumpEventQueue();
    expect(s.cloud.registrations, writes);

    // A restart never prompts again.
    s.dispose();
    final restarted = NotificationProvider(
      preferences: s.prefs,
      push: s.push..current = NotificationPermission.notDetermined,
      local: s.local,
      cloud: s.cloud,
    );
    final auth = AuthProvider(s.authService, s.prefs);
    await pumpEventQueue();
    restarted.attach(auth, s.settings, s.categories);
    await pumpEventQueue();
    expect(s.push.prompts, 1);
    restarted.dispose();
    auth.dispose();
  });

  test('preferences and currency travel with the registration', () async {
    final s = await setup();
    await s.start();
    await s.settings.setHouseholdActivityNotifications(false);
    await s.settings.setSavingsNotifications(false);
    await s.settings.setCurrency('USD');
    s.attach();
    await pumpEventQueue();

    final registration = s.cloud.devices['${testUser.uid}/${s.deviceId}']!;
    expect(registration.householdActivity, isFalse);
    expect(registration.householdBudgets, isTrue);
    expect(registration.savingsUpdates, isFalse);
    expect(registration.currencyCode, 'USD');
    s.dispose();
  });

  test('a refreshed token replaces the old one', () async {
    final s = await setup();
    await s.start();
    s.push.refreshToken('token-2');
    await pumpEventQueue();
    expect(s.cloud.devices['${testUser.uid}/${s.deviceId}']!.token, 'token-2');
    s.dispose();
  });

  test('denied permission: nothing is registered', () async {
    final s = await setup();
    s.push.answer = NotificationPermission.denied;
    await s.start();
    expect(s.provider.permission, NotificationPermission.denied);
    expect(s.cloud.devices, isEmpty);

    // Allowed later in the system settings.
    s.push.current = NotificationPermission.granted;
    await s.provider.refreshPermission();
    await pumpEventQueue();
    expect(s.cloud.devices, hasLength(1));
    s.dispose();
  });

  test('signing out removes the registration and rotates the token', () async {
    final s = await setup();
    await s.start();
    expect(s.cloud.devices, hasLength(1));

    expect(await s.auth.signOut(), isTrue);
    await pumpEventQueue();
    expect(s.cloud.devices, isEmpty);
    expect(s.push.deletedTokens, 1);
    expect(s.prefs.getString(PrefKeys.notificationRegisteredUid), isNull);
    expect(s.authService.calls.last, 'signOut');
    s.dispose();
  });

  test('a registration left by an offline sign-out is removed later', () async {
    final s = await setup(
      prefs: {
        PrefKeys.notificationDeviceId: 'device-1',
        PrefKeys.notificationRegisteredUid: 'old-uid',
      },
    );
    s.cloud.devices['old-uid/device-1'] = const DeviceRegistration(
      deviceId: 'device-1',
      token: 'stale',
      platform: 'android',
      currencyCode: 'AED',
      householdActivity: true,
      householdBudgets: true,
      savingsUpdates: true,
    );
    await s.start();
    expect(s.cloud.devices.keys, ['${testUser.uid}/device-1']);
    s.dispose();
  });

  test('offline registration is retried on the next change', () async {
    final s = await setup();
    s.cloud.offline = true;
    await s.start();
    expect(s.cloud.devices, isEmpty);
    s.cloud.offline = false;
    s.attach();
    await pumpEventQueue();
    expect(s.cloud.devices, hasLength(1));
    s.dispose();
  });

  test('pushes received while the app is open are shown', () async {
    final s = await setup();
    await s.start();
    const n = AppNotification(
      title: 'Sara added an expense',
      body: 'AED 45.50 · Groceries',
      channel: NotificationChannel.householdActivity,
      tag: 'tx-1',
    );
    s.push.receive(n);
    await pumpEventQueue();
    expect(s.local.shown, [n]);
    s.dispose();
  });

  test('without push support only local notifications work', () async {
    final s = await setup();
    await s.start(withPush: false);
    expect(s.provider.pushSupported, isFalse);
    expect(s.cloud.devices, isEmpty);
    expect(
      await s.provider.requestPermission(),
      NotificationPermission.unsupported,
    );
    s.dispose();
  });

  test('budget alerts: shown here, shared ones published', () async {
    final s = await setup();
    await s.start();
    const alert = BudgetAlert(
      key: 'alert.weekly.20261123',
      title: 'Budget warning',
      message: 'You have used 92% of your weekly budget.',
      level: BudgetAlertLevel.warning,
    );
    await s.provider.budgetAlertRaised(const BudgetAlertEvent(local: alert));
    expect(s.local.shown.single.title, 'Budget warning');
    expect(s.local.shown.single.channel, NotificationChannel.budgetAlerts);
    expect(s.local.shown.single.tag, 'budget-alert.weekly.20261123');
    expect(s.cloud.published, isEmpty);

    final household = HouseholdBudgetAlert(
      householdId: 'h1',
      key: 'monthly.20261101',
      level: 'exceeded',
      title: 'Budget exceeded',
      message: '104% of the shared monthly budget used. Over by AED 40.00.',
      periodEnd: DateTime(2026, 12, 1),
    );
    // Turned off on this device: nothing shown, the others are still told.
    await s.provider.budgetAlertRaised(BudgetAlertEvent(household: household));
    expect(s.local.shown, hasLength(1));
    expect(s.cloud.budgetAlerts, {
      'h1/monthly.20261101.exceeded': testUser.uid,
    });

    await s.provider.budgetAlertRaised(
      BudgetAlertEvent(local: alert, household: household),
    );
    expect(s.local.shown.last.title, 'Household budget warning');
    expect(s.local.shown.last.tag, 'budget-monthly.20261101');
    s.dispose();
  });

  test('recurring additions are summarised', () async {
    final s = await setup();
    await s.start();
    await s.provider.recurringAdded([RecurringAddition(rule(), 1)]);
    expect(s.local.shown.single.title, 'Recurring income added');
    expect(s.local.shown.single.body, 'Salary · +AED 10,000.00');
    expect(s.local.shown.single.channel, NotificationChannel.recurring);

    await s.provider.recurringAdded([
      RecurringAddition(rule(), 2),
      RecurringAddition(
        rule(
          id: 'r2',
          type: TransactionType.expense,
          amountMinor: 500000,
          categoryId: 'exp_rent',
          note: 'Flat rent',
        ),
        1,
      ),
    ]);
    expect(s.local.shown.last.title, '3 recurring transactions added');
    expect(
      s.local.shown.last.body,
      'Salary · +AED 10,000.00 × 2\nFlat rent · AED 5,000.00',
    );

    await s.settings.setRecurringNotifications(false);
    await s.provider.recurringAdded([RecurringAddition(rule(), 1)]);
    expect(s.local.shown, hasLength(2));
    s.dispose();
  });
}
