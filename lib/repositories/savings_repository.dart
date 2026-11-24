import 'package:sqflite/sqflite.dart';

import '../core/constants/app_constants.dart';
import '../core/database/app_database.dart';
import '../core/services/cloud_savings_store.dart';
import '../models/savings_model.dart';
import '../models/sync_models.dart';

export '../core/services/cloud_savings_store.dart' show SavingsException;

/// Storage of savings goals, their history and (for shared goals) members
/// and invitations.
///
/// Personal and household goals are changed on the device first and marked
/// for upload, so they work fully offline. Shared goals are created and
/// managed online; their details, members and history are cached here, and
/// contributions to them can be recorded offline and uploaded later.
abstract class SavingsRepository {
  /// Every goal of every kind with its saved amount (and [uid]'s own
  /// contribution): active first, then paused, then completed; newest first
  /// within each group.
  Future<List<SavingsGoal>> getGoals({String? uid});

  /// [goalId]'s history, newest first.
  Future<List<SavingsEntry>> getEntries(String goalId);

  /// Stores a personal or household goal for upload, or a shared goal that
  /// the cloud already confirmed ([synced]).
  Future<void> insertGoal(SavingsGoal goal, {bool synced = false});

  /// Saves [goal]'s editable details. Throws [SavingsException] if it no
  /// longer exists.
  Future<void> updateGoal(SavingsGoal goal, {bool synced = false});

  /// Deletes a personal or household goal and its history on this device
  /// and queues the deletion for the cloud. The money held in it goes back
  /// to the available balance.
  Future<void> deleteGoal(String goalId, DateTime deletedAt);

  /// Records a contribution or withdrawal ([synced] when the cloud already
  /// has it). Throws [SavingsException] when the goal does not exist or a
  /// withdrawal exceeds its balance; the check and the insert happen in one
  /// database transaction.
  Future<void> addEntry(SavingsEntry entry, {bool synced = false});

  /// Deletes one entry of a personal goal. Throws [SavingsException] when
  /// removing a contribution would leave less in the goal than was
  /// withdrawn, or for household / shared entries (those are corrected with
  /// an opposite entry instead).
  Future<void> deleteEntry(String entryId, DateTime deletedAt);

  // ---------------------------------------------------------- shared goals

  Future<List<SharedGoalMember>> getMembers(String goalId);

  /// Replaces the cached members of [goalId].
  Future<void> replaceMembers(String goalId, List<SharedGoalMember> members);

  /// Invitations sent for [goalId], or (without it) those received.
  Future<List<SharedGoalInvitation>> getInvitations({String? goalId});

  /// Replaces the cached invitations sent for [goalId], or the received
  /// ones when [goalId] is null.
  Future<void> replaceInvitations(
    List<SharedGoalInvitation> invitations, {
    String? goalId,
  });

  /// Removes a shared goal and everything cached for it from this device
  /// (the user left or lost access, or it was deleted).
  Future<void> releaseSharedGoal(String goalId);
}

/// A local savings change ready to upload.
class PendingSavingsRecord {
  const PendingSavingsRecord({
    required this.record,
    required this.isTombstone,
    required this.stamp,
    this.entry,
  });

  final CloudRecord record;
  final bool isTombstone;

  /// `updated_at` / `deleted_at` the upload was built from; confirmation
  /// only applies while the row still has it.
  final int stamp;

  /// The entry itself, for entries.
  final SavingsEntry? entry;

  String get id => record.id;
}

/// Local side of savings synchronisation.
abstract class LocalSavingsSyncStore {
  /// Unsent changes of [collection] in [partition] (for a shared partition,
  /// only its pending entries).
  Future<List<PendingSavingsRecord>> pendingRecords(
    SavingsPartition partition,
    SavingsCollection collection,
  );

  /// Marks uploaded rows as synced (unless changed since) and drops
  /// uploaded tombstones.
  Future<void> confirmUploaded(
    SavingsPartition partition,
    SavingsCollection collection,
    List<PendingSavingsRecord> uploaded,
  );

  /// Applies one cloud document of [partition] (last writer wins by
  /// `updatedAt`; a newer unsent local change or deletion is kept). Returns
  /// true when local data changed.
  Future<bool> applyRemote(
    SavingsPartition partition,
    SavingsCollection collection,
    CloudRecord remote,
  );

  /// Stores a shared goal's details and members as read from the cloud.
  /// Returns true when anything changed.
  Future<bool> applySharedGoal(
    CloudRecord goal,
    List<SharedGoalMember> members,
  );

  /// Shared goals cached on this device.
  Future<List<String>> sharedGoalIds();

  Future<void> releaseSharedGoal(String goalId);
}

class SqliteSavingsRepository
    implements SavingsRepository, LocalSavingsSyncStore {
  SqliteSavingsRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const _pending = 'pending';
  static const _synced = 'synced';

  /// Signed amount of an entry row, in SQL.
  static const _signed =
      "CASE WHEN e.type = 'deposit' THEN e.amount_minor "
      'ELSE -e.amount_minor END';

  // --------------------------------------------------------------- reads

  @override
  Future<List<SavingsGoal>> getGoals({String? uid}) async {
    final rows = await _db.rawQuery(
      'SELECT g.*, COALESCE(SUM($_signed), 0) AS saved_minor, '
      'MIN(e.date) AS first_entry_date, '
      'COALESCE(SUM(CASE WHEN e.user_uid = ? THEN $_signed ELSE 0 END), 0) '
      'AS my_saved_minor, '
      "COALESCE(SUM(CASE WHEN e.sync_status = 'pending' THEN 1 ELSE 0 END), "
      '0) AS pending_entries, '
      '(SELECT COUNT(*) FROM ${Tables.savingsMembers} m '
      "WHERE m.goal_id = g.id AND m.status = 'active') AS member_count "
      'FROM ${Tables.savingsGoals} g '
      'LEFT JOIN ${Tables.savingsEntries} e ON e.goal_id = g.id '
      'GROUP BY g.id '
      "ORDER BY CASE g.status WHEN 'active' THEN 0 WHEN 'paused' THEN 1 "
      'ELSE 2 END, g.created_at DESC',
      [uid ?? ''],
    );
    final goals = <SavingsGoal>[];
    for (final r in rows) {
      try {
        goals.add(SavingsGoal.fromMap(r));
      } on FormatException {
        // A malformed row is skipped rather than hiding every goal.
      }
    }
    return goals;
  }

  @override
  Future<List<SavingsEntry>> getEntries(String goalId) async {
    final rows = await _db.query(
      Tables.savingsEntries,
      where: 'goal_id = ?',
      whereArgs: [goalId],
      orderBy: 'date DESC, created_at DESC',
    );
    final entries = <SavingsEntry>[];
    for (final r in rows) {
      try {
        entries.add(SavingsEntry.fromMap(r));
      } on FormatException {
        // Skipped, see getGoals.
      }
    }
    return entries;
  }

  static Future<int> _balance(DatabaseExecutor db, String goalId) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM($_signed), 0) AS b '
      'FROM ${Tables.savingsEntries} e WHERE e.goal_id = ?',
      [goalId],
    );
    return (rows.first['b'] as int?) ?? 0;
  }

  static Future<Map<String, Object?>?> _goalRow(
    DatabaseExecutor db,
    String goalId,
  ) async {
    final rows = await db.query(
      Tables.savingsGoals,
      where: 'id = ?',
      whereArgs: [goalId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // -------------------------------------------------------------- writes

  @override
  Future<void> insertGoal(SavingsGoal goal, {bool synced = false}) =>
      _db.transaction((txn) async {
        await txn.insert(Tables.savingsGoals, {
          ...goal.toMap(),
          'sync_status': synced ? _synced : _pending,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await _dropTombstone(
          txn,
          goal.householdId ?? '',
          SavingsCollection.goals,
          goal.id,
        );
      });

  @override
  Future<void> updateGoal(SavingsGoal goal, {bool synced = false}) async {
    final values = goal.toMap()
      ..remove('id')
      ..remove('created_at')
      ..remove('ownership')
      ..remove('household_id')
      ..remove('owner_uid')
      ..remove('created_by')
      ..remove('created_by_name');
    final count = await _db.update(
      Tables.savingsGoals,
      {...values, 'sync_status': synced ? _synced : _pending},
      where: 'id = ?',
      whereArgs: [goal.id],
    );
    if (count == 0) {
      throw const SavingsException('This goal no longer exists.');
    }
  }

  @override
  Future<void> deleteGoal(
    String goalId,
    DateTime deletedAt,
  ) => _db.transaction((txn) async {
    final goal = await _goalRow(txn, goalId);
    if (goal == null) return;
    final at = deletedAt.millisecondsSinceEpoch;
    final ownership = SavingsOwnership.fromName(goal['ownership'] as String?);
    final household = goal['household_id'] as String? ?? '';
    if (ownership == SavingsOwnership.personal) {
      // Personal entries are deleted everywhere too, each with its own
      // marker. (Household entries are permanent records in the cloud;
      // deleting the goal hides them.)
      final entries = await txn.query(
        Tables.savingsEntries,
        columns: ['id'],
        where: 'goal_id = ?',
        whereArgs: [goalId],
      );
      for (final e in entries) {
        await _tombstone(
          txn,
          '',
          SavingsCollection.entries,
          e['id']! as String,
          at,
        );
      }
    }
    await txn.delete(
      Tables.savingsEntries,
      where: 'goal_id = ?',
      whereArgs: [goalId],
    );
    await txn.delete(Tables.savingsGoals, where: 'id = ?', whereArgs: [goalId]);
    if (ownership != SavingsOwnership.shared) {
      await _tombstone(txn, household, SavingsCollection.goals, goalId, at);
    }
  });

  @override
  Future<void> addEntry(SavingsEntry entry, {bool synced = false}) =>
      _db.transaction((txn) async {
        final goal = await _goalRow(txn, entry.goalId);
        if (goal == null) {
          throw const SavingsException('This goal no longer exists.');
        }
        if (!entry.isDeposit) {
          final balance = await _balance(txn, entry.goalId);
          // A withdrawal the cloud already accepted is stored even if this
          // device has not seen every contribution yet.
          if (!synced && entry.amountMinor > balance) {
            throw const SavingsException(
              'You cannot withdraw more than is saved in this goal.',
            );
          }
        }
        await txn.insert(Tables.savingsEntries, {
          ...entry.toMap(),
          'sync_status': synced ? _synced : _pending,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
        await _dropTombstone(
          txn,
          goal['household_id'] as String? ?? '',
          SavingsCollection.entries,
          entry.id,
        );
      });

  @override
  Future<void> deleteEntry(String entryId, DateTime deletedAt) =>
      _db.transaction((txn) async {
        final rows = await txn.query(
          Tables.savingsEntries,
          where: 'id = ?',
          whereArgs: [entryId],
          limit: 1,
        );
        if (rows.isEmpty) return;
        final entry = SavingsEntry.fromMap(rows.first);
        final goal = await _goalRow(txn, entry.goalId);
        if (goal != null && goal['ownership'] != 'personal') {
          throw const SavingsException(
            'Entries of shared goals stay in the history. Record an opposite '
            'entry to correct a mistake.',
          );
        }
        if (entry.isDeposit) {
          final balance = await _balance(txn, entry.goalId);
          if (balance - entry.amountMinor < 0) {
            throw const SavingsException(
              'Money from this contribution has already been withdrawn. '
              'Delete the withdrawal first.',
            );
          }
        }
        await txn.delete(
          Tables.savingsEntries,
          where: 'id = ?',
          whereArgs: [entryId],
        );
        await _tombstone(
          txn,
          '',
          SavingsCollection.entries,
          entryId,
          deletedAt.millisecondsSinceEpoch,
        );
      });

  // ---------------------------------------------------------- shared goals

  @override
  Future<List<SharedGoalMember>> getMembers(String goalId) async {
    final rows = await _db.query(
      Tables.savingsMembers,
      where: 'goal_id = ?',
      whereArgs: [goalId],
      orderBy: "CASE role WHEN 'owner' THEN 0 ELSE 1 END, joined_at",
    );
    return [for (final r in rows) SharedGoalMember.fromMap(r)];
  }

  @override
  Future<void> replaceMembers(String goalId, List<SharedGoalMember> members) =>
      _db.transaction((txn) => _replaceMembers(txn, goalId, members));

  static Future<void> _replaceMembers(
    DatabaseExecutor db,
    String goalId,
    List<SharedGoalMember> members,
  ) async {
    await db.delete(
      Tables.savingsMembers,
      where: 'goal_id = ?',
      whereArgs: [goalId],
    );
    for (final m in members) {
      await db.insert(
        Tables.savingsMembers,
        m.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  @override
  Future<List<SharedGoalInvitation>> getInvitations({String? goalId}) async {
    final rows = await _db.query(
      Tables.savingsInvitations,
      where: goalId == null
          ? "direction = 'received'"
          : "goal_id = ? AND direction = 'sent'",
      whereArgs: goalId == null ? null : [goalId],
      orderBy: 'created_at DESC',
    );
    return [for (final r in rows) SharedGoalInvitation.fromMap(r)];
  }

  @override
  Future<void> replaceInvitations(
    List<SharedGoalInvitation> invitations, {
    String? goalId,
  }) => _db.transaction((txn) async {
    final direction = goalId == null ? 'received' : 'sent';
    await txn.delete(
      Tables.savingsInvitations,
      where: goalId == null ? 'direction = ?' : 'direction = ? AND goal_id = ?',
      whereArgs: [direction, ?goalId],
    );
    for (final i in invitations) {
      await txn.insert(Tables.savingsInvitations, {
        ...i.toMap(),
        'direction': direction,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  });

  @override
  Future<void> releaseSharedGoal(String goalId) => _db.transaction((txn) async {
    await txn.delete(
      Tables.savingsEntries,
      where: 'goal_id = ?',
      whereArgs: [goalId],
    );
    await txn.delete(
      Tables.savingsGoals,
      where: "id = ? AND ownership = 'shared'",
      whereArgs: [goalId],
    );
    await txn.delete(
      Tables.savingsMembers,
      where: 'goal_id = ?',
      whereArgs: [goalId],
    );
    await txn.delete(
      Tables.savingsInvitations,
      where: "goal_id = ? AND direction = 'sent'",
      whereArgs: [goalId],
    );
    await txn.delete(
      Tables.appSettings,
      where: 'key IN (?, ?)',
      whereArgs: [
        SyncKeys.sharedGoalCursor(goalId, 'micros'),
        SyncKeys.sharedGoalCursor(goalId, 'doc_id'),
      ],
    );
  });

  // ---------------------------------------------------------- tombstones

  static Future<void> _tombstone(
    DatabaseExecutor db,
    String household,
    SavingsCollection collection,
    String id,
    int at,
  ) => db.insert(Tables.cloudTombstones, {
    'collection': collection.path,
    'household_id': household,
    'id': id,
    'deleted_at': at,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<int?> _tombstoneAt(
    DatabaseExecutor db,
    String household,
    SavingsCollection collection,
    String id,
  ) async {
    final rows = await db.query(
      Tables.cloudTombstones,
      columns: ['deleted_at'],
      where: 'collection = ? AND household_id = ? AND id = ?',
      whereArgs: [collection.path, household, id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['deleted_at']! as int;
  }

  static Future<void> _dropTombstone(
    DatabaseExecutor db,
    String household,
    SavingsCollection collection,
    String id,
  ) => db.delete(
    Tables.cloudTombstones,
    where: 'collection = ? AND household_id = ? AND id = ?',
    whereArgs: [collection.path, household, id],
  );

  // ---------------------------------------------------------------- sync

  static String _table(SavingsCollection c) => switch (c) {
    SavingsCollection.goals => Tables.savingsGoals,
    SavingsCollection.entries => Tables.savingsEntries,
  };

  /// SQL selecting the goals of [p].
  static ({String sql, List<Object?> args}) _goalsOf(SavingsPartition p) =>
      switch (p.ownership) {
        SavingsOwnership.personal => (
          sql: "ownership = 'personal'",
          args: const [],
        ),
        SavingsOwnership.household => (
          sql: "ownership = 'household' AND household_id = ?",
          args: [p.householdId],
        ),
        SavingsOwnership.shared => (
          sql: "ownership = 'shared' AND id = ?",
          args: [p.goalId],
        ),
      };

  @override
  Future<List<PendingSavingsRecord>> pendingRecords(
    SavingsPartition partition,
    SavingsCollection collection,
  ) async {
    final scope = _goalsOf(partition);
    final result = <PendingSavingsRecord>[];
    final shared = partition.ownership == SavingsOwnership.shared;
    if (collection == SavingsCollection.goals) {
      // Shared goals are only changed online, never queued.
      if (shared) return result;
      final rows = await _db.query(
        Tables.savingsGoals,
        where: "sync_status = '$_pending' AND ${scope.sql}",
        whereArgs: scope.args,
      );
      for (final r in rows) {
        try {
          final goal = SavingsGoal.fromMap(r);
          final at = goal.updatedAt.millisecondsSinceEpoch;
          result.add(
            PendingSavingsRecord(
              record: CloudRecord(
                id: goal.id,
                data: goal.toCloudMap(),
                updatedAtMs: at,
              ),
              isTombstone: false,
              stamp: at,
            ),
          );
        } on FormatException {
          continue;
        }
      }
    } else {
      final rows = await _db.rawQuery(
        'SELECT * FROM ${Tables.savingsEntries} '
        "WHERE sync_status = '$_pending' AND goal_id IN "
        '(SELECT id FROM ${Tables.savingsGoals} WHERE ${scope.sql}) '
        'ORDER BY created_at',
        scope.args,
      );
      for (final r in rows) {
        try {
          final entry = SavingsEntry.fromMap(r);
          final at = entry.updatedAt.millisecondsSinceEpoch;
          result.add(
            PendingSavingsRecord(
              record: CloudRecord(
                id: entry.id,
                data: entry.toCloudMap(),
                updatedAtMs: at,
              ),
              isTombstone: false,
              stamp: at,
              entry: entry,
            ),
          );
        } on FormatException {
          continue;
        }
      }
    }
    // Household and shared entries are permanent, so only personal entries
    // and personal / household goals have deletion markers.
    if (shared) return result;
    if (collection == SavingsCollection.entries && !partition.isPersonal) {
      return result;
    }
    final tombstones = await _db.query(
      Tables.cloudTombstones,
      where: 'collection = ? AND household_id = ?',
      whereArgs: [collection.path, partition.tombstoneKey],
    );
    for (final t in tombstones) {
      final at = t['deleted_at']! as int;
      result.add(
        PendingSavingsRecord(
          record: CloudRecord.deletion(t['id']! as String, at),
          isTombstone: true,
          stamp: at,
        ),
      );
    }
    return result;
  }

  @override
  Future<void> confirmUploaded(
    SavingsPartition partition,
    SavingsCollection collection,
    List<PendingSavingsRecord> uploaded,
  ) async {
    final batch = _db.batch();
    for (final p in uploaded) {
      if (p.isTombstone) {
        batch.delete(
          Tables.cloudTombstones,
          where:
              'collection = ? AND household_id = ? AND id = ? '
              'AND deleted_at <= ?',
          whereArgs: [collection.path, partition.tombstoneKey, p.id, p.stamp],
        );
      } else {
        batch.update(
          _table(collection),
          {'sync_status': _synced},
          where: 'id = ? AND updated_at = ?',
          whereArgs: [p.id, p.stamp],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  static bool _localWins(Map<String, Object?> local, int remoteAt) =>
      local['sync_status'] == _pending &&
      (local['updated_at']! as int) > remoteAt;

  @override
  Future<bool> applyRemote(
    SavingsPartition partition,
    SavingsCollection collection,
    CloudRecord remote,
  ) {
    return _db.transaction((txn) async {
      final id = remote.id;
      final household = partition.tombstoneKey;
      final table = _table(collection);
      final tombstone = await _tombstoneAt(txn, household, collection, id);
      // Deleted here after the cloud version was written: the deletion
      // wins and is uploaded.
      if (tombstone != null && tombstone >= remote.updatedAtMs) return false;

      final rows = await txn.query(
        table,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      final local = rows.isEmpty ? null : rows.first;

      if (remote.deleted) {
        if (tombstone != null) {
          await _dropTombstone(txn, household, collection, id);
        }
        if (local == null || _localWins(local, remote.updatedAtMs)) {
          return false;
        }
        await txn.delete(table, where: 'id = ?', whereArgs: [id]);
        if (collection == SavingsCollection.goals) {
          // Its history goes with it.
          await txn.delete(
            Tables.savingsEntries,
            where: 'goal_id = ?',
            whereArgs: [id],
          );
        }
        return true;
      }

      final Map<String, Object?> values;
      switch (collection) {
        case SavingsCollection.goals:
          final goal = SavingsGoal.fromCloudMap(
            id,
            remote.data,
            remote.updatedAtMs,
            ownership: partition.ownership,
            householdId: partition.householdId,
          );
          if (goal == null) return false;
          // A goal ID always stays in its own collection.
          if (local != null && local['ownership'] != goal.ownership.name) {
            return false;
          }
          values = goal.toMap();
        case SavingsCollection.entries:
          final entry = SavingsEntry.fromCloudMap(
            id,
            remote.data,
            remote.updatedAtMs,
          );
          if (entry == null) return false;
          if (partition.goalId != null && entry.goalId != partition.goalId) {
            return false;
          }
          // Its goal was deleted on this device: drop it with the goal.
          final goalGone = await _tombstoneAt(
            txn,
            household,
            SavingsCollection.goals,
            entry.goalId,
          );
          if (goalGone != null) return false;
          values = entry.toMap();
      }

      if (local != null) {
        final localAt = local['updated_at']! as int;
        if (_localWins(local, remote.updatedAtMs)) return false;
        if (localAt == remote.updatedAtMs) {
          await txn.update(
            table,
            {'sync_status': _synced},
            where: 'id = ? AND updated_at = ?',
            whereArgs: [id, localAt],
          );
          return false;
        }
        if (remote.updatedAtMs < localAt) {
          // The cloud holds an older version than one this device already
          // uploaded (another device overwrote it): send ours again so all
          // devices converge on the newest.
          if (local['sync_status'] == _synced) {
            await txn.update(
              table,
              {'sync_status': _pending},
              where: 'id = ? AND updated_at = ?',
              whereArgs: [id, localAt],
            );
          }
          return false;
        }
      }
      await txn.insert(table, {
        ...values,
        'sync_status': _synced,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (tombstone != null) {
        await _dropTombstone(txn, household, collection, id);
      }
      return true;
    });
  }

  @override
  Future<bool> applySharedGoal(
    CloudRecord remote,
    List<SharedGoalMember> members,
  ) => _db.transaction((txn) async {
    final goal = SavingsGoal.fromCloudMap(
      remote.id,
      remote.data,
      remote.updatedAtMs,
      ownership: SavingsOwnership.shared,
    );
    if (goal == null) return false;
    final local = await _goalRow(txn, goal.id);
    var changed = false;
    if (local == null || local['updated_at'] != remote.updatedAtMs) {
      await txn.insert(Tables.savingsGoals, {
        ...goal.toMap(),
        'sync_status': _synced,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      changed = true;
    }
    final before = await txn.query(
      Tables.savingsMembers,
      where: 'goal_id = ?',
      whereArgs: [goal.id],
    );
    final beforeKeys = {
      for (final r in before) SharedGoalMember.fromMap(r).toMap().toString(),
    };
    final afterKeys = {for (final m in members) m.toMap().toString()};
    if (beforeKeys.length != afterKeys.length ||
        !beforeKeys.containsAll(afterKeys)) {
      await _replaceMembers(txn, goal.id, members);
      changed = true;
    }
    return changed;
  });

  @override
  Future<List<String>> sharedGoalIds() async {
    final rows = await _db.query(
      Tables.savingsGoals,
      columns: ['id'],
      where: "ownership = 'shared'",
    );
    return [for (final r in rows) r['id']! as String];
  }
}
