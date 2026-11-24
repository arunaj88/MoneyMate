import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  late AppDatabase database;
  late SqliteLocalSyncStore store;
  final resetAt = DateTime(2026, 11, 23, 12);

  Future<void> insertTx(
    String id, {
    String scope = 'personal',
    String? household,
    String category = 'exp_food',
    required DateTime updatedAt,
    String status = 'synced',
  }) => database.db.insert(Tables.transactions, {
    'id': id,
    'type': 'expense',
    'amount_minor': 100,
    'category_id': category,
    'date': updatedAt.millisecondsSinceEpoch,
    'note': '',
    'payment_method': 'cash',
    'created_at': updatedAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'scope': scope,
    'household_id': household,
    'sync_status': status,
  });

  Future<void> setting(String key, String value) =>
      database.db.insert(Tables.appSettings, {'key': key, 'value': value});

  Future<List<String>> ids(String table, {String column = 'id'}) async => [
    for (final r in await database.db.query(table, orderBy: column))
      r[column]! as String,
  ];

  setUp(() async {
    database = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    store = SqliteLocalSyncStore(database);
    final old = DateTime(2026, 11, 1);
    for (final id in ['cat_pets', 'cat_shared_use']) {
      await database.db.insert(Tables.categories, {
        ...CategoryModel(
          id: id,
          name: id,
          type: TransactionType.expense,
          iconKey: 'pets',
          colorValue: 1,
        ).toMap(),
        'updated_at': old.millisecondsSinceEpoch,
      });
    }
    // A built-in category the user renamed.
    await database.db.update(
      Tables.categories,
      {'name': 'Takeaway', 'updated_at': old.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: ['exp_food'],
    );
    await insertTx('p-synced', category: 'cat_pets', updatedAt: old);
    await insertTx('p-pending', updatedAt: old, status: 'pending');
    await insertTx(
      's-1',
      scope: 'shared',
      household: 'house-1',
      category: 'cat_shared_use',
      updatedAt: old,
    );
    await database.db.insert(Tables.syncTombstones, {
      'id': 'gone',
      'household_id': '',
      'deleted_at': old.millisecondsSinceEpoch,
    });
    await database.db.insert(Tables.archivedTotals, {
      'id': 'arch',
      'household_id': '',
      'type': 'expense',
      'amount_minor': 500,
    });
    await setting(SyncKeys.ownerUid, 'uid-1');
    await setting(SyncKeys.retentionDays, '90');
    await setting(SyncKeys.pullCursorMicros, '123');
    await setting(SyncKeys.lastSyncedAt, '456');
    await setting('alert.p.20261101', 'warning');
    await setting('alert.h.house-1.20261101', 'warning');
  });

  tearDown(() => database.close());

  test('removes personal data and keeps shared data and essentials', () async {
    await store.clearPersonalData(resetAt: resetAt);

    expect(await ids(Tables.transactions), ['s-1']);
    expect(await ids(Tables.syncTombstones), isEmpty);
    expect(await ids(Tables.archivedTotals), isEmpty);
    final categories = await ids(Tables.categories);
    expect(categories, isNot(contains('cat_pets')));
    // Still used by a shared transaction.
    expect(categories, contains('cat_shared_use'));
    expect(categories, containsAll(DefaultCategories.all.map((c) => c.id)));
    final food = await database.db.query(
      Tables.categories,
      where: 'id = ?',
      whereArgs: ['exp_food'],
    );
    expect(
      food.single['name'],
      DefaultCategories.all.firstWhere((c) => c.id == 'exp_food').name,
    );

    final keys = await ids(Tables.appSettings, column: 'key');
    expect(keys, containsAll([SyncKeys.ownerUid, SyncKeys.retentionDays]));
    expect(keys, contains('alert.h.house-1.20261101'));
    expect(
      keys,
      isNot(
        anyOf(
          contains(SyncKeys.pullCursorMicros),
          contains(SyncKeys.lastSyncedAt),
          contains('alert.p.20261101'),
        ),
      ),
    );
    expect(
      await store.getSetting(SyncKeys.personalResetAt),
      resetAt.millisecondsSinceEpoch.toString(),
    );
    expect(await store.countUnsynced(), (pending: 0, failed: 0));
  });

  test('also drops a household the user left during the reset', () async {
    await store.clearPersonalData(resetAt: resetAt, householdId: 'house-1');
    expect(await ids(Tables.transactions), isEmpty);
    expect(await ids(Tables.categories), isNot(contains('cat_shared_use')));
    expect(
      await ids(Tables.appSettings, column: 'key'),
      isNot(contains('alert.h.house-1.20261101')),
    );
  });

  test('with a cut-off, records changed after the reset stay', () async {
    await insertTx(
      'p-new',
      updatedAt: resetAt.add(const Duration(minutes: 5)),
      status: 'pending',
    );
    await store.clearPersonalData(resetAt: resetAt, changedBefore: resetAt);
    expect(await ids(Tables.transactions), ['p-new', 's-1']);
  });
}
