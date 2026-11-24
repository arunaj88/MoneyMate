import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/models/transaction_model.dart';

import '../helpers/app_harness.dart';
import '../helpers/fakes.dart';

void main() {
  final today = DateTime.now();

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  TestHarness harness() => TestHarness(
    withSavings: true,
    transactions: [
      tx(
        id: 'salary',
        amountMinor: 100000,
        date: today,
        type: TransactionType.income,
        categoryId: 'inc_salary',
      ),
      tx(id: 'food', amountMinor: 20000, date: today),
    ],
  );

  testWidgets('create a goal, add and withdraw money; balances follow', (
    tester,
  ) async {
    final app = harness();
    await app.pump(tester);

    // No goals yet: the balance is the plain total.
    expect(find.text('Total balance'), findsOneWidget);
    expect(textOf(tester, 'balanceText'), 'AED 800.00');

    // Create a goal from the dashboard card.
    final card = find.byKey(const Key('savingsOverviewCard'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.descendant(of: card, matching: find.text('Create')),
    );
    expect(find.text('New savings goal'), findsOneWidget);

    // Validation: empty form.
    await tapVisible(tester, find.byKey(const Key('saveGoalButton')));
    expect(find.text('Please enter a name'), findsOneWidget);
    expect(find.text('Please enter an amount'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('goalNameField')), 'Japan');
    await tester.enterText(find.byKey(const Key('goalTargetField')), '0');
    await tapVisible(tester, find.byKey(const Key('saveGoalButton')));
    expect(find.text('Amount must be greater than zero'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('goalTargetField')), '500');
    await tapVisible(tester, find.byKey(const Key('saveGoalButton')));
    expect(app.savings!.goals.single.name, 'Japan');
    expect(app.savings!.goals.single.targetMinor, 50000);

    // Open the Savings screen and the goal.
    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('savingsOverviewCard')),
        matching: find.text('View all'),
      ),
    );
    expect(find.text('Savings'), findsOneWidget);
    expect(textOf(tester, 'totalSavedText'), 'AED 0.00');
    expect(
      textOf(tester, 'overallSummaryText'),
      contains('1 active, 0 completed'),
    );
    expect(textOf(tester, 'personalSavedText'), 'AED 0.00');
    final goalId = app.savings!.goals.single.id;
    await tapVisible(tester, find.byKey(Key('savingsGoal-$goalId')));

    // Add 300.
    await tapVisible(tester, find.byKey(const Key('goalAddMoney')));
    await tester.enterText(find.byKey(const Key('moneyAmountField')), '300');
    await tapVisible(tester, find.byKey(const Key('saveMoneyButton')));
    expect(textOf(tester, 'goalSavedText'), 'AED 300.00');
    expect(textOf(tester, 'goalPercentText'), '60%');
    expect(textOf(tester, 'goalRemainingText'), 'AED 200.00');

    // Withdrawing more than saved is refused in the form.
    await tapVisible(tester, find.byKey(const Key('goalWithdraw')));
    await tester.enterText(find.byKey(const Key('moneyAmountField')), '301');
    await tapVisible(tester, find.byKey(const Key('saveMoneyButton')));
    expect(find.text('Only AED 300.00 is saved in this goal'), findsOneWidget);
    expect(app.savings!.entries, hasLength(1));

    // Withdraw 100.
    await tester.enterText(find.byKey(const Key('moneyAmountField')), '100');
    await tapVisible(tester, find.byKey(const Key('saveMoneyButton')));
    expect(textOf(tester, 'goalSavedText'), 'AED 200.00');
    expect(find.text('-AED 100.00'), findsOneWidget);
    expect(find.text('+AED 300.00'), findsOneWidget);

    // Back to the dashboard: 800 - 200 saved = 600 available.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(textOf(tester, 'totalSavedText'), 'AED 200.00');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Available balance'), findsOneWidget);
    expect(textOf(tester, 'balanceText'), 'AED 600.00');
    expect(textOf(tester, 'balanceSavedText'), 'In savings: AED 200.00');
    // Savings are not expenses: the transactions are untouched.
    expect(app.transactions.items, hasLength(2));
  });

  testWidgets('pause, complete and delete a goal with confirmation', (
    tester,
  ) async {
    final app = harness();
    await app.pump(tester);
    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('savingsOverviewCard')),
        matching: find.text('Create'),
      ),
    );
    await tester.enterText(find.byKey(const Key('goalNameField')), 'Car');
    await tester.enterText(find.byKey(const Key('goalTargetField')), '100');
    await tapVisible(tester, find.byKey(const Key('saveGoalButton')));
    final goalId = app.savings!.goals.single.id;

    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('savingsOverviewCard')),
        matching: find.text('View all'),
      ),
    );
    await tapVisible(tester, find.byKey(Key('savingsGoal-$goalId')));

    // Pause: adding money is disabled.
    await tapVisible(tester, find.byKey(const Key('goalMenu')));
    await tapVisible(tester, find.text('Pause goal'));
    expect(app.savings!.goals.single.isPaused, isTrue);
    expect(
      tester
          .widget<ButtonStyleButton>(find.byKey(const Key('goalAddMoney')))
          .onPressed,
      isNull,
    );

    // Resume and complete (with confirmation).
    await tapVisible(tester, find.byKey(const Key('resumeGoalButton')));
    expect(app.savings!.goals.single.isActive, isTrue);
    await tapVisible(tester, find.byKey(const Key('goalMenu')));
    await tapVisible(tester, find.text('Mark as completed'));
    await tapVisible(tester, find.text('Complete'));
    expect(app.savings!.goals.single.isCompleted, isTrue);

    // Delete: cancelling keeps it; confirming removes it.
    await tapVisible(tester, find.byKey(const Key('goalMenu')));
    await tapVisible(tester, find.text('Delete goal'));
    await tapVisible(tester, find.text('Cancel'));
    expect(app.savings!.goals, hasLength(1));
    await tapVisible(tester, find.byKey(const Key('goalMenu')));
    await tapVisible(tester, find.text('Delete goal'));
    await tapVisible(tester, find.text('Delete'));
    expect(app.savings!.goals, isEmpty);
    expect(find.text('No personal goals yet'), findsOneWidget);
  });

  testWidgets('three tabs; household and shared explain what they need', (
    tester,
  ) async {
    await harness().pump(tester);
    await tapVisible(tester, find.byKey(const Key('savingsOverviewCard')));
    for (final tab in ['Personal', 'Household', 'Shared']) {
      expect(
        find.descendant(of: find.byType(TabBar), matching: find.text(tab)),
        findsOneWidget,
      );
    }
    await tapVisible(tester, find.byKey(const Key('savingsTab-household')));
    expect(find.text('No household yet'), findsOneWidget);
    expect(find.byKey(const Key('newGoalFab')), findsNothing);
    await tapVisible(tester, find.byKey(const Key('savingsTab-shared')));
    expect(find.text('Sign in to share goals'), findsOneWidget);
  });

  testWidgets('savings stay hidden in the household view and without the '
      'feature', (tester) async {
    await TestHarness().pump(tester);
    expect(find.byKey(const Key('savingsOverviewCard')), findsNothing);
    await openTab(tester, 'Settings');
    expect(find.byKey(const Key('savingsTile')), findsNothing);
  });
}
