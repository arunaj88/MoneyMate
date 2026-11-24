import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/models/transaction_model.dart';

import '../helpers/app_harness.dart';
import '../helpers/fakes.dart';

void main() {
  final today = DateTime.now();

  testWidgets('dashboard shows balance and all navigation sections', (
    tester,
  ) async {
    await TestHarness(
      transactions: [
        tx(
          id: 'salary',
          amountMinor: 1000000,
          date: today,
          type: TransactionType.income,
          categoryId: 'inc_salary',
        ),
        tx(id: 'food', amountMinor: 12550, date: today, note: 'Dinner'),
      ],
    ).pump(tester);

    expect(find.text('MoneyMate'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('balanceText'))).data,
      'AED 9,874.50',
    );
    expect(find.text('Recent transactions'), findsOneWidget);
    for (final label in [
      'Dashboard',
      'Transactions',
      'Budget',
      'Reports',
      'Settings',
    ]) {
      expect(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
        findsOneWidget,
      );
    }
  });

  testWidgets('add transaction validates input and refreshes dashboard', (
    tester,
  ) async {
    final harness = TestHarness();
    await harness.pump(tester);

    expect(find.text('No transactions yet'), findsWidgets);

    await tester.tap(find.byKey(const Key('addTransactionFab')));
    await tester.pumpAndSettle();
    expect(find.text('New transaction'), findsOneWidget);

    // Empty form.
    final save = find.byKey(const Key('saveTransactionButton'));
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Please enter an amount'), findsOneWidget);
    expect(find.text('Please choose a category'), findsOneWidget);

    // Zero amount.
    await tester.enterText(find.byKey(const Key('amountField')), '0');
    await tester.pumpAndSettle();
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Amount must be greater than zero'), findsOneWidget);

    // Valid expense.
    await tester.enterText(find.byKey(const Key('amountField')), '25.50');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Groceries'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Groceries'));
    await tester.enterText(find.byKey(const Key('noteField')), 'Weekly shop');
    await tester.pumpAndSettle();
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(harness.transactions.items, hasLength(1));
    final saved = harness.transactions.items.single;
    expect(saved.amountMinor, 2550);
    expect(saved.categoryId, 'exp_groceries');
    expect(saved.type, TransactionType.expense);
    expect(saved.note, 'Weekly shop');

    // Dashboard updated automatically.
    expect(
      tester.widget<Text>(find.byKey(const Key('balanceText'))).data,
      '-AED 25.50',
    );
    expect(find.text('Groceries'), findsWidgets);
  });

  testWidgets('transactions screen groups, searches and deletes', (
    tester,
  ) async {
    final harness = TestHarness(
      transactions: [
        tx(id: 'a', amountMinor: 1000, date: today, note: 'Coffee beans'),
        tx(
          id: 'b',
          amountMinor: 5000,
          date: today.subtract(const Duration(days: 1)),
          categoryId: 'exp_fuel',
          note: 'Full tank',
        ),
      ],
    );
    await harness.pump(tester);
    await openTab(tester, 'Transactions');

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('2 transactions'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('transactionSearchField')),
      'tank',
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('1 transaction'), findsOneWidget);
    expect(find.text('Fuel'), findsWidgets);

    // Delete via the row menu with confirmation.
    await tester.tap(find.byTooltip('More').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();
    expect(find.text('Delete transaction?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(harness.transactions.items.map((t) => t.id), ['a']);
    expect(find.text('No matching transactions'), findsOneWidget);
  });

  testWidgets('budget screen sets a weekly target and shows usage', (
    tester,
  ) async {
    final harness = TestHarness(
      transactions: [tx(id: 'a', amountMinor: 8500, date: today)],
    );
    await harness.pump(tester);
    await openTab(tester, 'Budget');

    await tester.tap(find.byKey(const Key('setTarget-weekly')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amountDialogField')), '100');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const Key('usagePercent-weekly'))).data,
      '85.0%',
    );
    expect(find.text('Weekly target'), findsOneWidget);
    // 85% crosses the 80% alert threshold.
    expect(find.byKey(const Key('budgetAlertBanner')), findsOneWidget);

    // Monthly target is independent.
    await tester.tap(find.text('Monthly').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('setTarget-monthly')), findsOneWidget);
  });

  testWidgets('reports and settings screens render', (tester) async {
    await TestHarness(
      transactions: [
        tx(
          id: 'i',
          amountMinor: 300000,
          date: today,
          type: TransactionType.income,
          categoryId: 'inc_salary',
        ),
        tx(id: 'e', amountMinor: 100000, date: today),
      ],
    ).pump(tester);

    await openTab(tester, 'Reports');
    expect(find.text('Total savings'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('reportSavings'))).data,
      '+AED 2,000.00',
    );

    await openTab(tester, 'Settings');
    await tester.ensureVisible(find.byKey(const Key('themeSelector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    await tester.scrollUntilVisible(
      find.text('Export transactions (CSV)'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Back up data'), findsOneWidget);
    expect(find.text('Restore from backup'), findsOneWidget);
    expect(find.text('Export transactions (CSV)'), findsOneWidget);
  });

  testWidgets('dashboard header: text column takes all the free width', (
    tester,
  ) async {
    await TestHarness().pump(tester); // 390x844, normal text size

    final greeting = find.byKey(const Key('dashboardGreeting'));
    final avatar = find.byKey(const Key('dashboardAvatar'));
    final textColumn = find
        .ancestor(of: greeting, matching: find.byType(Column))
        .first;
    final chip = find
        .ancestor(
          of: find.textContaining(RegExp(r'^\w{3}, \d{1,2} \w{3}$')).first,
          matching: find.byType(Container),
        )
        .first;

    // Greeting and app name start at the left padding, the avatar ends at
    // the right padding, and the chip sits right after the text column with
    // only the fixed gap before the avatar: no space is split off between
    // them (a Flexible chip used to take half the row).
    expect(tester.getTopLeft(textColumn).dx, closeTo(16, 0.5));
    expect(tester.getTopRight(avatar).dx, closeTo(390 - 16, 0.5));
    expect(
      tester.getTopLeft(chip).dx,
      closeTo(tester.getTopRight(textColumn).dx, 0.5),
    );
    expect(
      tester.getTopLeft(avatar).dx - tester.getTopRight(chip).dx,
      closeTo(12, 0.5),
    );
  });
}
