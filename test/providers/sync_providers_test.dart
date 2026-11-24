import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/cloud_history_loader.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/core/services/connectivity_monitor.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_cloud_store.dart';
import '../helpers/fake_household_service.dart';
import '../helpers/fakes.dart';

class FakeConnectivity implements ConnectivityMonitor {
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

class FakeHistory implements TransactionHistorySource {
  FakeHistory(this.pages);

  final List<List<TransactionModel>> pages;
  bool available = true;
  bool offline = false;
  final List<TransactionFilter> requests = [];

  @override
  bool get isAvailable => available;

  @override
  Future<DateTime> localCutoff() async => DateTime(2026, 8, 25);

  @override
  Future<HistoryResult> loadOlder({
    required TransactionFilter filter,
    required Map<String, String> categoryNames,
    Object? cursor,
  }) async {
    requests.add(filter);
    if (offline) throw const CloudUnavailableException('offline');
    final index = (cursor as int?) ?? 0;
    return HistoryResult(
      transactions: pages[index],
      cursor: index + 1,
      hasMore: index + 1 < pages.length,
      categoriesAdded: false,
    );
  }

  @override
  Future<OlderTransactions> olderTransactions({
    required ScopeFilter scope,
    required DateTime start,
    required Map<String, String> categoryNames,
    required int version,
  }) async {
    if (offline) throw const CloudUnavailableException('offline');
    return OlderTransactions(
      items: [for (final p in pages) ...p],
      cutoff: await localCutoff(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('TransactionProvider with cloud history', () {
    late InMemoryTransactionRepository repo;
    late FakeHistory history;
    late TransactionProvider provider;

    setUp(() async {
      repo = InMemoryTransactionRepository(
        initial: [
          tx(id: 'local', amountMinor: 100, date: DateTime(2026, 11, 20)),
          tx(id: 'both', amountMinor: 200, date: DateTime(2026, 8, 1)),
        ],
      );
      history = FakeHistory([
        [
          tx(id: 'both', amountMinor: 999, date: DateTime(2026, 8, 1)),
          tx(id: 'old1', amountMinor: 300, date: DateTime(2026, 7, 1)),
        ],
        [tx(id: 'old2', amountMinor: 400, date: DateTime(2026, 5, 1))],
      ]);
      provider = TransactionProvider(repo, history: history);
      await provider.load();
    });

    test('merges cloud records without duplicates', () async {
      await provider.loadCloudHistory();
      expect(provider.transactions.map((t) => t.id), ['local', 'both', 'old1']);
      // The local version wins over the cloud copy with the same ID.
      expect(
        provider.transactions.firstWhere((t) => t.id == 'both').amountMinor,
        200,
      );
      expect(provider.isCloudOnly('old1'), isTrue);
      expect(provider.isCloudOnly('both'), isFalse);
      expect(provider.historyStatus, CloudHistoryStatus.loaded);

      await provider.loadCloudHistory();
      expect(provider.transactions.map((t) => t.id).last, 'old2');
      expect(provider.historyStatus, CloudHistoryStatus.exhausted);
    });

    test('editing a cloud-only record stores it locally', () async {
      await provider.loadCloudHistory();
      final old = provider.transactions.firstWhere((t) => t.id == 'old1');
      await provider.updateTransaction(old.copyWith(amountMinor: 350));

      expect(provider.isCloudOnly('old1'), isFalse);
      expect((await repo.getById('old1'))!.amountMinor, 350);
      expect(provider.transactions.where((t) => t.id == 'old1'), hasLength(1));
    });

    test('deleting a cloud-only record removes it from the list', () async {
      await provider.loadCloudHistory();
      await provider.deleteTransaction('old1');
      expect(provider.transactions.map((t) => t.id), ['local', 'both']);
    });

    test('offline shows a message and can retry', () async {
      history.offline = true;
      await provider.loadCloudHistory();
      expect(provider.historyStatus, CloudHistoryStatus.offline);
      expect(provider.historyMessage, contains('offline'));
      expect(provider.transactions, hasLength(2));

      history.offline = false;
      await provider.loadCloudHistory();
      expect(provider.transactions, hasLength(3));
    });

    test('a date filter before the local window loads history', () async {
      await provider.setFilter(TransactionFilter(start: DateTime(2026, 1, 1)));
      expect(history.requests, hasLength(1));

      // A filter inside the window does not touch the cloud.
      await provider.setFilter(TransactionFilter(start: DateTime(2026, 11, 1)));
      expect(history.requests, hasLength(1));
      expect(provider.isCloudOnly('old1'), isFalse);
    });

    test('hidden without a signed-in account', () {
      history.available = false;
      expect(provider.canLoadCloudHistory, isFalse);
    });
  });

  group('SyncProvider', () {
    late AppDatabase db;
    late SqliteTransactionRepository repo;
    late InMemoryCloudStore cloud;
    late FakeConnectivity connectivity;
    late AuthProvider auth;
    late CategoryProvider categories;
    late TransactionProvider transactions;
    late SyncProvider sync;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
      repo = SqliteTransactionRepository(db);
      cloud = InMemoryCloudStore();
      connectivity = FakeConnectivity();
      auth = AuthProvider(
        FakeAuthService(signedIn: testUser),
        await SharedPreferences.getInstance(),
      );
      categories = CategoryProvider(InMemoryCategoryRepository());
      transactions = TransactionProvider(repo);
      sync = SyncProvider(
        service: TransactionSyncService(
          local: SqliteLocalSyncStore(db),
          cloud: cloud,
        ),
        connectivity: connectivity,
        changeDebounce: const Duration(milliseconds: 10),
      );
      await pumpEventQueue();
    });

    tearDown(() async {
      sync.dispose();
      auth.dispose();
      await db.close();
    });

    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test('syncs the household and releases it when access ends', () async {
      final households = FakeHouseholdService(uid: testUser.uid);
      final household = HouseholdProvider(
        service: households,
        preferences: await SharedPreferences.getInstance(),
      )..updateAuth(auth);
      addTearDown(household.dispose);
      await household.createHousehold('Home');
      await settle();

      await repo.insert(tx(id: 'p', amountMinor: 100, date: DateTime.now()));
      await repo.insert(
        tx(
          id: 's',
          amountMinor: 200,
          date: DateTime.now(),
          householdId: 'house-1',
          createdBy: testUser.uid,
        ),
      );
      sync.updateDependencies(
        auth,
        categories,
        transactions,
        household: household,
      );
      await settle();
      expect(cloud.docs(testUser.uid).keys, ['p']);
      expect(cloud.docs('household:house-1').keys, ['s']);
      expect(sync.statusLabel, SyncStatusLabel.synced);

      // The owner removes this user: confirmed by the server.
      households.removeCurrentUser();
      await settle();
      sync.updateDependencies(
        auth,
        categories,
        transactions,
        household: household,
      );
      await settle();

      expect(await repo.getById('s'), isNull);
      expect(await repo.getById('p'), isNotNull);
      expect(sync.lastRelease?.removed, 1);
      // The household's cloud history is not touched.
      expect(cloud.docs('household:house-1')['s']!.deleted, isFalse);
    });

    test('syncs after sign-in and after local changes', () async {
      await repo.insert(tx(id: 'a', amountMinor: 100, date: DateTime.now()));
      sync.updateDependencies(auth, categories, transactions);
      await settle();

      expect(sync.phase, SyncPhase.idle);
      expect(cloud.docs(testUser.uid).keys, ['a']);
      expect(sync.pendingCount, 0);
      expect(sync.lastSyncedAt, isNotNull);
      expect(sync.retentionDays, 90);

      await transactions.addTransaction(
        type: TransactionType.expense,
        amountMinor: 250,
        categoryId: 'exp_food',
        date: DateTime.now(),
      );
      sync.updateDependencies(auth, categories, transactions);
      await settle();
      expect(cloud.docs(testUser.uid), hasLength(2));
    });

    test('waits while offline and syncs when the connection returns', () async {
      connectivity.set(false);
      await repo.insert(tx(id: 'a', amountMinor: 100, date: DateTime.now()));
      sync.updateDependencies(auth, categories, transactions);
      await settle();

      expect(sync.phase, SyncPhase.offline);
      expect(sync.pendingCount, 1);
      expect(cloud.docs(testUser.uid), isEmpty);

      connectivity.set(true);
      await settle();
      expect(sync.phase, SyncPhase.idle);
      expect(cloud.docs(testUser.uid).keys, ['a']);
    });

    test('reloads the list when the cloud changed local data', () async {
      final remote = tx(id: 'r', amountMinor: 700, date: DateTime.now());
      cloud.putRemote(testUser.uid, CloudTransaction(transaction: remote));
      await transactions.load();
      sync.updateDependencies(auth, categories, transactions);
      await settle();

      expect(transactions.transactions.map((t) => t.id), ['r']);
    });
  });
}
