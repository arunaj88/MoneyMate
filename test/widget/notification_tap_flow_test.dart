import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/app/home_shell.dart';
import 'package:money_mate/features/savings/screens/goal_details_screen.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:provider/provider.dart';

import '../helpers/app_harness.dart';
import '../helpers/fake_household_service.dart';
import '../helpers/fake_notifications.dart';
import '../helpers/fakes.dart';

int selectedTab(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

AppNotification notification(
  NotificationChannel channel, [
  Map<String, String> data = const {},
]) => AppNotification(title: 't', body: 'b', channel: channel, data: data);

void main() {
  testWidgets('the notification that started the app opens its screen', (
    tester,
  ) async {
    final local = RecordingLocalNotifier()
      ..launchData = notification(NotificationChannel.budgetAlerts).tapData;
    await TestHarness(localNotifier: local).pump(tester);
    expect(selectedTab(tester), 2);
  });

  testWidgets('a tap closes what is open and goes to its target', (
    tester,
  ) async {
    final local = RecordingLocalNotifier();
    await TestHarness(localNotifier: local, withSavings: true).pump(tester);
    expect(selectedTab(tester), 0);

    // A form is open when a household transaction notification is tapped.
    await tester.tap(find.byKey(const Key('addTransactionFab')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('amountField')), findsOneWidget);
    local.tap(
      notification(NotificationChannel.householdActivity, {
        'type': 'household_transaction',
        'householdId': 'h1',
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('amountField')), findsNothing);
    expect(selectedTab(tester), 1);

    // A savings goal update opens that goal.
    local.tap(
      notification(NotificationChannel.savingsUpdates, {
        'type': 'shared_goal',
        'goalId': 'g1',
      }),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GoalDetailsScreen), findsOneWidget);
    expect(find.text('This goal no longer exists'), findsOneWidget);

    // A recurring transaction notification goes back to the list.
    local.tap(notification(NotificationChannel.recurring));
    await tester.pumpAndSettle();
    expect(find.byType(GoalDetailsScreen), findsNothing);
    expect(selectedTab(tester), 1);
  });

  testWidgets('household taps open the household view, personal ones the '
      'personal view', (tester) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    await households.createHousehold('Khan family');
    final local = RecordingLocalNotifier();
    await TestHarness(
      households: households,
      localNotifier: local,
    ).pump(tester);
    final context = tester.element(find.byType(HomeShell));
    final views = context.read<TransactionScopeProvider>();
    final budgets = context.read<BudgetProvider>();
    expect(views.view, ViewScope.personal);

    // On the personal dashboard, a member added a shared transaction.
    local.tap(
      notification(NotificationChannel.householdActivity, {
        'type': 'household_transaction',
        'householdId': 'house-1',
      }),
    );
    await tester.pumpAndSettle();
    expect(selectedTab(tester), 1);
    expect(views.view, ViewScope.shared);

    // A personal budget alert goes back to the personal budgets.
    local.tap(
      notification(NotificationChannel.budgetAlerts, {
        'type': 'personal_budget',
      }),
    );
    await tester.pumpAndSettle();
    expect(selectedTab(tester), 2);
    expect(views.view, ViewScope.personal);
    expect(budgets.selectedScope, const DataScope.personal());

    // A household budget alert opens the household's budgets.
    local.tap(
      notification(NotificationChannel.budgetAlerts, {
        'type': 'household_budget',
        'householdId': 'house-1',
      }),
    );
    await tester.pumpAndSettle();
    expect(budgets.selectedScope, const DataScope.household('house-1'));
    expect(views.view, ViewScope.shared);

    // A household the user is no longer in changes nothing.
    await views.setView(ViewScope.personal);
    local.tap(
      notification(NotificationChannel.householdActivity, {
        'type': 'household_transaction',
        'householdId': 'other-house',
      }),
    );
    await tester.pumpAndSettle();
    expect(selectedTab(tester), 1);
    expect(views.view, ViewScope.personal);
  });
}
