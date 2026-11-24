import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/models/transaction_model.dart';

import '../helpers/app_harness.dart';

void main() {
  testWidgets('a monthly salary is added, listed in Settings and stopped', (
    tester,
  ) async {
    final harness = TestHarness();
    await harness.pump(tester);

    await tester.tap(find.byKey(const Key('addTransactionFab')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amountField')), '10000');
    await tester.ensureVisible(find.text('Salary'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salary'));
    await tester.pumpAndSettle();

    final repeat = find.byKey(const Key('repeatField'));
    await tester.ensureVisible(repeat);
    await tester.pumpAndSettle();
    expect(find.text('Does not repeat'), findsOneWidget);
    await tester.tap(repeat);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('repeat-monthly')));
    await tester.pumpAndSettle();
    final today = DateTime.now();
    expect(
      find.text(RecurringRule.describe(RecurrenceFrequency.monthly, today)),
      findsOneWidget,
    );

    final save = find.byKey(const Key('saveTransactionButton'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(find.textContaining('repeats monthly'), findsOneWidget);
    final rule = harness.recurring.rules.single;
    expect(rule.frequency, RecurrenceFrequency.monthly);
    expect(rule.amountMinor, 1000000);
    expect(rule.nextIndex, 1);
    final added = harness.transactions.items.single;
    expect(added.type, TransactionType.income);
    expect(added.categoryId, 'inc_salary');
    expect(PeriodUtils.isSameDay(added.date, today), isTrue);

    // Listed in Settings with its next date.
    await openTab(tester, 'Settings');
    final tile = find.byKey(const Key('recurringTile'));
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(Key('recurringRule-${rule.id}')), findsOneWidget);
    expect(find.textContaining('Next: '), findsOneWidget);

    // Stopping keeps the transaction already added.
    await tester.tap(find.byKey(Key('stopRule-${rule.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(find.text('No recurring transactions'), findsOneWidget);
    expect(harness.recurring.rules, isEmpty);
    expect(harness.transactions.items, hasLength(1));
  });

  testWidgets('repeats that fell due are added when the app starts', (
    tester,
  ) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month - 2, 1, 9);
    final harness = TestHarness();
    harness.recurring.rules.add(
      RecurringRule(
        id: 'salary',
        type: TransactionType.income,
        amountMinor: 1000000,
        categoryId: 'inc_salary',
        frequency: RecurrenceFrequency.monthly,
        startDate: start,
        nextIndex: 1, // The first month was added when it was created.
        createdAt: start,
        updatedAt: start,
      ),
    );
    await harness.pump(tester);

    // The two months since then were added once each.
    expect(harness.transactions.items.map((t) => t.date), [
      DateTime(start.year, start.month + 1, 1, 9),
      DateTime(start.year, start.month + 2, 1, 9),
    ]);
    expect(harness.recurring.rules.single.nextIndex, 3);
    expect(find.text('AED 20,000.00'), findsWidgets);
  });
}
