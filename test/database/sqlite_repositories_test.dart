import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/budget_repository.dart';
import 'package:money_mate/repositories/category_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fakes.dart';

void main() {
  sqfliteFfiInit();

  late AppDatabase db;
  late SqliteTransactionRepository transactions;
  late SqliteCategoryRepository categories;
  late SqliteBudgetRepository budgets;

  setUp(() async {
    db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    transactions = SqliteTransactionRepository(db);
    categories = SqliteCategoryRepository(db);
    budgets = SqliteBudgetRepository(db);
  });

  tearDown(() => db.close());

  group('schema', () {
    test('seeds default categories', () async {
      final all = await categories.getAll();
      expect(all.length, DefaultCategories.all.length);
      expect(
        all.where((c) => c.type == TransactionType.expense).map((c) => c.name),
        containsAll(['Food', 'Groceries', 'Fuel', 'Rent', 'Other']),
      );
    });

    test('rejects non-positive amounts at the database level', () async {
      await expectLater(
        db.db.insert(Tables.transactions, {
          ...tx(id: 'x', amountMinor: 1, date: DateTime(2026)).toMap(),
          'amount_minor': 0,
        }),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('enforces category foreign key', () async {
      await expectLater(
        transactions.insert(
          tx(
            id: 'x',
            amountMinor: 100,
            date: DateTime(2026),
            categoryId: 'nope',
          ),
        ),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('transactions', () {
    setUp(() async {
      await transactions.insert(
        tx(
          id: 'salary',
          amountMinor: 1000000,
          date: DateTime(2026, 11, 1, 9),
          type: TransactionType.income,
          categoryId: 'inc_salary',
        ),
      );
      await transactions.insert(
        tx(
          id: 'lunch',
          amountMinor: 4550,
          date: DateTime(2026, 11, 24, 13),
          note: 'Lunch with team',
        ),
      );
      await transactions.insert(
        tx(
          id: 'fuel',
          amountMinor: 20000,
          date: DateTime(2026, 11, 22, 8),
          categoryId: 'exp_fuel',
        ),
      );
      await transactions.insert(
        tx(id: 'old', amountMinor: 3000, date: DateTime(2026, 10, 31, 20)),
      );
    });

    test('returns newest first', () async {
      final all = await transactions.getTransactions();
      expect(all.map((t) => t.id), ['lunch', 'fuel', 'salary', 'old']);
    });

    test('filters by type, category and date range', () async {
      final expenses = await transactions.getTransactions(
        filter: const TransactionFilter(type: TransactionType.expense),
      );
      expect(expenses.length, 3);

      final fuel = await transactions.getTransactions(
        filter: const TransactionFilter(categoryIds: {'exp_fuel'}),
      );
      expect(fuel.single.id, 'fuel');

      final nov = await transactions.getTransactions(
        filter: TransactionFilter(
          start: DateTime(2026, 11),
          end: DateTime(2026, 12),
        ),
      );
      expect(nov.map((t) => t.id), isNot(contains('old')));
    });

    test('searches notes and category names', () async {
      final byNote = await transactions.getTransactions(
        filter: const TransactionFilter(query: 'team'),
      );
      expect(byNote.single.id, 'lunch');
      final byCategory = await transactions.getTransactions(
        filter: const TransactionFilter(query: 'fue'),
      );
      expect(byCategory.single.id, 'fuel');
      final literal = await transactions.getTransactions(
        filter: const TransactionFilter(query: '%'),
      );
      expect(literal, isEmpty);
    });

    test('update and delete', () async {
      final lunch = (await transactions.getById('lunch'))!;
      await transactions.update(lunch.copyWith(amountMinor: 5000));
      expect((await transactions.getById('lunch'))!.amountMinor, 5000);
      await transactions.delete('lunch');
      expect(await transactions.getById('lunch'), isNull);
    });

    test('aggregations', () async {
      expect(
        await transactions.sumAmount(type: TransactionType.income),
        1000000,
      );
      expect(
        await transactions.sumAmount(
          type: TransactionType.expense,
          range: PeriodUtils.monthRange(DateTime(2026, 11)),
        ),
        24550,
      );
      final byCategory = await transactions.totalsByCategory(
        type: TransactionType.expense,
        range: PeriodUtils.monthRange(DateTime(2026, 11)),
      );
      expect(byCategory.first.categoryId, 'exp_fuel');
    });

    test('a past-dated expense counts toward its own week AND month', () async {
      // Week of Mon 16 – Sun 22 Nov and month of November both include fuel.
      final totals = await transactions.totalsForRanges([
        PeriodUtils.weekRange(DateTime(2026, 11, 22)),
        PeriodUtils.weekRange(DateTime(2026, 11, 24)),
        PeriodUtils.monthRange(DateTime(2026, 11)),
        PeriodUtils.monthRange(DateTime(2026, 10)),
      ]);
      expect(totals[0].expenseMinor, 20000);
      expect(totals[1].expenseMinor, 4550);
      expect(totals[2].expenseMinor, 24550);
      expect(totals[2].incomeMinor, 1000000);
      expect(totals[3].expenseMinor, 3000);
    });

    test('daily totals cover every day', () async {
      final days = await transactions.dailyTotals(
        type: TransactionType.expense,
        range: PeriodUtils.weekRange(DateTime(2026, 11, 24)),
      );
      expect(days.length, 7);
      expect(days[1].totalMinor, 4550); // Tuesday 24th
    });

    test(
      'deleting a custom category moves its transactions to Other',
      () async {
        const custom = CategoryModel(
          id: 'custom',
          name: 'Coffee',
          type: TransactionType.expense,
          iconKey: 'coffee',
          colorValue: 0xFF795548,
        );
        await categories.insert(custom);
        await transactions.insert(
          tx(
            id: 'c1',
            amountMinor: 1500,
            date: DateTime(2026, 11, 3),
            categoryId: 'custom',
          ),
        );
        await categories.delete(custom);
        expect(
          (await transactions.getById('c1'))!.categoryId,
          DefaultCategories.otherExpenseId,
        );
      },
    );

    test('built-in categories cannot be deleted', () async {
      await expectLater(
        categories.delete(DefaultCategories.all.first),
        throwsStateError,
      );
    });
  });

  group('budgets', () {
    test('target versions are kept for history', () async {
      await budgets.setTarget(
        period: BudgetPeriod.monthly,
        amountMinor: 100000,
        effectiveFrom: DateTime(2026, 10),
      );
      await budgets.setTarget(
        period: BudgetPeriod.monthly,
        amountMinor: 150000,
        effectiveFrom: DateTime(2026, 11),
      );
      // Changing again in the same period replaces only that version.
      await budgets.setTarget(
        period: BudgetPeriod.monthly,
        amountMinor: 120000,
        effectiveFrom: DateTime(2026, 11),
      );
      final versions = await budgets.getTargetVersions(BudgetPeriod.monthly);
      expect(versions.map((v) => v.amountMinor), [100000, 120000]);
      expect(await budgets.getTargetVersions(BudgetPeriod.weekly), isEmpty);
    });

    test('category budgets are unique per category and period', () async {
      final now = DateTime(2026, 11, 1);
      CategoryBudget b(String id, int amount) => CategoryBudget(
        id: id,
        categoryId: 'exp_food',
        period: BudgetPeriod.monthly,
        amountMinor: amount,
        createdAt: now,
        updatedAt: now,
      );
      await budgets.upsertCategoryBudget(b('a', 50000));
      await budgets.upsertCategoryBudget(b('b', 60000));
      final all = await budgets.getCategoryBudgets();
      expect(all.single.amountMinor, 60000);
    });
  });

  group('backup', () {
    test('round trip restores identical data', () async {
      final service = SqliteBackupService(db);
      await transactions.insert(
        tx(
          id: 't1',
          amountMinor: 1234,
          date: DateTime(2026, 11, 5),
          note: 'Comma, "quote"',
        ),
      );
      await budgets.setTarget(
        period: BudgetPeriod.weekly,
        amountMinor: 50000,
        effectiveFrom: DateTime(2026, 11, 2),
      );
      final json = await service.createBackupJson(
        settings: {'currencyCode': 'AED'},
      );

      final parsed = BackupService.parse(json);
      expect(parsed.transactions.single.note, 'Comma, "quote"');

      await transactions.delete('t1');
      await service.restore(parsed);

      expect((await transactions.getById('t1'))!.amountMinor, 1234);
      expect(
        (await budgets.getTargetVersions(
          BudgetPeriod.weekly,
        )).single.amountMinor,
        50000,
      );
    });

    test('accepts backups created under the old ExpenseMate name', () {
      final parsed = BackupService.parse(
        jsonEncode({
          'app': 'ExpenseMate',
          'schemaVersion': 1,
          'data': {'categories': [], 'transactions': []},
        }),
      );
      expect(parsed.transactions, isEmpty);
    });

    test('rejects invalid files', () {
      expect(
        () => BackupService.parse('not json'),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupService.parse(jsonEncode({'app': 'Other'})),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupService.parse(
          jsonEncode({
            'app': 'MoneyMate',
            'schemaVersion': 999,
            'data': {'transactions': [], 'categories': []},
          }),
        ),
        throwsA(isA<BackupFormatException>()),
      );
      expect(
        () => BackupService.parse(
          jsonEncode({
            'app': 'MoneyMate',
            'schemaVersion': 1,
            'data': {
              'categories': [],
              'transactions': [
                tx(
                  id: '1',
                  amountMinor: 100,
                  date: DateTime(2026),
                  categoryId: 'missing',
                ).toJson(),
              ],
            },
          }),
        ),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('CSV export escapes values', () async {
      final service = SqliteBackupService(db);
      await transactions.insert(
        tx(
          id: 't1',
          amountMinor: 1234,
          date: DateTime(2026, 11, 5),
          note: 'Comma, "quote"',
        ),
      );
      final csv = await service.createTransactionsCsv(currencyCode: 'AED');
      final lines = const LineSplitter().convert(csv);
      expect(
        lines.first,
        'Date,Type,Category,Amount,Currency,Payment Method,Note,Scope,Added By',
      );
      expect(
        lines[1],
        '2026-11-05,Expense,Food,-12.34,AED,Cash,"Comma, ""quote""",Personal,',
      );
      expect(BackupService.buildCsvRow(['=SUM(A1)']), "'=SUM(A1)");
    });
  });
}
