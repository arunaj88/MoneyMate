import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/connectivity_monitor.dart';
import 'package:money_mate/core/services/data_reset_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/reset_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/repositories/app_settings_repository.dart';
import 'package:money_mate/repositories/budget_repository.dart';
import 'package:money_mate/repositories/category_repository.dart';
import 'package:money_mate/repositories/settings_sync_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_cloud_store.dart';
import '../helpers/fake_household_service.dart';
import '../helpers/fakes.dart';

class _Connectivity implements ConnectivityMonitor {
  final controller = StreamController<bool>.broadcast();
  bool online = true;

  @override
  Future<bool> isOnline() async => online;

  @override
  Stream<bool> get onlineChanges => controller.stream;

  void set(bool value) {
    online = value;
    controller.add(value);
  }
}

/// The real service with a switchable SQLite failure.
class _ResetService extends SyncDataResetService {
  _ResetService(super.sync);

  bool deviceError = false;
  int deviceCalls = 0;

  @override
  Future<void> clearDevice() {
    deviceCalls++;
    if (deviceError) throw StateError('disk I/O error');
    return super.clearDevice();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late AppDatabase db;
  late SharedPreferences prefs;
  late SqliteTransactionRepository txRepo;
  late SqliteCategoryRepository categoryRepo;
  late SqliteBudgetRepository budgetRepo;
  late InMemoryCloudStore cloud;
  late InMemoryRecordStore records;
  late _Connectivity connectivity;
  late TransactionSyncService syncService;
  late FakeHouseholdService households;
  late AuthProvider auth;
  late HouseholdProvider household;
  late TransactionScopeProvider scope;
  late SettingsProvider settings;
  late CategoryProvider categories;
  late TransactionProvider transactions;
  late BudgetProvider budgets;
  late SyncProvider sync;
  late _ResetService service;
  late ResetProvider reset;
  late ResetTargets targets;

  final now = DateTime.now();
  const partnerUid = 'uid-sara';
  const personalKey = 'uid-1';
  const sharedKey = 'household:house-2';

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void wire() {
    scope.updateHousehold(household);
    transactions.onScopeChanged(scope);
    budgets.updateDependencies(settings, categories, transactions, household);
    sync.updateDependencies(
      auth,
      categories,
      transactions,
      household: household,
      budgets: budgets,
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    txRepo = SqliteTransactionRepository(db);
    categoryRepo = SqliteCategoryRepository(db);
    budgetRepo = SqliteBudgetRepository(db);
    cloud = InMemoryCloudStore();
    records = InMemoryRecordStore();
    connectivity = _Connectivity();
    syncService = TransactionSyncService(
      local: SqliteLocalSyncStore(db),
      cloud: cloud,
      settings: SqliteSettingsSyncStore(db),
      records: records,
    );
    households = FakeHouseholdService(uid: testUser.uid);
    auth = AuthProvider(FakeAuthService(signedIn: testUser), prefs);
    await settle();
    household = HouseholdProvider(service: households, preferences: prefs)
      ..updateAuth(auth);
    scope = TransactionScopeProvider(prefs);
    settings = SettingsProvider(prefs);
    categories = CategoryProvider(categoryRepo);
    await categories.load();
    transactions = TransactionProvider(txRepo);
    await transactions.load();
    budgets = BudgetProvider(
      budgetRepository: budgetRepo,
      transactionRepository: txRepo,
      appSettingsRepository: SqliteAppSettingsRepository(db),
    );
    sync = SyncProvider(
      service: syncService,
      connectivity: connectivity,
      changeDebounce: const Duration(milliseconds: 10),
    );
    service = _ResetService(syncService);
    reset = ResetProvider(service);
    targets = ResetTargets(
      auth: auth,
      household: household,
      sync: sync,
      scope: scope,
      categories: categories,
      transactions: transactions,
      budgets: budgets,
    );
    await settle();
    wire();
    await settle();
  });

  tearDown(() async {
    reset.dispose();
    sync.dispose();
    household.dispose();
    auth.dispose();
    await db.close();
  });

  const custom = CategoryModel(
    id: 'cat_pets',
    name: 'Pets',
    type: TransactionType.expense,
    iconKey: 'pets',
    colorValue: 0xFF795548,
  );

  /// Personal data backed up to the cloud: a transaction from today, one
  /// from last year (older than the retention window), a custom category,
  /// a budget target and changed preferences.
  Future<void> seedPersonal() async {
    await categoryRepo.insert(custom);
    await categories.load();
    await transactions.addTransaction(
      type: TransactionType.expense,
      amountMinor: 1200,
      categoryId: custom.id,
      date: now,
    );
    await budgetRepo.setTarget(
      period: BudgetPeriod.monthly,
      amountMinor: 500000,
      effectiveFrom: DateTime(now.year, now.month),
    );
    await settings.setCurrency('USD');
    wire();
    await sync.syncNow();
    await settle();
    cloud.putRemote(
      personalKey,
      CloudTransaction(
        transaction: tx(
          id: 'last-year',
          amountMinor: 9000,
          date: DateTime(now.year - 1, now.month, 1),
        ),
      ),
    );
    await sync.syncNow();
    await settle();
    expect(cloud.docs(personalKey), hasLength(2));
  }

  Map<String, int> versions(Map<String, Object> docs) => {
    for (final MapEntry(:key, :value) in docs.entries)
      key: switch (value) {
        CloudTransaction(:final updatedAtMs) => updatedAtMs,
        CloudRecord(:final updatedAtMs) => updatedAtMs,
        _ => -1,
      },
  };

  /// Everything stored in the fake Firestore (document versions and the
  /// write count), to prove a reset or restore left it alone.
  Map<String, Object> snapshot() => {
    for (final key in [personalKey, partnerUid, sharedKey])
      'tx/$key': versions(cloud.docs(key)),
    for (final p in [
      CloudPartition.personal(testUser.uid),
      CloudPartition.household(testUser.uid, 'house-2'),
    ])
      for (final kind in CloudRecordKind.values)
        '${p.key}/${kind.name}': versions(records.docs(p, kind)),
    'writes': cloud.writes,
  };

  /// Every transaction on the device, personal and shared.
  Future<List<TransactionModel>> allRows() async => [
    for (final row in await db.db.query('transactions', orderBy: 'id'))
      TransactionModel.fromMap(row),
  ];

  Future<int> count(String table) async => (await db.db.query(table)).length;

  Future<void> expectFreshDevice() async {
    expect(await allRows(), isEmpty);
    expect(transactions.transactions, isEmpty);
    for (final table in [
      Tables.budgets,
      Tables.categoryBudgets,
      Tables.syncTombstones,
      Tables.cloudTombstones,
      Tables.archivedTotals,
    ]) {
      expect(await count(table), 0, reason: table);
    }
    expect(categories.byId.containsKey(custom.id), isFalse);
    expect(
      categories.byId.keys.toSet(),
      DefaultCategories.all.map((c) => c.id).toSet(),
    );
    expect(
      budgets.setFor(const DataScope.personal())?.monthly.hasTarget ?? false,
      isFalse,
    );
    expect(sync.pendingCount, 0);
    expect(scope.view, ViewScope.personal);
    expect(reset.restorePending, isTrue);
    // Still signed in; preferences kept.
    expect(auth.isAuthenticated, isTrue);
    expect(auth.user?.uid, testUser.uid);
    expect(settings.currencyCode, 'USD');
    expect(sync.isPaused, isFalse);
  }

  group('Reset App', () {
    test('clears the device online and leaves Firestore unchanged', () async {
      await seedPersonal();
      final before = snapshot();

      expect(await reset.reset(targets), isTrue);
      await settle();

      await expectFreshDevice();
      expect(reset.error, isNull);
      expect(reset.isRunning, isFalse);
      // No document deleted, changed or added (sync ran after the reset).
      expect(snapshot(), before);
      expect(sync.lastSyncedAt, isNotNull);
    });

    test('works offline', () async {
      await seedPersonal();
      final before = snapshot();
      connectivity.set(false);
      cloud.offline = true;
      records.offline = true;
      await settle();

      expect(await reset.reset(targets), isTrue);
      await settle();
      await expectFreshDevice();

      cloud.offline = false;
      records.offline = false;
      connectivity.set(true);
      await settle();
      expect(snapshot(), before);
    });

    test('keeps the schema, account link and configuration', () async {
      await seedPersonal();
      final local = SqliteLocalSyncStore(db);
      await local.setSetting(SyncKeys.retentionDays, '120');
      await local.setSetting('alert.monthly', '1');
      expect(await local.getSetting(SyncKeys.pullCursorMicros), isNotNull);

      expect(await reset.reset(targets), isTrue);

      expect(await db.db.getVersion(), AppConstants.databaseVersion);
      expect(await local.getSetting(SyncKeys.ownerUid), testUser.uid);
      expect(await local.getSetting(SyncKeys.retentionDays), '120');
      expect(await local.getSetting('installed_at'), isNotNull);
      expect(await local.getSetting(SyncKeys.pullCursorMicros), isNull);
      expect(await local.getSetting(SyncKeys.lastSyncedAt), isNotNull);
      expect(await local.getSetting('alert.monthly'), isNull);
      expect(await local.getSetting(SyncKeys.restorePending), isNotNull);
    });

    test('changes waiting to upload are discarded, never uploaded', () async {
      await seedPersonal();
      connectivity.set(false);
      await settle();
      await transactions.addTransaction(
        type: TransactionType.income,
        amountMinor: 9900,
        categoryId: 'inc_salary',
        date: now,
      );
      final synced = transactions.transactions.firstWhere(
        (t) => t.amountMinor == 1200,
      );
      await transactions.deleteTransaction(synced.id);
      wire();
      await settle();
      expect(sync.pendingCount, 2);
      final before = snapshot();

      expect(await reset.reset(targets), isTrue);
      connectivity.set(true);
      await settle();
      await sync.syncNow();

      await expectFreshDevice();
      // The deletion did not reach the cloud, nor did the new record.
      expect(snapshot(), before);
      expect(cloud.docs(personalKey)[synced.id]?.deleted, isFalse);
    });

    test(
      'stays empty after a restart; automatic sync downloads nothing',
      () async {
        await seedPersonal();
        expect(await reset.reset(targets), isTrue);
        await settle();
        // Another device adds a record after the reset.
        cloud.putRemote(
          personalKey,
          CloudTransaction(
            transaction: tx(id: 'other-device', amountMinor: 50, date: now),
          ),
        );

        // "Restart": new providers on the same database.
        final reopened = ResetProvider(_ResetService(syncService));
        addTearDown(reopened.dispose);
        await settle();
        expect(reopened.restorePending, isTrue);

        await sync.syncNow();
        final result = await syncService.synchronize(testUser.uid);
        expect(result.outcome, SyncOutcome.completed);
        expect(result.report.restorePending, isTrue);
        expect(result.report.downloaded, 0);
        expect(result.report.budgetsDownloaded, 0);
        expect(result.report.categoriesDownloaded, 0);
        await expectFreshDevice();

        // Cloud history (older records) stays hidden as well.
        final history = await syncService.loadHistory(
          CloudPartition.personal(testUser.uid),
          filter: const TransactionFilter(),
          categoryNames: const {},
        );
        expect(history.transactions, isEmpty);
        expect(history.hasMore, isFalse);
      },
    );

    test('new records after a reset are still backed up', () async {
      await seedPersonal();
      expect(await reset.reset(targets), isTrue);
      await settle();

      await transactions.addTransaction(
        type: TransactionType.expense,
        amountMinor: 300,
        categoryId: 'exp_food',
        date: now,
      );
      wire();
      await sync.syncNow();
      await settle();

      expect(cloud.docs(personalKey), hasLength(3));
      expect(await allRows(), hasLength(1));
      expect(sync.statusLabel, SyncStatusLabel.synced);
    });

    test('a SQLite failure changes nothing and can be retried', () async {
      await seedPersonal();
      service.deviceError = true;
      expect(await reset.reset(targets), isFalse);
      expect(reset.error, contains('Nothing was changed'));
      expect(reset.restorePending, isFalse);
      expect(reset.isRunning, isFalse);
      expect(sync.isPaused, isFalse);
      expect(await allRows(), hasLength(1));
      expect(categories.byId.containsKey(custom.id), isTrue);

      service.deviceError = false;
      expect(await reset.reset(targets), isTrue);
      await settle();
      await expectFreshDevice();
    });

    test('repeated requests while a reset runs are ignored', () async {
      await seedPersonal();
      final first = reset.reset(targets);
      expect(reset.isRunning, isTrue);
      expect(await reset.reset(targets), isFalse);
      expect(await reset.restore(targets), isFalse);
      expect(await first, isTrue);
      expect(service.deviceCalls, 1);
    });
  });

  group('Restore My Cloud Data', () {
    test(
      'restores records with their original IDs, without duplicates',
      () async {
        await seedPersonal();
        final ids = cloud.docs(personalKey).keys.toSet();
        expect(await reset.reset(targets), isTrue);
        await settle();
        final before = snapshot();

        final progress = <RestoreProgress>[];
        reset.addListener(() {
          final p = reset.restoreProgress;
          if (p != null) progress.add(p);
        });
        expect(await reset.restore(targets), isTrue);
        await settle();

        expect(reset.restorePending, isFalse);
        expect(reset.error, isNull);
        expect(progress, isNotEmpty);
        expect(progress.last.downloaded, greaterThan(0));
        // Within the retention window: on the device with the cloud ID.
        final rows = await allRows();
        expect(rows.map((t) => t.id), [
          ids.firstWhere((id) => id != 'last-year'),
        ]);
        expect(rows.single.categoryId, custom.id);
        // Older: stays in the cloud, still counted in all-time totals.
        expect(await count(Tables.archivedTotals), 1);
        expect(categories.byId.containsKey(custom.id), isTrue);
        expect(
          budgets.setFor(const DataScope.personal())?.monthly.hasTarget,
          isTrue,
        );
        expect(transactions.transactions, hasLength(1));
        // Restoring wrote nothing to the cloud.
        expect(snapshot(), before);

        // Again: still no duplicates.
        expect(await reset.restore(targets), isTrue);
        expect(await allRows(), hasLength(1));
        expect(await count(Tables.archivedTotals), 1);
        expect(await count(Tables.budgets), 1);
      },
    );

    test('an interrupted restore stays pending and can be retried', () async {
      await seedPersonal();
      expect(await reset.reset(targets), isTrue);
      await settle();

      // Offline before anything is read.
      connectivity.set(false);
      cloud.offline = true;
      expect(await reset.restore(targets), isFalse);
      expect(reset.error, contains('offline'));
      expect(reset.restorePending, isTrue);

      // Transactions arrive, then budgets and categories fail.
      cloud.offline = false;
      records.offline = true;
      connectivity.set(true);
      expect(await reset.restore(targets), isFalse);
      expect(reset.restorePending, isTrue);
      expect(await allRows(), hasLength(1));
      // Automatic sync still downloads nothing while pending.
      await sync.syncNow();

      records.offline = false;
      expect(await reset.restore(targets), isTrue);
      expect(reset.restorePending, isFalse);
      expect(await allRows(), hasLength(1));
      expect(categories.byId.containsKey(custom.id), isTrue);
    });

    test('normal synchronisation resumes afterwards', () async {
      await seedPersonal();
      expect(await reset.reset(targets), isTrue);
      expect(await reset.restore(targets), isTrue);
      await settle();

      cloud.putRemote(
        personalKey,
        CloudTransaction(
          transaction: tx(id: 'later', amountMinor: 75, date: now),
        ),
      );
      await sync.syncNow();
      await settle();
      expect((await allRows()).map((t) => t.id), contains('later'));
      expect(sync.statusLabel, SyncStatusLabel.synced);
      expect(auth.isAuthenticated, isTrue);
    });

    test('requires a signed-in user', () async {
      await auth.signOut();
      await settle();
      expect(await reset.restore(targets), isFalse);
      expect(reset.error, contains('Sign in'));
    });
  });

  group('with a household', () {
    Future<void> joinPartnersHousehold() async {
      households.codes['K7QM2XRP9D'] = const Household(
        id: 'house-2',
        name: 'Sara & Sam',
        ownerUid: partnerUid,
      );
      expect(await household.acceptInvitation('K7QM2XRP9D'), isTrue);
      await settle();
      cloud.putRemote(
        sharedKey,
        CloudTransaction(
          transaction: tx(
            id: 'shared-sara',
            amountMinor: 4500,
            date: now,
            householdId: 'house-2',
            createdBy: partnerUid,
          ),
        ),
      );
      cloud.putRemote(
        partnerUid,
        CloudTransaction(
          transaction: tx(id: 'sara-private', amountMinor: 700, date: now),
        ),
      );
      wire();
      await sync.syncNow();
      await settle();
      expect((await allRows()).map((t) => t.id), contains('shared-sara'));
    }

    test('reset clears cached shared data but keeps the membership', () async {
      await seedPersonal();
      await joinPartnersHousehold();
      final before = snapshot();

      expect(await reset.reset(targets), isTrue);
      await settle();

      await expectFreshDevice();
      expect(household.householdId, 'house-2');
      expect(households.calls, isNot(contains('leave')));
      expect(households.calls, isNot(contains('delete')));
      expect(snapshot(), before);

      // Switching to the household view shows nothing stale.
      await scope.setView(ViewScope.shared);
      wire();
      await settle();
      expect(transactions.transactions, isEmpty);
    });

    test('restore includes shared data for an active member', () async {
      await seedPersonal();
      await joinPartnersHousehold();
      expect(await reset.reset(targets), isTrue);
      await settle();

      expect(await reset.restore(targets), isTrue);
      final rows = await allRows();
      expect(rows.map((t) => t.id), contains('shared-sara'));
      expect(rows.firstWhere((t) => t.id == 'shared-sara').isShared, isTrue);
      // Another user's personal data is never downloaded.
      expect(rows.map((t) => t.id), isNot(contains('sara-private')));
    });

    test('restore skips a household the user may no longer read', () async {
      await seedPersonal();
      await joinPartnersHousehold();
      expect(await reset.reset(targets), isTrue);
      await settle();
      cloud.denied.add(sharedKey);
      records.denied.add(sharedKey);

      expect(await reset.restore(targets), isTrue);
      final rows = await allRows();
      expect(rows.where((t) => t.isShared), isEmpty);
      expect(rows.where((t) => t.isPersonal), hasLength(1));
      expect(reset.restorePending, isFalse);
    });
  });

  test('an unreadable reset marker does not stop sync', () async {
    cloud.userDocDenied = true;
    await transactions.addTransaction(
      type: TransactionType.expense,
      amountMinor: 1200,
      categoryId: 'exp_food',
      date: now,
    );
    final result = await syncService.synchronize(testUser.uid);
    expect(result.outcome, SyncOutcome.completed);
    expect(cloud.docs(personalKey), hasLength(1));
  });
}
