import 'package:flutter/foundation.dart';

import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/repositories/savings_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/cloud_savings_store.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';

/// Synchronises savings goals and their history; run by
/// `TransactionSyncService` as part of every sync cycle.
///
/// Each partition (the user's personal savings, the household's savings,
/// each shared goal) is handled separately and never mixed:
///
/// 1. **Pull** changes since the partition's cursor, resolving conflicts
///    before anything is written: a newer cloud version replaces an older
///    unsent local edit (last writer wins by `updatedAt`); a newer local
///    edit or deletion is kept.
/// 2. **Push** pending goal changes and entries. Personal entries are
///    batched; household and shared entries are written one at a time in a
///    Firestore transaction with the goal's running total, which makes them
///    safe against concurrent contributions and idempotent (an entry that is
///    already in the cloud is only confirmed).
///
/// Rows are marked synced only after the cloud confirmed them. Savings are
/// never removed by the 90-day transaction clean-up. A refused savings
/// collection (e.g. security rules not deployed yet) never stops the rest
/// of the sync or affects household membership: savings simply stay
/// pending.
class SavingsSyncEngine {
  SavingsSyncEngine({
    required LocalSavingsSyncStore local,
    required CloudSavingsStore cloud,
    required LocalSyncStore settings,
    this.pageSize = 300,
  }) : _local = local,
       _cloud = cloud,
       _settings = settings;

  final LocalSavingsSyncStore _local;
  final CloudSavingsStore _cloud;
  final LocalSyncStore _settings;
  final int pageSize;

  Future<void> syncPersonal(
    String uid,
    SyncReport report, {
    required bool download,
    required bool restore,
  }) => _syncPartition(
    SavingsPartition.personal(uid),
    report,
    download: download,
    restore: restore,
  );

  Future<void> syncHousehold(
    String uid,
    String householdId,
    SyncReport report, {
    required bool download,
    required bool restore,
  }) => _syncPartition(
    SavingsPartition.household(uid, householdId),
    report,
    download: download,
    restore: restore,
  );

  /// Shared goals the user belongs to: details, members and history are
  /// refreshed; goals the user lost access to (removed, left, deleted) are
  /// removed from this device.
  Future<void> syncShared(
    String uid,
    SyncReport report, {
    required bool download,
    required bool restore,
  }) async {
    final Set<String> ids;
    try {
      ids = {
        if (download) ...await _cloud.fetchSharedGoalIds(uid),
        ...await _local.sharedGoalIds(),
      };
    } on CloudAccessDeniedException {
      report.savingsUnavailable = true;
      return;
    }
    for (final goalId in ids) {
      final partition = SavingsPartition.shared(uid, goalId);
      try {
        if (download) {
          final goal = await _cloud.fetchSharedGoal(uid, goalId);
          final members = goal == null || goal.deleted
              ? const <SharedGoalMember>[]
              : await _cloud.fetchSharedMembers(uid, goalId);
          final me = members.where((m) => m.uid == uid && m.isActive);
          if (goal == null || goal.deleted || me.isEmpty) {
            await _release(uid, goalId, report);
            continue;
          }
          if (await _local.applySharedGoal(goal, members)) {
            report.savingsDownloaded++;
          }
          await _pull(partition, SavingsCollection.entries, report, restore);
        }
        await _pushEntries(partition, report);
      } on CloudUnavailableException {
        rethrow;
      } on CloudAccessDeniedException {
        // Removed from the goal: its cached copy goes.
        await _release(uid, goalId, report);
      } catch (e, stack) {
        debugPrint('Syncing shared goal $goalId failed: $e\n$stack');
        report.failed++;
      }
    }
  }

  Future<void> _release(String uid, String goalId, SyncReport report) async {
    await _local.releaseSharedGoal(goalId);
    report.sharedGoalsReleased++;
    try {
      await _cloud.forgetSharedGoal(uid, goalId);
    } catch (e) {
      // Only an index entry; it is tidied up on a later cycle.
      debugPrint('Could not forget shared goal $goalId: $e');
    }
  }

  Future<void> _syncPartition(
    SavingsPartition partition,
    SyncReport report, {
    required bool download,
    required bool restore,
  }) async {
    for (final collection in SavingsCollection.values) {
      try {
        if (download) await _pull(partition, collection, report, restore);
        if (collection == SavingsCollection.goals) {
          await _pushGoals(partition, report);
        } else {
          await _pushEntries(partition, report);
        }
      } on CloudUnavailableException {
        rethrow;
      } on CloudAccessDeniedException {
        debugPrint('Savings of $partition not accessible; skipped.');
        report.savingsUnavailable = true;
        return;
      } catch (e, stack) {
        // Unsynced rows stay pending and are retried on the next cycle.
        debugPrint(
          'Syncing ${collection.path} of $partition failed: '
          '$e\n$stack',
        );
        report.failed++;
      }
    }
  }

  Future<void> _pushGoals(SavingsPartition p, SyncReport report) async {
    final pending = await _local.pendingRecords(p, SavingsCollection.goals);
    if (pending.isEmpty) return;
    await _cloud.upsertGoals(p, [for (final r in pending) r.record]);
    await _local.confirmUploaded(p, SavingsCollection.goals, pending);
    report.savingsUploaded += pending.length;
  }

  Future<void> _pushEntries(SavingsPartition p, SyncReport report) async {
    final pending = await _local.pendingRecords(p, SavingsCollection.entries);
    if (pending.isEmpty) return;
    if (p.isPersonal) {
      await _cloud.upsertPersonalEntries(p.uid, [
        for (final r in pending) r.record,
      ]);
      await _local.confirmUploaded(p, SavingsCollection.entries, pending);
      report.savingsUploaded += pending.length;
      return;
    }
    for (final record in pending) {
      final entry = record.entry;
      if (entry == null) continue;
      try {
        final outcome = await _cloud.recordEntry(p, entry);
        if (outcome == EntryWriteOutcome.goalMissing) {
          // Kept until the goal's deletion arrives, which removes it.
          report.failed++;
          continue;
        }
        await _local.confirmUploaded(p, SavingsCollection.entries, [record]);
        report.savingsUploaded++;
      } on SavingsException catch (e) {
        debugPrint('Savings entry ${entry.id} refused: $e');
        report.failed++;
      }
    }
  }

  String _cursorKey(SavingsPartition p, SavingsCollection c, String part) =>
      switch (p.ownership) {
        SavingsOwnership.personal => switch ((c, part)) {
          (SavingsCollection.goals, 'micros') =>
            SyncKeys.savingsGoalsCursorMicros,
          (SavingsCollection.goals, _) => SyncKeys.savingsGoalsCursorDocId,
          (SavingsCollection.entries, 'micros') =>
            SyncKeys.savingsEntriesCursorMicros,
          (SavingsCollection.entries, _) => SyncKeys.savingsEntriesCursorDocId,
        },
        SavingsOwnership.household => SyncKeys.householdSavingsCursor(
          p.householdId!,
          c == SavingsCollection.goals ? 'savings_goals' : 'savings_entries',
          part,
        ),
        SavingsOwnership.shared => SyncKeys.sharedGoalCursor(p.goalId!, part),
      };

  Future<void> _pull(
    SavingsPartition p,
    SavingsCollection collection,
    SyncReport report,
    bool restore,
  ) async {
    final microsKey = _cursorKey(p, collection, 'micros');
    final docKey = _cursorKey(p, collection, 'doc_id');
    if (restore) {
      // Read everything again; rows are matched by ID, so nothing is
      // duplicated.
      await _settings.removeSetting(microsKey);
      await _settings.removeSetting(docKey);
    }
    final micros = int.tryParse(await _settings.getSetting(microsKey) ?? '');
    final docId = await _settings.getSetting(docKey);
    var cursor = micros == null || docId == null
        ? null
        : SyncCursor(micros, docId);
    while (true) {
      final page = await _cloud.fetchChangedSince(
        p,
        collection,
        cursor,
        limit: pageSize,
      );
      for (final change in page) {
        final record = change.record;
        if (record != null && await _local.applyRemote(p, collection, record)) {
          report.savingsDownloaded++;
        }
        final position = change.position;
        if (position != null && (cursor == null || position.isAfter(cursor))) {
          cursor = position;
        }
      }
      if (cursor != null) {
        await _settings.setSetting(microsKey, cursor.serverMicros.toString());
        await _settings.setSetting(docKey, cursor.docId);
      }
      if (page.length < pageSize) break;
    }
  }
}
