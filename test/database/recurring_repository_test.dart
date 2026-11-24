import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/services/recurring_scheduler.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/category_repository.dart';
import 'package:money_mate/repositories/recurring_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

RecurringRule salary({
  String id = 'salary',
  DateTime? start,
  String categoryId = 'inc_salary',
  String? householdId,
}) {
  final s = start ?? DateTime(2026, 3, 1, 9);
  return RecurringRule(
    id: id,
    type: TransactionType.income,
    amountMinor: 1000000,
    categoryId: categoryId,
    frequency: RecurrenceFrequency.monthly,
    startDate: s,
    note: 'Salary',
    scope: householdId == null
        ? TransactionScope.personal
        : TransactionScope.shared,
    householdId: householdId,
    createdAt: s,
    updatedAt: s,
    createdBy: householdId == null ? null : 'uid-1',
  );
}

void main() {
  sqfliteFfiInit();

  late AppDatabase db;
  late SqliteRecurringRepository recurring;
  late SqliteTransactionRepository transactions;

  setUp(() async {
    db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    recurring = SqliteRecurringRepository(db);
    transactions = SqliteTransactionRepository(db);
  });

  tearDown(() => db.close());

  Future<int> run(DateTime now) async {
    var added = 0;
    for (final r in await recurring.getRules()) {
      added += await recurring.commit(RecurringScheduler.due(r, now));
    }
    return added;
  }

  test('adds due occurrences once and advances the rule', () async {
    await recurring.insert(salary());
    expect(await run(DateTime(2026, 5, 15)), 3); // March, April, May.
    final stored = await transactions.getTransactions();
    expect(stored.map((t) => t.date), [
      DateTime(2026, 5, 1, 9),
      DateTime(2026, 4, 1, 9),
      DateTime(2026, 3, 1, 9),
    ]);
    expect(stored.every((t) => t.amountMinor == 1000000), isTrue);

    // Running again the same day adds nothing; next month adds one.
    expect(await run(DateTime(2026, 5, 31)), 0);
    expect((await recurring.getRules()).single.nextIndex, 3);
    expect(await run(DateTime(2026, 6, 1)), 1);
    expect(await transactions.getTransactions(), hasLength(4));

    // New rows are pending upload, like any new transaction.
    final rows = await db.db.query(
      Tables.transactions,
      columns: ['sync_status'],
    );
    expect(rows.every((r) => r['sync_status'] == 'pending'), isTrue);
  });

  test('a stale or repeated commit adds nothing', () async {
    final rule = salary();
    await recurring.insert(rule);
    final due = RecurringScheduler.due(rule, DateTime(2026, 4, 1));
    expect(await recurring.commit(due), 2);
    // The same batch again (e.g. two runs racing) is ignored.
    expect(await recurring.commit(due), 0);
    expect(await transactions.getTransactions(), hasLength(2));
  });

  test('a deleted occurrence is never added again', () async {
    final rule = salary();
    await recurring.insert(rule);
    await run(DateTime(2026, 3, 2));
    final first = (await transactions.getTransactions()).single;
    await transactions.delete(first.id);

    // Even a fresh copy of the rule (e.g. restored from a backup) skips it.
    await recurring.delete(rule.id);
    await recurring.insert(salary());
    expect(await run(DateTime(2026, 4, 1)), 1);
    expect((await transactions.getTransactions()).map((t) => t.date), [
      DateTime(2026, 4, 1, 9),
    ]);
  });

  test('stopping a rule keeps the transactions it added', () async {
    await recurring.insert(salary());
    await run(DateTime(2026, 4, 1));
    await recurring.delete('salary');
    expect(await recurring.getRules(), isEmpty);
    expect(await run(DateTime(2026, 9, 1)), 0);
    expect(await transactions.getTransactions(), hasLength(2));
  });

  test('deleting a category moves its rules to Other', () async {
    const bonus = CategoryModel(
      id: 'bonus',
      name: 'Bonus',
      type: TransactionType.income,
      iconKey: 'gift',
      colorValue: 0xFF795548,
    );
    final categories = SqliteCategoryRepository(db);
    await categories.insert(bonus);
    await recurring.insert(salary(categoryId: 'bonus'));
    await categories.delete(bonus);

    final rule = (await recurring.getRules()).single;
    expect(rule.categoryId, DefaultCategories.otherIdFor(rule.type));
    await run(DateTime(2026, 3, 1));
    expect(
      (await transactions.getTransactions()).single.categoryId,
      DefaultCategories.otherIdFor(TransactionType.income),
    );
  });

  test('Reset App removes every rule', () async {
    await recurring.insert(salary());
    await recurring.insert(salary(id: 'rent', householdId: 'h1'));
    await SqliteLocalSyncStore(db).clearLocalData(resetAt: DateTime.now());
    expect(await recurring.getRules(), isEmpty);
  });

  test('leaving a household removes its shared rules only', () async {
    await recurring.insert(salary());
    await recurring.insert(salary(id: 'rent', householdId: 'h1'));
    await SqliteLocalSyncStore(db).releaseHousehold('h1', uid: 'uid-1');
    expect((await recurring.getRules()).map((r) => r.id), ['salary']);
  });

  test('backups include personal rules and restore them', () async {
    await recurring.insert(salary());
    await recurring.insert(salary(id: 'rent', householdId: 'h1'));
    final backup = SqliteBackupService(db);
    final json = await backup.createBackupJson();
    final contents = BackupService.parse(json);
    expect(contents.recurringRules.map((r) => r.id), ['salary']);

    await recurring.delete('salary');
    await backup.restore(contents);
    expect(
      (await recurring.getRules()).map((r) => r.id),
      unorderedEquals(['salary', 'rent']),
    );
  });

  test('backups made before recurring rules existed still parse', () {
    final contents = BackupService.parse(
      '{"app":"MoneyMate","schemaVersion":1,'
      '"data":{"categories":[],"transactions":[]}}',
    );
    expect(contents.recurringRules, isEmpty);
  });

  test('upgrading from v3 adds the table and keeps data', () async {
    final dir = await Directory.systemTemp.createTemp('mm_recurring');
    addTearDown(() => dir.delete(recursive: true));
    final factory = databaseFactoryFfiNoIsolate;
    final path = p.join(dir.path, 'v3.db');
    final v3 = await AppDatabase.openAtPath(factory, path, version: 3);
    await SqliteTransactionRepository(v3).insert(
      TransactionModel(
        id: 'kept',
        type: TransactionType.expense,
        amountMinor: 500,
        categoryId: 'exp_food',
        date: DateTime(2026, 11),
        createdAt: DateTime(2026, 11),
        updatedAt: DateTime(2026, 11),
      ),
    );
    final before = await v3.db.rawQuery(
      "SELECT name FROM sqlite_master WHERE name = '${Tables.recurringRules}'",
    );
    expect(before, isEmpty);
    await v3.close();

    final v4 = await AppDatabase.openAtPath(factory, path);
    addTearDown(v4.close);
    expect(await v4.db.getVersion(), AppConstants.databaseVersion);
    expect(
      (await SqliteTransactionRepository(v4).getTransactions()).single.id,
      'kept',
    );
    final repo = SqliteRecurringRepository(v4);
    await repo.insert(salary());
    expect(await repo.getRules(), hasLength(1));
  });
}
