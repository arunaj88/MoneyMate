import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/budget_repository.dart';
import 'package:money_mate/repositories/settings_sync_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_cloud_store.dart';
import '../helpers/fakes.dart';

const me = 'uid-husband';
const partner = 'uid-wife';
const hid = 'house-1';
final now = DateTime.now();

DateTime daysAgo(int n) => DateTime(now.year, now.month, now.day - n, 9);

void main() {
  sqfliteFfiInit();

  late AppDatabase db;
  late SqliteTransactionRepository transactions;
  late SqliteBudgetRepository budgets;
  late SqliteLocalSyncStore local;
  late InMemoryCloudStore cloud;
  late InMemoryRecordStore records;
  late TransactionSyncService sync;

  const personalKey = me;
  const sharedKey = 'household:$hid';
  const personalPartition = CloudPartition.personal(me);
  final sharedPartition = CloudPartition.household(me, hid);

  setUp(() async {
    db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    transactions = SqliteTransactionRepository(db);
    budgets = SqliteBudgetRepository(db);
    local = SqliteLocalSyncStore(db);
    cloud = InMemoryCloudStore();
    records = InMemoryRecordStore();
    sync = TransactionSyncService(
      local: local,
      cloud: cloud,
      settings: SqliteSettingsSyncStore(db),
      records: records,
      clock: () => now,
    );
  });

  tearDown(() => db.close());

  TransactionModel shared(
    String id, {
    required DateTime date,
    int amount = 1000,
    String createdBy = me,
  }) => tx(
    id: id,
    amountMinor: amount,
    date: date,
    householdId: hid,
    createdBy: createdBy,
  );

  CloudTransaction fromPartner(
    String id, {
    required DateTime date,
    int amount = 2000,
    bool deleted = false,
    DateTime? updatedAt,
  }) => CloudTransaction(
    transaction: TransactionModel(
      id: id,
      type: TransactionType.expense,
      amountMinor: amount,
      categoryId: 'exp_groceries',
      date: date,
      createdAt: date,
      updatedAt: updatedAt ?? date,
      scope: TransactionScope.shared,
      householdId: hid,
      createdBy: partner,
      createdByName: 'Sara',
    ),
    deleted: deleted,
  );

  group('personal data isolation', () {
    test('personal and shared records go to separate collections', () async {
      await transactions.insert(
        tx(id: 'p1', amountMinor: 500, date: daysAgo(1)),
      );
      await transactions.insert(shared('s1', date: daysAgo(1)));

      final result = await sync.synchronize(me, householdId: hid);

      expect(result.outcome, SyncOutcome.completed);
      expect(cloud.docs(personalKey).keys, ['p1']);
      expect(cloud.docs(sharedKey).keys, ['s1']);

      final personalDoc = cloud.rawDoc(personalKey, 'p1')!;
      expect(personalDoc['scope'], 'personal');
      expect(personalDoc['ownerUid'], me);
      expect(personalDoc['createdBy'], me);
      expect(personalDoc.containsKey('householdId'), isFalse);

      final sharedDoc = cloud.rawDoc(sharedKey, 's1')!;
      expect(sharedDoc['scope'], 'shared');
      expect(sharedDoc['householdId'], hid);
      expect(sharedDoc['createdBy'], me);
      expect(sharedDoc['updatedBy'], me);
      expect(sharedDoc.containsKey('ownerUid'), isFalse);
    });

    test('without a household nothing is written to any household', () async {
      await transactions.insert(
        tx(id: 'p1', amountMinor: 500, date: daysAgo(1)),
      );
      await sync.synchronize(me);
      expect(cloud.docs(sharedKey), isEmpty);
      expect(cloud.docs(personalKey).keys, ['p1']);
    });

    test('queries only combine scopes when asked to', () async {
      await transactions.insert(
        tx(id: 'p1', amountMinor: 500, date: daysAgo(1)),
      );
      await transactions.insert(shared('s1', date: daysAgo(1), amount: 700));

      Future<List<String>> ids(ScopeFilter scope) async =>
          (await transactions.getTransactions(
            filter: TransactionFilter(scope: scope),
          )).map((t) => t.id).toList()..sort();

      expect(await ids(const ScopeFilter.personal()), ['p1']);
      expect(await ids(const ScopeFilter.shared(hid)), ['s1']);
      expect(await ids(const ScopeFilter.combined(hid)), ['p1', 's1']);
      expect(await ids(const ScopeFilter.shared('other-house')), isEmpty);

      // Combined totals count every transaction exactly once.
      expect(
        await transactions.sumAmount(
          type: TransactionType.expense,
          scope: const ScopeFilter.combined(hid),
        ),
        1200,
      );
      expect(await transactions.sumAmount(type: TransactionType.expense), 500);
    });

    test(
      'personal budgets stay private; shared budgets go to the household',
      () async {
        final monday = DateTime(2026, 11, 23);
        await budgets.setTarget(
          period: BudgetPeriod.weekly,
          amountMinor: 50000,
          effectiveFrom: monday,
        );
        await budgets.setTarget(
          period: BudgetPeriod.monthly,
          amountMinor: 300000,
          effectiveFrom: DateTime(2026, 11),
          scope: const DataScope.household(hid),
          updatedBy: me,
        );

        await sync.synchronize(me, householdId: hid);

        final personal = records.docs(
          personalPartition,
          CloudRecordKind.budgets,
        );
        final household = records.docs(
          sharedPartition,
          CloudRecordKind.budgets,
        );
        expect(personal.keys, [
          'target_weekly_${monday.millisecondsSinceEpoch}',
        ]);
        expect(household.keys, [
          'target_monthly_${DateTime(2026, 11).millisecondsSinceEpoch}',
        ]);
        expect(household.values.single.data['updatedBy'], me);
        expect(household.values.single.data['amountMinor'], 300000);
      },
    );
  });

  group('shared transactions', () {
    test("a partner's shared transaction syncs to this device", () async {
      cloud.putRemote(sharedKey, fromPartner('w1', date: daysAgo(2)));

      final result = await sync.synchronize(me, householdId: hid);

      expect(result.report.downloaded, 1);
      final row = await transactions.getById('w1');
      expect(row!.scope, TransactionScope.shared);
      expect(row.householdId, hid);
      expect(row.createdBy, partner);
      expect(row.createdByName, 'Sara');
      // Never shown as personal data.
      expect(await transactions.getTransactions(), isEmpty);
    });

    test('an edit by another member wins when it is newer', () async {
      await transactions.insert(shared('s1', date: daysAgo(2)));
      await sync.synchronize(me, householdId: hid);

      final edited = fromPartner(
        's1',
        date: daysAgo(2),
        amount: 4321,
        updatedAt: now.add(const Duration(minutes: 1)),
      );
      cloud.putRemote(
        sharedKey,
        CloudTransaction(
          transaction: edited.transaction.copyWith(createdBy: me),
        ),
      );
      await sync.synchronize(me, householdId: hid);

      expect((await transactions.getById('s1'))!.amountMinor, 4321);
    });

    test(
      'deleting a shared transaction soft-deletes it for everyone',
      () async {
        cloud.putRemote(sharedKey, fromPartner('w1', date: daysAgo(2)));
        await sync.synchronize(me, householdId: hid);

        await transactions.delete('w1');
        await sync.synchronize(me, householdId: hid);

        final doc = cloud.docs(sharedKey)['w1']!;
        expect(doc.deleted, isTrue);
        // The creator is preserved; the deleting member is recorded.
        expect(cloud.rawDoc(sharedKey, 'w1')!['createdBy'], partner);
        expect(cloud.rawDoc(sharedKey, 'w1')!['updatedBy'], me);
        expect(cloud.rawDoc(sharedKey, 'w1')!['deletedAt'], isA<int>());
      },
    );

    test(
      'a remote deletion in one scope never removes a row of another',
      () async {
        await transactions.insert(
          tx(id: 'x', amountMinor: 100, date: daysAgo(1)),
        );
        await sync.synchronize(me, householdId: hid);
        // The household collection has a deleted document with the same ID.
        cloud.putRemote(
          sharedKey,
          fromPartner('x', date: daysAgo(1), deleted: true),
        );

        await sync.synchronize(me, householdId: hid);

        final row = await transactions.getById('x');
        expect(row, isNotNull);
        expect(row!.scope, TransactionScope.personal);
      },
    );

    test('moving a personal transaction into the household', () async {
      await transactions.insert(
        tx(id: 'm', amountMinor: 800, date: daysAgo(3)),
      );
      await sync.synchronize(me, householdId: hid);
      expect(cloud.docs(personalKey)['m']!.deleted, isFalse);

      final moved = (await transactions.getById('m'))!.withScope(
        TransactionScope.shared,
        householdId: hid,
        updatedAt: now,
        updatedBy: me,
      );
      await transactions.update(moved.copyWith(createdBy: me));
      await sync.synchronize(me, householdId: hid);

      expect(cloud.docs(personalKey)['m']!.deleted, isTrue);
      expect(cloud.docs(sharedKey)['m']!.deleted, isFalse);
      expect(cloud.docs(sharedKey)['m']!.transaction.amountMinor, 800);
      final local = await transactions.getById('m');
      expect(local!.scope, TransactionScope.shared);
      expect(await transactionRowCount(db), 1);
    });
  });

  group('household access', () {
    test(
      'refused household access does not stop personal sync or delete data',
      () async {
        await transactions.insert(
          tx(id: 'p1', amountMinor: 500, date: daysAgo(1)),
        );
        await transactions.insert(shared('s1', date: daysAgo(1)));
        cloud.denied.add(sharedKey);

        final result = await sync.synchronize(me, householdId: hid);

        expect(result.outcome, SyncOutcome.completed);
        expect(result.report.householdsDenied, {hid});
        expect(cloud.docs(personalKey).keys, ['p1']);
        // The unsynced shared row is kept until access is confirmed lost.
        expect(await transactions.getById('s1'), isNotNull);
      },
    );

    test(
      'releasing a household keeps personal data and unsent own records',
      () async {
        await transactions.insert(
          tx(id: 'p1', amountMinor: 500, date: daysAgo(1)),
        );
        cloud.putRemote(sharedKey, fromPartner('w1', date: daysAgo(2)));
        await budgets.setTarget(
          period: BudgetPeriod.weekly,
          amountMinor: 1000,
          effectiveFrom: DateTime(2026, 11, 23),
          scope: const DataScope.household(hid),
        );
        await sync.synchronize(me, householdId: hid);
        // Created offline and never uploaded.
        await transactions.insert(shared('unsent', date: daysAgo(0)));

        final result = await sync.releaseHousehold(hid, uid: me);

        expect(result.kept, 1);
        expect(result.removed, 1);
        expect(await transactions.getById('w1'), isNull);
        final unsent = await transactions.getById('unsent');
        expect(unsent!.scope, TransactionScope.personal);
        expect(unsent.householdId, isNull);
        expect(await transactions.getById('p1'), isNotNull);
        expect(
          await budgets.getTargetVersions(
            BudgetPeriod.weekly,
            scope: const DataScope.household(hid),
          ),
          isEmpty,
        );
        // The household's cloud history is untouched.
        expect(cloud.docs(sharedKey)['w1']!.deleted, isFalse);
        // The kept record is uploaded as personal next time.
        await sync.synchronize(me);
        expect(cloud.docs(personalKey).keys, containsAll(['p1', 'unsent']));
      },
    );
  });

  group('90-day retention for shared data', () {
    test(
      'old verified shared rows leave the device; the cloud keeps them',
      () async {
        await transactions.insert(shared('recent', date: daysAgo(10)));
        await transactions.insert(
          shared('old', date: daysAgo(120), amount: 3000),
        );

        final result = await sync.synchronize(me, householdId: hid);

        expect(result.report.archivedLocally, 1);
        expect(await transactions.getById('old'), isNull);
        expect(await transactions.getById('recent'), isNotNull);
        expect(cloud.docs(sharedKey).keys, containsAll(['recent', 'old']));
        // Still counted in the household balance.
        final archived = await transactions.archivedTotals(
          scope: const ScopeFilter.shared(hid),
        );
        expect(archived.expense, 3000);
        expect(
          (await transactions.archivedTotals()).expense,
          0,
          reason: 'shared amounts never appear in personal totals',
        );
      },
    );

    test('pending or failed shared rows are never removed', () async {
      await transactions.insert(shared('old', date: daysAgo(120)));
      cloud.dropWrites.add('old');

      await sync.synchronize(me, householdId: hid);

      expect(await transactions.getById('old'), isNotNull);
      final counts = await local.countUnsynced(
        scope: const DataScope.household(hid),
      );
      expect(counts.failed, 1);
    });

    test('a pending personal change does not block shared clean-up and vice '
        'versa', () async {
      await transactions.insert(
        tx(id: 'p-old', amountMinor: 100, date: daysAgo(150)),
      );
      await transactions.insert(shared('s-old', date: daysAgo(150)));
      cloud.dropWrites.add('p-old');

      await sync.synchronize(me, householdId: hid);

      expect(await transactions.getById('p-old'), isNotNull);
      expect(await transactions.getById('s-old'), isNull);
    });

    test(
      'old shared records are loaded from cloud history on request',
      () async {
        cloud.putRemote(sharedKey, fromPartner('w-old', date: daysAgo(200)));
        await sync.synchronize(me, householdId: hid);
        expect(await transactions.getById('w-old'), isNull);

        final history = await sync.loadHistory(
          sharedPartition,
          filter: const TransactionFilter(scope: ScopeFilter.shared(hid)),
          categoryNames: const {'exp_groceries': 'Groceries'},
        );
        expect(history.transactions.map((t) => t.id), ['w-old']);
        expect(history.transactions.single.isShared, isTrue);
        // Counted once in the archived balance.
        expect(
          (await transactions.archivedTotals(
            scope: const ScopeFilter.shared(hid),
          )).expense,
          2000,
        );
      },
    );
  });

  group('existing data', () {
    test(
      'legacy personal cloud documents get their ownership fields',
      () async {
        // Written by the previous app version: no scope / owner fields.
        cloud.putRemote(
          personalKey,
          CloudTransaction(
            transaction: tx(id: 'legacy', amountMinor: 100, date: daysAgo(5)),
            isLegacy: true,
          ),
        );
        await sync.synchronize(me);
        expect(cloud.backfilled['legacy'], {
          'scope': 'personal',
          'ownerUid': me,
          'createdBy': me,
        });
        expect(await transactions.getById('legacy'), isNotNull);
      },
    );

    test('shared budgets from a partner are applied locally', () async {
      records.putRemote(
        sharedPartition,
        CloudRecordKind.budgets,
        CloudRecord(
          id: 'target_monthly_1',
          data: {
            'kind': 'target',
            'period': 'monthly',
            'amountMinor': 250000,
            'effectiveFrom': DateTime(2026, 11).millisecondsSinceEpoch,
            'updatedBy': partner,
          },
          updatedAtMs: 10,
        ),
      );
      final result = await sync.synchronize(me, householdId: hid);
      expect(result.report.budgetsDownloaded, 1);
      final versions = await budgets.getTargetVersions(
        BudgetPeriod.monthly,
        scope: const DataScope.household(hid),
      );
      expect(versions.single.amountMinor, 250000);
      expect(versions.single.updatedBy, partner);
      expect(await budgets.getTargetVersions(BudgetPeriod.monthly), isEmpty);
    });

    test(
      'a newer local shared budget is not overwritten by an older one',
      () async {
        final from = DateTime(2026, 11);
        await budgets.setTarget(
          period: BudgetPeriod.monthly,
          amountMinor: 999,
          effectiveFrom: from,
          scope: const DataScope.household(hid),
        );
        records.putRemote(
          sharedPartition,
          CloudRecordKind.budgets,
          CloudRecord(
            id: 'target_monthly_${from.millisecondsSinceEpoch}',
            data: {
              'kind': 'target',
              'period': 'monthly',
              'amountMinor': 1,
              'effectiveFrom': from.millisecondsSinceEpoch,
            },
            updatedAtMs: 1,
          ),
        );
        await sync.synchronize(me, householdId: hid);
        final versions = await budgets.getTargetVersions(
          BudgetPeriod.monthly,
          scope: const DataScope.household(hid),
        );
        expect(versions.single.amountMinor, 999);
        expect(
          records
              .docs(sharedPartition, CloudRecordKind.budgets)
              .values
              .single
              .data['amountMinor'],
          999,
        );
      },
    );

    test('deleting a shared category budget reaches the household', () async {
      final budget = CategoryBudget(
        id: 'cb1',
        categoryId: 'exp_food',
        period: BudgetPeriod.weekly,
        amountMinor: 5000,
        createdAt: now,
        updatedAt: now,
        householdId: hid,
      );
      await budgets.upsertCategoryBudget(budget);
      await sync.synchronize(me, householdId: hid);
      expect(
        records
            .docs(sharedPartition, CloudRecordKind.budgets)['category_cb1']!
            .deleted,
        isFalse,
      );

      await budgets.deleteCategoryBudget('cb1');
      await sync.synchronize(me, householdId: hid);

      expect(
        records
            .docs(sharedPartition, CloudRecordKind.budgets)['category_cb1']!
            .deleted,
        isTrue,
      );
      expect(
        await budgets.getCategoryBudgets(scope: const DataScope.household(hid)),
        isEmpty,
      );
    });
  });

  test('sync keys keep the original personal cursor', () {
    expect(
      SyncKeys.cursorMicros(const DataScope.personal()),
      SyncKeys.pullCursorMicros,
    );
    expect(
      SyncKeys.cursorMicros(const DataScope.household(hid)),
      isNot(SyncKeys.pullCursorMicros),
    );
  });
}

Future<int> transactionRowCount(AppDatabase db) async =>
    ((await db.db.rawQuery(
          'SELECT COUNT(*) AS n FROM ${Tables.transactions}',
        )).first['n']
        as int?) ??
    0;
