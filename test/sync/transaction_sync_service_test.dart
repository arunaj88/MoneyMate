import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/app_settings_repository.dart';
import 'package:money_mate/repositories/budget_repository.dart';
import 'package:money_mate/repositories/category_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_cloud_store.dart';
import '../helpers/fakes.dart';

const uid = 'uid-1';
final now = DateTime.now();

/// A date [n] days before [now], at 09:00.
DateTime daysAgo(int n) => DateTime(now.year, now.month, now.day - n, 9);

void main() {
  sqfliteFfiInit();

  late AppDatabase db;
  late SqliteTransactionRepository transactions;
  late SqliteLocalSyncStore local;
  late InMemoryCloudStore cloud;
  late TransactionSyncService sync;

  setUp(() async {
    db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    transactions = SqliteTransactionRepository(db);
    local = SqliteLocalSyncStore(db);
    cloud = InMemoryCloudStore();
    sync = TransactionSyncService(local: local, cloud: cloud, clock: () => now);
  });

  tearDown(() => db.close());

  Future<List<String>> localIds() async =>
      (await transactions.getTransactions()).map((t) => t.id).toList();

  Future<RecordSyncStatus?> statusOf(String id) async =>
      (await local.getRecords([id]))[id]?.status;

  CloudTransaction remote(
    String id, {
    required DateTime date,
    DateTime? updatedAt,
    int amount = 500,
    bool deleted = false,
    String categoryId = 'exp_food',
    CategorySnapshot? category,
  }) => CloudTransaction(
    transaction: TransactionModel(
      id: id,
      type: TransactionType.expense,
      amountMinor: amount,
      categoryId: categoryId,
      date: date,
      createdAt: date,
      updatedAt: updatedAt ?? date,
    ),
    deleted: deleted,
    category: category,
  );

  group('retention policy', () {
    test('defaults to exactly 90 days', () async {
      expect(AppConstants.defaultLocalRetentionDays, 90);
      expect((await sync.retentionPolicy()).days, 90);
      expect(
        await sync.retentionCutoff(),
        DateTime(now.year, now.month, now.day - 90),
      );
    });

    test('can be configured, ignoring invalid values', () async {
      await local.setSetting(SyncKeys.retentionDays, '120');
      expect((await sync.retentionPolicy()).days, 120);
      await local.setSetting(SyncKeys.retentionDays, '5');
      expect((await sync.retentionPolicy()).days, 90);
      await local.setSetting(SyncKeys.retentionDays, 'abc');
      expect((await sync.retentionPolicy()).days, 90);
    });
  });

  group('upload and local clean-up', () {
    test('uploads existing records, then removes only verified ones older '
        'than 90 days from the device', () async {
      await transactions.insert(
        tx(id: 'recent', amountMinor: 100, date: daysAgo(3)),
      );
      await transactions.insert(
        tx(id: 'edge', amountMinor: 100, date: daysAgo(90)),
      );
      await transactions.insert(
        tx(id: 'old', amountMinor: 100, date: daysAgo(91)),
      );
      await transactions.insert(
        tx(id: 'ancient', amountMinor: 100, date: daysAgo(400)),
      );

      final result = await sync.synchronize(uid);

      expect(result.outcome, SyncOutcome.completed);
      expect(result.report.uploaded, 4);
      expect(result.report.archivedLocally, 2);
      // Day 90 is inside the window; day 91 and older are cloud-only.
      expect(await localIds(), unorderedEquals(['recent', 'edge']));
      // The cloud keeps the complete history.
      expect(
        cloud.docs(uid).keys,
        unorderedEquals(['recent', 'edge', 'old', 'ancient']),
      );
      expect(cloud.docs(uid).values.every((d) => !d.deleted), isTrue);
      expect(await statusOf('recent'), RecordSyncStatus.synced);
    });

    test('nothing is removed while offline', () async {
      await transactions.insert(
        tx(id: 'old', amountMinor: 100, date: daysAgo(200)),
      );
      cloud.offline = true;

      final result = await sync.synchronize(uid);

      expect(result.outcome, SyncOutcome.offline);
      expect(await localIds(), ['old']);
      expect(await statusOf('old'), RecordSyncStatus.pending);
    });

    test('records that fail verification are kept and marked failed', () async {
      await transactions.insert(
        tx(id: 'old', amountMinor: 100, date: daysAgo(200)),
      );
      cloud.dropWrites.add('old');

      final result = await sync.synchronize(uid);

      expect(result.report.failed, 1);
      expect(result.report.archivedLocally, 0);
      expect(await localIds(), ['old']);
      expect(await statusOf('old'), RecordSyncStatus.failed);

      // Retried on the next sync, then archived once verified.
      cloud.dropWrites.clear();
      final retry = await sync.synchronize(uid);
      expect(retry.report.uploaded, 1);
      expect(retry.report.archivedLocally, 1);
      expect(await localIds(), isEmpty);
      expect(cloud.docs(uid)['old']!.transaction.amountMinor, 100);
    });

    test('any unsynced record blocks the clean-up entirely', () async {
      await transactions.insert(
        tx(id: 'old', amountMinor: 100, date: daysAgo(200)),
      );
      await sync.synchronize(uid);
      expect(await localIds(), isEmpty);

      await transactions.insert(
        tx(id: 'old2', amountMinor: 100, date: daysAgo(150)),
      );
      await transactions.insert(
        tx(id: 'bad', amountMinor: 100, date: daysAgo(1)),
      );
      cloud.dropWrites.add('bad');

      final result = await sync.synchronize(uid);

      expect(await statusOf('bad'), RecordSyncStatus.failed);
      expect(await statusOf('old2'), RecordSyncStatus.synced);
      expect(result.report.archivedLocally, 0);
      expect(await localIds(), unorderedEquals(['old2', 'bad']));
    });

    test(
      'a synced row whose cloud copy changed is re-queued, not removed',
      () async {
        await transactions.insert(
          tx(id: 'recent', amountMinor: 100, date: daysAgo(1)),
        );
        await local.setSetting(SyncKeys.retentionDays, '365');
        await transactions.insert(
          tx(id: 'old', amountMinor: 100, date: daysAgo(200)),
        );
        await sync.synchronize(uid);
        expect(await localIds(), contains('old'));

        // Another device overwrote it with an older timestamp (clock skew),
        // so the local "synced" copy no longer matches the cloud.
        cloud.putRemote(
          uid,
          remote('old', date: daysAgo(200), updatedAt: daysAgo(300), amount: 7),
        );
        await local.setSetting(SyncKeys.retentionDays, '90');

        final result = await sync.synchronize(uid);

        // Kept locally and queued again; archived only once re-verified.
        expect(result.report.archivedLocally, 0);
        expect(await localIds(), contains('old'));
        expect(await statusOf('old'), RecordSyncStatus.pending);
        final again = await sync.synchronize(uid);
        expect(again.report.uploaded, 1);
        expect(again.report.archivedLocally, 1);
        expect(cloud.docs(uid)['old']!.transaction.amountMinor, 100);
      },
    );

    test('budgets, categories and settings are untouched', () async {
      final categories = SqliteCategoryRepository(db);
      final budgets = SqliteBudgetRepository(db);
      final settings = SqliteAppSettingsRepository(db);
      await categories.insert(
        const CategoryModel(
          id: 'custom',
          name: 'Hobbies',
          type: TransactionType.expense,
          iconKey: 'star',
          colorValue: 0xFF000000,
        ),
      );
      await budgets.setTarget(
        period: BudgetPeriod.monthly,
        amountMinor: 100000,
        effectiveFrom: daysAgo(300),
      );
      await settings.set('alert.monthly', 'shown');
      await transactions.insert(
        tx(
          id: 'old',
          amountMinor: 100,
          date: daysAgo(200),
          categoryId: 'custom',
        ),
      );

      final result = await sync.synchronize(uid);

      expect(result.report.archivedLocally, 1);
      expect((await categories.getAll()).map((c) => c.id), contains('custom'));
      expect(
        await budgets.getTargetVersions(BudgetPeriod.monthly),
        hasLength(1),
      );
      expect(await settings.get('alert.monthly'), 'shown');
      // The category travels with the cloud record.
      expect(cloud.docs(uid)['old']!.category?.name, 'Hobbies');
    });
  });

  group('two-way sync', () {
    test('downloads recent records from other devices only', () async {
      cloud.putRemote(uid, remote('r-new', date: daysAgo(5)));
      cloud.putRemote(uid, remote('r-old', date: daysAgo(150)));

      final result = await sync.synchronize(uid);

      expect(result.report.downloaded, 1);
      expect(await localIds(), ['r-new']);
      expect(await statusOf('r-new'), RecordSyncStatus.synced);

      // A second sync applies nothing new (cursor) and uploads nothing.
      final writes = cloud.writes;
      final again = await sync.synchronize(uid);
      expect(again.report.downloaded, 0);
      expect(cloud.writes, writes);
    });

    test('creates a missing category from the cloud snapshot', () async {
      cloud.putRemote(
        uid,
        remote(
          'r1',
          date: daysAgo(2),
          categoryId: 'cat-remote',
          category: const CategorySnapshot(
            id: 'cat-remote',
            name: 'Pets',
            type: TransactionType.expense,
            iconKey: 'pets',
            colorValue: 0xFF112233,
          ),
        ),
      );

      await sync.synchronize(uid);

      final cats = await SqliteCategoryRepository(db).getAll();
      expect(cats.map((c) => c.name), contains('Pets'));
      expect((await transactions.getById('r1'))!.categoryId, 'cat-remote');
    });

    test('newer local edit wins over an older cloud version', () async {
      await transactions.insert(
        tx(id: 'a', amountMinor: 100, date: daysAgo(1)),
      );
      await sync.synchronize(uid);

      final edited = (await transactions.getById('a'))!.copyWith(
        amountMinor: 200,
        updatedAt: now.add(const Duration(minutes: 5)),
      );
      await transactions.update(edited);
      await sync.synchronize(uid);

      expect(cloud.docs(uid)['a']!.transaction.amountMinor, 200);
      expect(await statusOf('a'), RecordSyncStatus.synced);
    });

    test('newer cloud edit wins over an older pending local edit', () async {
      await transactions.insert(
        tx(id: 'a', amountMinor: 100, date: daysAgo(1)),
      );
      await sync.synchronize(uid);

      await transactions.update(
        (await transactions.getById('a'))!.copyWith(
          amountMinor: 200,
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
      );
      cloud.putRemote(
        uid,
        remote(
          'a',
          date: daysAgo(1),
          amount: 300,
          updatedAt: now.add(const Duration(minutes: 9)),
        ),
      );

      final result = await sync.synchronize(uid);

      expect(result.report.conflictsWonByCloud, 1);
      expect((await transactions.getById('a'))!.amountMinor, 300);
      expect(cloud.docs(uid)['a']!.transaction.amountMinor, 300);
      expect(await statusOf('a'), RecordSyncStatus.synced);
    });

    test('local deletion marks the cloud record deleted (soft)', () async {
      await transactions.insert(
        tx(id: 'a', amountMinor: 100, date: daysAgo(1)),
      );
      await sync.synchronize(uid);

      await transactions.delete('a');
      final result = await sync.synchronize(uid);

      expect(result.report.deletionsUploaded, 1);
      expect(cloud.docs(uid)['a']!.deleted, isTrue);
      expect(await local.allTombstoneIds(), isEmpty);
    });

    test('deletion from another device removes the local copy', () async {
      await transactions.insert(
        tx(id: 'a', amountMinor: 100, date: daysAgo(1)),
      );
      await sync.synchronize(uid);

      cloud.putRemote(
        uid,
        remote(
          'a',
          date: daysAgo(1),
          amount: 100,
          deleted: true,
          updatedAt: now,
        ),
      );
      final result = await sync.synchronize(uid);

      expect(result.report.deletedFromCloud, 1);
      expect(await localIds(), isEmpty);
    });

    test(
      'undo after a synced deletion restores the record everywhere',
      () async {
        final original = tx(id: 'a', amountMinor: 100, date: daysAgo(1));
        await transactions.insert(original);
        await sync.synchronize(uid);
        await transactions.delete('a');
        await sync.synchronize(uid);
        expect(cloud.docs(uid)['a']!.deleted, isTrue);

        await transactions.insert(
          original.copyWith(
            updatedAt: DateTime.now().add(const Duration(days: 1)),
          ),
        );
        await sync.synchronize(uid);

        expect(cloud.docs(uid)['a']!.deleted, isFalse);
        expect(await localIds(), ['a']);
      },
    );

    test('never syncs data linked to a different account', () async {
      await transactions.insert(
        tx(id: 'a', amountMinor: 100, date: daysAgo(200)),
      );
      await sync.synchronize(uid);
      await transactions.insert(
        tx(id: 'b', amountMinor: 100, date: daysAgo(300)),
      );

      final result = await sync.synchronize('someone-else');

      expect(result.outcome, SyncOutcome.accountMismatch);
      expect(cloud.docs('someone-else'), isEmpty);
      expect(await localIds(), ['b']);
    });

    test('concurrent sync requests share one cycle', () async {
      await transactions.insert(
        tx(id: 'a', amountMinor: 100, date: daysAgo(1)),
      );
      final results = await Future.wait([
        sync.synchronize(uid),
        sync.synchronize(uid),
      ]);
      expect(identical(results[0], results[1]), isTrue);
      expect(cloud.writes, 1);
    });
  });

  group('cloud history', () {
    setUp(() async {
      await transactions.insert(
        tx(id: 'local', amountMinor: 100, date: daysAgo(1)),
      );
      cloud.putRemote(uid, remote('h1', date: daysAgo(100)));
      cloud.putRemote(uid, remote('h2', date: daysAgo(120), amount: 900));
      cloud.putRemote(uid, remote('gone', date: daysAgo(130), deleted: true));
      cloud.putRemote(uid, remote('deleted-here', date: daysAgo(140)));
    });

    Map<String, String> names() => {
      for (final c in DefaultCategories.all) c.id: c.name,
    };

    test('returns older records without duplicates or deletions', () async {
      // Still on this device (not archived yet) – must not appear twice.
      await transactions.insert(
        tx(id: 'h1', amountMinor: 500, date: daysAgo(100)),
      );
      await transactions.delete('deleted-here');

      final result = await sync.loadHistory(
        CloudPartition.personal(uid),
        filter: const TransactionFilter(),
        categoryNames: names(),
      );

      expect(result.transactions.map((t) => t.id), ['h2']);
      expect(result.hasMore, isFalse);
    });

    test('applies the transaction filter', () async {
      final result = await sync.loadHistory(
        CloudPartition.personal(uid),
        filter: TransactionFilter(start: daysAgo(110), end: daysAgo(90)),
        categoryNames: names(),
      );
      expect(result.transactions.map((t) => t.id), ['h1']);
    });

    test('pages through results', () async {
      final first = await sync.loadHistory(
        CloudPartition.personal(uid),
        filter: const TransactionFilter(),
        categoryNames: names(),
        pageSize: 1,
        maxPages: 1,
      );
      expect(first.transactions.map((t) => t.id), ['h1']);
      expect(first.hasMore, isTrue);
      final second = await sync.loadHistory(
        CloudPartition.personal(uid),
        filter: const TransactionFilter(),
        categoryNames: names(),
        cursor: first.cursor,
        pageSize: 1,
        maxPages: 1,
      );
      expect(second.transactions.map((t) => t.id), ['h2']);
    });
  });
}
