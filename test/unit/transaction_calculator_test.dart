import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/transaction_calculator.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/report_models.dart';
import 'package:money_mate/models/transaction_model.dart';

import '../helpers/fakes.dart';

void main() {
  final transactions = [
    tx(
      id: '1',
      amountMinor: 500000,
      date: DateTime(2026, 11, 1, 9),
      type: TransactionType.income,
      categoryId: 'inc_salary',
    ),
    tx(id: '2', amountMinor: 2550, date: DateTime(2026, 11, 2, 12)),
    tx(
      id: '3',
      amountMinor: 12000,
      date: DateTime(2026, 11, 2, 18),
      categoryId: 'exp_fuel',
    ),
    tx(id: '4', amountMinor: 1450, date: DateTime(2026, 10, 30)),
  ];

  test('totals separate income and expense', () {
    expect(TransactionCalculator.totalIncome(transactions), 500000);
    expect(TransactionCalculator.totalExpense(transactions), 16000);
    expect(TransactionCalculator.balance(transactions), 484000);
  });

  test('totals respect a date range', () {
    final nov = PeriodUtils.monthRange(DateTime(2026, 11));
    expect(TransactionCalculator.totalExpense(transactions, range: nov), 14550);
  });

  test('minor-unit arithmetic is exact (no floating point drift)', () {
    final many = List.generate(
      1000,
      (i) => tx(id: '$i', amountMinor: 10, date: DateTime(2026, 1, 1)),
    );
    // 1000 × 0.10 = 100.00 exactly.
    expect(TransactionCalculator.totalExpense(many), 10000);
  });

  test('groupByDay groups newest day first', () {
    final groups = TransactionCalculator.groupByDay(transactions);
    expect(groups.map((g) => g.key), [
      DateTime(2026, 11, 2),
      DateTime(2026, 11, 1),
      DateTime(2026, 10, 30),
    ]);
    expect(groups.first.value.length, 2);
  });

  test('totalsByCategory sorts by amount and ignores income', () {
    final totals = TransactionCalculator.totalsByCategory(
      transactions,
      TransactionType.expense,
    );
    expect(totals.map((t) => t.categoryId), ['exp_fuel', 'exp_food']);
    expect(totals.first.totalMinor, 12000);
    expect(totals.last.totalMinor, 4000);
  });

  test('toShares computes percentages', () {
    final shares = TransactionCalculator.toShares(
      const [
        CategoryTotal(categoryId: 'exp_food', totalMinor: 7500),
        CategoryTotal(categoryId: 'exp_fuel', totalMinor: 2500),
      ],
      {for (final c in DefaultCategories.all) c.id: c},
    );
    expect(shares.first.category.name, 'Food');
    expect(shares.first.percent, 75);
    expect(shares.last.percent, 25);
  });

  test('dailyTotals fills every day of the range', () {
    final range = DateRange(DateTime(2026, 11, 1), DateTime(2026, 11, 4));
    final days = TransactionCalculator.dailyTotals(
      transactions,
      TransactionType.expense,
      range,
    );
    expect(days.length, 3);
    expect(days.map((d) => d.totalMinor), [0, 14550, 0]);
  });

  test('percentChange', () {
    expect(TransactionCalculator.percentChange(150, 100), 50);
    expect(TransactionCalculator.percentChange(50, 100), -50);
    expect(TransactionCalculator.percentChange(50, 0), isNull);
  });
}
