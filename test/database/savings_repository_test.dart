import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/services/cloud_savings_store.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/savings_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fakes.dart';

final _t0 = DateTime(2026, 11, 1, 9);

SavingsGoal newGoal(String id, {int target = 100000}) => SavingsGoal(
  id: id,
  name: 'Goal $id',
  purpose: SavingsPurpose.trip,
  targetMinor: target,
  createdAt: _t0,
  updatedAt: _t0,
);

SavingsEntry entry(
  String id,
  String goalId,
  int amount, {
  bool deposit = true,
  DateTime? date,
}) => SavingsEntry(
  id: id,
  goalId: goalId,
  type: deposit ? SavingsEntryType.deposit : SavingsEntryType.withdrawal,
  amountMinor: amount,
  date: date ?? _t0,
  createdAt: _t0,
  updatedAt: _t0,
);

void main() {
  sqfliteFfiInit();

  late AppDatabase db;
  late SqliteSavingsRepository repo;

  setUp(() async {
    db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    repo = SqliteSavingsRepository(db);
  });

  tearDown(() => db.close());

  Future<int> savedIn(String goalId) async =>
      (await repo.getGoals()).firstWhere((g) => g.id == goalId).savedMinor;

  test('contributions and withdrawals update the derived balance', () async {
    await repo.insertGoal(newGoal('g'));
    await repo.addEntry(entry('e1', 'g', 30000));
    await repo.addEntry(entry('e2', 'g', 5000));
    await repo.addEntry(entry('w1', 'g', 10000, deposit: false));

    final goal = (await repo.getGoals()).single;
    expect(goal.savedMinor, 25000);
    expect(goal.firstEntryDate, _t0);
    expect((await repo.getEntries('g')).map((e) => e.id), hasLength(3));
  });

  test('a withdrawal can never exceed the goal balance', () async {
    await repo.insertGoal(newGoal('g'));
    await repo.addEntry(entry('e1', 'g', 1000));
    await expectLater(
      repo.addEntry(entry('w1', 'g', 1001, deposit: false)),
      throwsA(isA<SavingsException>()),
    );
    expect(await savedIn('g'), 1000);
    // Exactly the balance is fine.
    await repo.addEntry(entry('w2', 'g', 1000, deposit: false));
    expect(await savedIn('g'), 0);
  });

  test('entries need an existing goal', () async {
    await expectLater(
      repo.addEntry(entry('e1', 'missing', 100)),
      throwsA(isA<SavingsException>()),
    );
  });

  test(
    'deleting a contribution that was already withdrawn is refused',
    () async {
      await repo.insertGoal(newGoal('g'));
      await repo.addEntry(entry('e1', 'g', 1000));
      await repo.addEntry(entry('w1', 'g', 800, deposit: false));
      await expectLater(
        repo.deleteEntry('e1', DateTime.now()),
        throwsA(isA<SavingsException>()),
      );
      // Deleting the withdrawal first, then the contribution, works.
      await repo.deleteEntry('w1', DateTime.now());
      await repo.deleteEntry('e1', DateTime.now());
      expect(await savedIn('g'), 0);
    },
  );

  test('deleting a goal removes its history and leaves tombstones', () async {
    await repo.insertGoal(newGoal('g'));
    await repo.insertGoal(newGoal('keep'));
    await repo.addEntry(entry('e1', 'g', 1000));
    await repo.addEntry(entry('e2', 'keep', 500));
    await repo.deleteGoal('g', DateTime(2026, 11, 2));

    expect((await repo.getGoals()).map((g) => g.id), ['keep']);
    expect(await repo.getEntries('g'), isEmpty);
    expect(await savedIn('keep'), 500);

    final goalUploads = await repo.pendingRecords(
      const SavingsPartition.personal('u'),
      SavingsCollection.goals,
    );
    final deletion = goalUploads.firstWhere((p) => p.isTombstone);
    expect(deletion.id, 'g');
    expect(deletion.record.deleted, isTrue);
    final entryUploads = await repo.pendingRecords(
      const SavingsPartition.personal('u'),
      SavingsCollection.entries,
    );
    expect(entryUploads.where((p) => p.isTombstone).map((p) => p.id), ['e1']);
  });

  test('savings are kept apart from income and expense totals', () async {
    final transactions = SqliteTransactionRepository(db);
    final today = DateTime.now();
    await transactions.insert(
      tx(
        id: 'i',
        type: TransactionType.income,
        categoryId: 'inc_salary',
        amountMinor: 100000,
        date: today,
      ),
    );
    await transactions.insert(tx(id: 'x', amountMinor: 20000, date: today));
    await repo.insertGoal(newGoal('g'));
    await repo.addEntry(entry('e1', 'g', 30000, date: today));

    expect(await transactions.sumAmount(type: TransactionType.income), 100000);
    expect(await transactions.sumAmount(type: TransactionType.expense), 20000);
    final month = PeriodUtils.monthRange(DateTime.now());
    final totals = await transactions.totalsForRanges([month]);
    expect(totals.single.expenseMinor, 20000);
    expect(totals.single.incomeMinor, 100000);
    expect((await transactions.getTransactions()).map((t) => t.id).toSet(), {
      'i',
      'x',
    });
  });

  test('Reset App clears savings with everything else', () async {
    await repo.insertGoal(newGoal('g'));
    await repo.addEntry(entry('e1', 'g', 100));
    await SqliteLocalSyncStore(db).clearLocalData(resetAt: DateTime.now());
    expect(await repo.getGoals(), isEmpty);
    expect(
      await repo.pendingRecords(
        const SavingsPartition.personal('u'),
        SavingsCollection.entries,
      ),
      isEmpty,
    );
  });

  test('backup includes savings and restores them for upload', () async {
    await repo.insertGoal(newGoal('g'));
    await repo.addEntry(entry('e1', 'g', 4000));
    await repo.addEntry(entry('w1', 'g', 1000, deposit: false));
    final backup = SqliteBackupService(db);
    final json = await backup.createBackupJson();

    // Data changed after the backup: a new goal that is not in it.
    await repo.insertGoal(newGoal('later'));

    await backup.restore(BackupService.parse(json));
    final goals = await repo.getGoals();
    expect(goals.map((g) => g.id), ['g']);
    expect(goals.single.savedMinor, 3000);
    final pending = await repo.pendingRecords(
      const SavingsPartition.personal('u'),
      SavingsCollection.goals,
    );
    // The restored goal is uploaded again; the dropped one is deleted.
    expect(pending.where((p) => !p.isTombstone).map((p) => p.id), ['g']);
    expect(pending.where((p) => p.isTombstone).map((p) => p.id), ['later']);
  });

  test('backup parsing rejects inconsistent savings', () {
    String doc(List<Map<String, Object?>> entries) =>
        '{"app":"MoneyMate","schemaVersion":1,"data":{"categories":[],'
        '"transactions":[],"savingsGoals":[${_json(newGoal('g').toJson())}],'
        '"savingsEntries":[${entries.map(_json).join(',')}]}}';
    expect(
      () => BackupService.parse(doc([entry('e', 'other', 5).toJson()])),
      throwsA(isA<BackupFormatException>()),
    );
    expect(
      () => BackupService.parse(
        doc([entry('w', 'g', 5, deposit: false).toJson()]),
      ),
      throwsA(isA<BackupFormatException>()),
    );
    expect(
      BackupService.parse(doc([entry('e', 'g', 5).toJson()])).savingsEntries,
      hasLength(1),
    );
  });

  group('on disk', () {
    late Directory dir;
    late String path;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('money_mate_savings');
      path = p.join(dir.path, 'test.db');
    });

    tearDown(() => dir.delete(recursive: true));

    test('savings survive an app restart', () async {
      final factory = databaseFactoryFfiNoIsolate;
      final first = await AppDatabase.openAtPath(factory, path);
      final r1 = SqliteSavingsRepository(first);
      await r1.insertGoal(newGoal('g'));
      await r1.addEntry(entry('e1', 'g', 2500));
      await first.close();

      final second = await AppDatabase.openAtPath(factory, path);
      final goals = await SqliteSavingsRepository(second).getGoals();
      expect(goals.single.savedMinor, 2500);
      await second.close();
    });

    test(
      'v5 → v6 keeps existing goals as personal with their history',
      () async {
        final factory = databaseFactoryFfiNoIsolate;
        final v5 = await AppDatabase.openAtPath(factory, path, version: 5);
        await v5.db.insert(Tables.savingsGoals, {
          'id': 'old',
          'name': 'Old goal',
          'purpose': 'gold',
          'target_minor': 1000,
          'created_at': 1,
          'updated_at': 1,
          'sync_status': 'synced',
        });
        await v5.db.insert(Tables.savingsEntries, {
          'id': 'e',
          'goal_id': 'old',
          'type': 'deposit',
          'amount_minor': 400,
          'date': 1,
          'created_at': 1,
          'updated_at': 1,
          'sync_status': 'synced',
        });
        await v5.close();

        final v6 = await AppDatabase.openAtPath(factory, path);
        final goal = (await SqliteSavingsRepository(v6).getGoals()).single;
        expect(goal.ownership, SavingsOwnership.personal);
        expect(goal.householdId, isNull);
        expect(goal.savedMinor, 400);
        await v6.close();
      },
    );

    test(
      'v4 → current adds the savings tables and keeps existing data',
      () async {
        final factory = databaseFactoryFfiNoIsolate;
        final v4 = await AppDatabase.openAtPath(factory, path, version: 4);
        await SqliteTransactionRepository(
          v4,
        ).insert(tx(id: 'a', amountMinor: 100, date: _t0));
        await v4.close();

        final v5 = await AppDatabase.openAtPath(factory, path);
        expect(
          (await SqliteTransactionRepository(v5).getTransactions()).single.id,
          'a',
        );
        final r = SqliteSavingsRepository(v5);
        await r.insertGoal(newGoal('g'));
        expect((await r.getGoals()).single.id, 'g');
        await v5.close();
      },
    );
  });
}

String _json(Map<String, Object?> map) =>
    '{${map.entries.map((e) {
      final v = e.value;
      final value = v == null
          ? 'null'
          : v is String
          ? '"$v"'
          : '$v';
      return '"${e.key}":$value';
    }).join(',')}}';
