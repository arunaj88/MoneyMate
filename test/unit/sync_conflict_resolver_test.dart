import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/sync_conflict_resolver.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/sync_repository.dart';

import '../helpers/fakes.dart';

void main() {
  final cutoff = DateTime(2026, 8, 25);
  final t0 = DateTime(2026, 11, 1, 10);
  final t1 = t0.add(const Duration(minutes: 1));

  TransactionModel version(DateTime updatedAt, {int amount = 100}) =>
      tx(id: 'a', amountMinor: amount, date: t0).copyWith(updatedAt: updatedAt);

  CloudTransaction cloud(
    DateTime updatedAt, {
    int amount = 100,
    bool deleted = false,
  }) => CloudTransaction(
    transaction: version(updatedAt, amount: amount),
    deleted: deleted,
  );

  LocalSyncRecord local(
    DateTime updatedAt, {
    int amount = 100,
    RecordSyncStatus status = RecordSyncStatus.pending,
  }) => LocalSyncRecord(
    transaction: version(updatedAt, amount: amount),
    status: status,
    cloudUpdatedAt: status == RecordSyncStatus.synced ? updatedAt : null,
  );

  group('push', () {
    test('uploads when the cloud has nothing or an older version', () {
      final change = LocalUpsert(version(t1, amount: 2));
      expect(SyncConflictResolver.resolvePush(change, null), PushAction.upload);
      expect(
        SyncConflictResolver.resolvePush(change, cloud(t0)),
        PushAction.upload,
      );
    });

    test('confirms an identical cloud copy', () {
      expect(
        SyncConflictResolver.resolvePush(LocalUpsert(version(t0)), cloud(t0)),
        PushAction.confirm,
      );
    });

    test('newer or tied cloud version wins', () {
      final change = LocalUpsert(version(t0, amount: 5));
      expect(
        SyncConflictResolver.resolvePush(change, cloud(t1)),
        PushAction.acceptRemote,
      );
      expect(
        SyncConflictResolver.resolvePush(change, cloud(t0, amount: 9)),
        PushAction.acceptRemote,
      );
    });

    test('deletions', () {
      expect(
        SyncConflictResolver.resolvePush(LocalDeletion('a', t1), null),
        PushAction.confirm,
      );
      expect(
        SyncConflictResolver.resolvePush(LocalDeletion('a', t1), cloud(t0)),
        PushAction.upload,
      );
      // Edited on another device after it was deleted here: edit wins.
      expect(
        SyncConflictResolver.resolvePush(LocalDeletion('a', t0), cloud(t1)),
        PushAction.acceptRemote,
      );
    });
  });

  group('pull', () {
    PullAction pull(
      CloudTransaction remote, {
      LocalSyncRecord? local,
      DateTime? tombstone,
    }) => SyncConflictResolver.resolvePull(
      remote: remote,
      local: local,
      tombstoneDeletedAt: tombstone,
      retentionCutoff: cutoff,
    );

    test('inserts recent records and skips archived ones', () {
      expect(pull(cloud(t0)), PullAction.writeRemote);
      final old = CloudTransaction(
        transaction: tx(id: 'o', amountMinor: 1, date: DateTime(2026, 1, 1)),
      );
      expect(pull(old), PullAction.skipArchived);
    });

    test('keeps a newer pending local edit', () {
      expect(
        pull(cloud(t0, amount: 3), local: local(t1, amount: 4)),
        PullAction.keepLocal,
      );
    });

    test('overwrites an older local version', () {
      expect(
        pull(
          cloud(t1, amount: 3),
          local: local(t0, status: RecordSyncStatus.synced),
        ),
        PullAction.writeRemote,
      );
    });

    test('confirms an identical pending row', () {
      expect(pull(cloud(t0), local: local(t0)), PullAction.confirmLocal);
      expect(
        pull(cloud(t0), local: local(t0, status: RecordSyncStatus.synced)),
        PullAction.keepLocal,
      );
    });

    test('remote deletion', () {
      expect(
        pull(
          cloud(t1, deleted: true),
          local: local(t0, status: RecordSyncStatus.synced),
        ),
        PullAction.deleteLocal,
      );
      // A newer local edit survives an older remote deletion.
      expect(
        pull(cloud(t0, deleted: true), local: local(t1)),
        PullAction.keepLocal,
      );
      expect(
        pull(cloud(t1, deleted: true), tombstone: t0),
        PullAction.clearTombstone,
      );
    });

    test('local deletion vs remote edit', () {
      expect(pull(cloud(t0), tombstone: t1), PullAction.keepLocal);
      expect(pull(cloud(t1), tombstone: t0), PullAction.writeRemote);
    });
  });

  test('cloud documents round-trip', () {
    const category = CategorySnapshot(
      id: 'c',
      name: 'Pets',
      type: TransactionType.expense,
      iconKey: 'pets',
      colorValue: 0xFF00FF00,
    );
    final doc = CloudTransaction(
      transaction: version(t1, amount: 1234).copyWith(note: 'Vet'),
      category: category,
    );
    final parsed = CloudTransaction.fromCloudMap(
      'a',
      doc.toCloudMap(const CloudPartition.personal('uid-1')),
    );
    expect(parsed.matches(doc.transaction), isTrue);
    expect(parsed.category?.name, 'Pets');
    expect(parsed.deleted, isFalse);
    expect(
      () => CloudTransaction.fromCloudMap('a', {'type': 'expense'}),
      throwsFormatException,
    );
  });
}
