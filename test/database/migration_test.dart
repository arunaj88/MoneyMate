import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/repositories/budget_repository.dart';
import 'package:money_mate/repositories/category_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/settings_sync_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fakes.dart';

/// The columns a transaction had in schema v1.
Map<String, Object?> v1Row(TransactionModel t) => {
  for (final e in t.toMap().entries)
    if (const {
      'id',
      'type',
      'amount_minor',
      'category_id',
      'date',
      'note',
      'payment_method',
      'created_at',
      'updated_at',
    }.contains(e.key))
      e.key: e.value,
};

void main() {
  sqfliteFfiInit();

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('money_mate_migration');
    path = p.join(dir.path, 'test.db');
  });

  tearDown(() => dir.delete(recursive: true));

  test('v1 → v2 keeps every row and marks transactions pending', () async {
    final factory = databaseFactoryFfiNoIsolate;
    final v1 = await AppDatabase.openAtPath(factory, path, version: 1);
    // Insert with raw SQL: the v1 schema has no sync or scope columns.
    for (final t in [
      tx(id: 'a', amountMinor: 100, date: DateTime(2025, 1, 5)),
      tx(id: 'b', amountMinor: 250, date: DateTime(2026, 11, 1)),
    ]) {
      await v1.db.insert(Tables.transactions, v1Row(t));
    }
    await v1.db.insert(Tables.budgets, {
      'period': BudgetPeriod.weekly.name,
      'amount_minor': 5000,
      'effective_from': DateTime(2025, 1, 6).millisecondsSinceEpoch,
      'updated_at': DateTime(2025, 1, 6).millisecondsSinceEpoch,
    });
    final categoryCount = (await SqliteCategoryRepository(v1).getAll()).length;
    await v1.close();

    final v2 = await AppDatabase.openAtPath(factory, path);
    addTearDown(v2.close);
    expect(await v2.db.getVersion(), AppConstants.databaseVersion);

    final transactions = await SqliteTransactionRepository(
      v2,
    ).getTransactions();
    expect(transactions.map((t) => t.id), unorderedEquals(['a', 'b']));
    final rows = await v2.db.query(Tables.transactions);
    expect(rows.every((r) => r['sync_status'] == 'pending'), isTrue);
    expect(rows.every((r) => r['cloud_updated_at'] == null), isTrue);

    final store = SqliteLocalSyncStore(v2);
    expect(await store.countUnsynced(), (pending: 2, failed: 0));
    expect(await store.archiveCandidates(DateTime(2030)), isEmpty);
    expect((await SqliteCategoryRepository(v2).getAll()).length, categoryCount);
    expect(
      await SqliteBudgetRepository(v2).getTargetVersions(BudgetPeriod.weekly),
      hasLength(1),
    );
    expect(await v2.db.query(Tables.syncTombstones), isEmpty);
  });

  test('fresh install creates the v2 schema', () async {
    final db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    addTearDown(db.close);
    final columns = await db.db.rawQuery(
      'PRAGMA table_info(${Tables.transactions})',
    );
    expect(
      columns.map((c) => c['name']),
      containsAll(['sync_status', 'cloud_updated_at', 'synced_at']),
    );
  });

  test('local writes are tracked for sync', () async {
    final db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    addTearDown(db.close);
    final repo = SqliteTransactionRepository(db);
    final store = SqliteLocalSyncStore(db);
    final t = tx(id: 'a', amountMinor: 100, date: DateTime(2026, 11, 1));

    await repo.insert(t);
    await store.markSynced('a', t.updatedAt);
    expect((await store.getRecords(['a']))['a']!.isVerifiedInCloud, isTrue);

    await repo.update(t.copyWith(amountMinor: 150, updatedAt: DateTime(2027)));
    expect(
      (await store.getRecords(['a']))['a']!.status,
      RecordSyncStatus.pending,
    );

    // A stale confirmation (for the old version) is ignored.
    expect(await store.markSynced('a', t.updatedAt), isFalse);

    await repo.delete('a');
    expect(await store.allTombstoneIds(), {'a'});
    await repo.insert(t); // Undo cancels the pending deletion.
    expect(await store.allTombstoneIds(), isEmpty);
  });

  test(
    'v2 → v3 keeps everything personal and queues it for the cloud',
    () async {
      final factory = databaseFactoryFfiNoIsolate;
      final v2 = await AppDatabase.openAtPath(factory, path, version: 2);
      final synced = tx(
        id: 'synced',
        amountMinor: 700,
        date: DateTime(2026, 9),
      );
      await v2.db.insert(Tables.transactions, {
        ...v1Row(synced),
        'sync_status': 'synced',
        'cloud_updated_at': synced.updatedAt.millisecondsSinceEpoch,
      });
      await v2.db.insert(Tables.transactions, {
        ...v1Row(tx(id: 'pending', amountMinor: 300, date: DateTime(2026, 11))),
        'sync_status': 'pending',
      });
      await v2.db.insert(Tables.syncTombstones, {
        'id': 'gone',
        'deleted_at': 5,
        'sync_status': 'failed',
      });
      await v2.db.insert(Tables.categories, {
        'id': 'custom',
        'name': 'Hobbies',
        'type': 'expense',
        'icon_key': 'gift',
        'color_value': 1,
      });
      await v2.db.insert(Tables.budgets, {
        'period': 'monthly',
        'amount_minor': 90000,
        'effective_from': DateTime(2026, 10).millisecondsSinceEpoch,
        'updated_at': 1,
      });
      await v2.db.insert(Tables.categoryBudgets, {
        'id': 'cb',
        'category_id': 'custom',
        'period': 'weekly',
        'amount_minor': 2000,
        'created_at': 1,
        'updated_at': 1,
      });
      await v2.db.insert(Tables.appSettings, {
        'key': SyncKeys.pullCursorMicros,
        'value': '123',
      });
      await v2.close();

      final v3 = await AppDatabase.openAtPath(factory, path);
      addTearDown(v3.close);
      expect(await v3.db.getVersion(), AppConstants.databaseVersion);

      // Every transaction is personal; sync state and IDs are unchanged.
      final transactions = SqliteTransactionRepository(v3);
      final personal = await transactions.getTransactions();
      expect(personal.map((t) => t.id), unorderedEquals(['synced', 'pending']));
      expect(personal.every((t) => t.isPersonal), isTrue);
      expect(
        await transactions.getTransactions(
          filter: const TransactionFilter(scope: ScopeFilter.shared('any')),
        ),
        isEmpty,
      );
      final store = SqliteLocalSyncStore(v3);
      expect(
        (await store.getRecords(['synced']))['synced']!.isVerifiedInCloud,
        isTrue,
      );
      expect(await store.allTombstoneIds(scope: const DataScope.personal()), {
        'gone',
      });
      expect(await store.countUnsynced(), (pending: 1, failed: 1));

      // Budgets and categories are kept and queued for the personal cloud.
      final budgets = SqliteBudgetRepository(v3);
      final monthly = await budgets.getTargetVersions(BudgetPeriod.monthly);
      expect(monthly.single.amountMinor, 90000);
      expect(monthly.single.householdId, isNull);
      expect((await budgets.getCategoryBudgets()).single.id, 'cb');
      final settings = SqliteSettingsSyncStore(v3);
      final pendingBudgets = await settings.pendingRecords(
        const DataScope.personal(),
        CloudRecordKind.budgets,
      );
      expect(pendingBudgets, hasLength(2));
      final pendingCategories = await settings.pendingRecords(
        const DataScope.personal(),
        CloudRecordKind.categories,
      );
      // Only the custom category; built-ins exist on every device.
      expect(pendingCategories.map((p) => p.record.id), ['custom']);

      // The personal feed is read once more so archived totals are complete.
      expect(await store.getSetting(SyncKeys.pullCursorMicros), isNull);
      expect(await v3.db.query(Tables.archivedTotals), isEmpty);
    },
  );
}
