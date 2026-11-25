import 'package:sqflite/sqflite.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/sync_conflict_resolver.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';

/// A local transaction together with its cloud sync state.
class LocalSyncRecord {
  const LocalSyncRecord({
    required this.transaction,
    required this.status,
    this.cloudUpdatedAt,
  });

  final TransactionModel transaction;
  final RecordSyncStatus status;

  /// `updated_at` of the version last verified in the cloud.
  final DateTime? cloudUpdatedAt;

  /// The data scope (cloud collection) this row belongs to.
  DataScope get scope => transaction.isShared
      ? DataScope.household(transaction.householdId!)
      : const DataScope.personal();

  /// True when this exact version is confirmed to be stored in the cloud.
  bool get isVerifiedInCloud =>
      status == RecordSyncStatus.synced &&
      cloudUpdatedAt?.millisecondsSinceEpoch ==
          transaction.updatedAt.millisecondsSinceEpoch;
}

/// What happened to cached shared data when household access ended.
class HouseholdReleaseResult {
  const HouseholdReleaseResult({required this.kept, required this.removed});

  /// Shared transactions this user created that never reached the cloud;
  /// they were kept as personal transactions so nothing is lost.
  final int kept;

  /// Cached copies of the household's cloud records removed from this
  /// device (the household's cloud history is not touched).
  final int removed;
}

/// Local (SQLite) side of cloud synchronisation.
///
/// Every method works on one [DataScope] (personal by default), so personal
/// and shared records are never pushed to, pulled from or cleaned up with
/// the wrong collection. Every method that removes local rows is guarded so
/// it can only remove a row whose current version is verified in the cloud,
/// or apply a deletion that came from the cloud. Nothing here ever clears a
/// whole table.
abstract class LocalSyncStore {
  Future<String?> getSetting(String key);
  Future<void> setSetting(String key, String value);
  Future<void> removeSetting(String key);

  /// Changes in [scope] not yet confirmed in the cloud (pending or failed),
  /// oldest first.
  Future<List<LocalChange>> pendingChanges({
    int limit = 200,
    DataScope scope = const DataScope.personal(),
  });

  /// Local rows with these IDs, in any scope.
  Future<Map<String, LocalSyncRecord>> getRecords(Iterable<String> ids);

  /// Deletion times of transactions among [ids] deleted locally in [scope].
  Future<Map<String, DateTime>> getTombstones(
    Iterable<String> ids, {
    DataScope scope = const DataScope.personal(),
  });

  /// IDs deleted on this device whose deletion has not reached the cloud.
  Future<Set<String>> allTombstoneIds({DataScope? scope});

  /// Marks the row as synced if it still has [updatedAt]. Returns false if
  /// it was edited or deleted meanwhile (then it stays pending).
  Future<bool> markSynced(String id, DateTime updatedAt);

  /// Removes the tombstone once the cloud records the deletion, unless the
  /// transaction was deleted again later.
  Future<void> clearTombstone(
    String id,
    DateTime deletedAt, {
    DataScope scope = const DataScope.personal(),
  });

  Future<void> markFailed(
    Iterable<LocalChange> changes,
    String error, {
    DataScope scope = const DataScope.personal(),
  });

  /// Applies a cloud document of [scope] to the local database, resolving
  /// conflicts with [SyncConflictResolver]. Documents dated before
  /// [retentionCutoff] are not added to this device (existing rows are
  /// still updated). A local row with the same ID in another scope is never
  /// touched.
  Future<RemoteApplyOutcome> applyRemote(
    CloudTransaction remote, {
    required DateTime retentionCutoff,
    DataScope scope = const DataScope.personal(),
  });

  /// Makes sure the category of [snapshot] exists locally and returns the
  /// local category ID to use. Returns null when nothing usable exists.
  /// New categories from a household are marked with [householdId].
  Future<String?> ensureCategory(
    String categoryId,
    CategorySnapshot? snapshot, {
    String? householdId,
  });

  /// Synced rows of [scope] dated before [cutoff] whose current version is
  /// verified in the cloud: the only rows the retention clean-up may
  /// consider.
  Future<List<TransactionModel>> archiveCandidates(
    DateTime cutoff, {
    int limit = 200,
    DataScope scope = const DataScope.personal(),
  });

  /// Deletes the given rows from this device only, each one only if it is
  /// still synced with the same `updated_at`. Returns the number deleted.
  Future<int> removeArchived(List<TransactionModel> verified);

  /// Marks rows that claimed to be synced but whose cloud copy did not
  /// match as pending again, so they are re-uploaded.
  Future<void> requeue(List<TransactionModel> transactions);

  /// Unsynced changes in [scope], or in all scopes when null.
  Future<({int pending, int failed})> countUnsynced({DataScope? scope});

  /// Removes this device's cached copy of a household's data after the
  /// user lost access. Shared transactions [uid] created that never reached
  /// the cloud become personal instead of being lost. Personal data and the
  /// household's cloud history are never touched.
  Future<HouseholdReleaseResult> releaseHousehold(
    String householdId, {
    required String uid,
  });

  /// Removes the user's personal data from this device after it was reset
  /// in the cloud: personal transactions, deletions waiting to upload,
  /// archived totals, budgets, custom categories (unless shared records
  /// still use them), budget alert state and personal sync position.
  /// Built-in categories are restored to their original state. Shared
  /// household data stays, except [householdId]'s when given (a household
  /// the user just left or deleted as part of the reset).
  ///
  /// With [changedBefore], only records last changed before that time are
  /// removed (another device applying a reset made elsewhere: records
  /// created there since the reset are kept). [resetAt] is stored as the
  /// reset this device has applied.
  Future<void> clearPersonalData({
    required DateTime resetAt,
    DateTime? changedBefore,
    String? householdId,
  });

  /// Reset App (local only): removes every user-specific record from this
  /// device in one SQLite transaction, so either everything or nothing is
  /// cleared. Personal and cached household transactions, budgets, custom
  /// categories, archived totals, pending uploads and deletions, pull
  /// cursors, last-sync time and budget alert state all go; built-in
  /// categories return to their original state. The schema, the account
  /// link and app configuration (retention period) are kept.
  ///
  /// Marks a restore as pending ([SyncKeys.restorePending] = [resetAt]), so
  /// sync downloads nothing until the user restores their cloud data. Only
  /// the device is touched: nothing here talks to the cloud.
  Future<void> clearLocalData({required DateTime resetAt});
}

class SqliteLocalSyncStore implements LocalSyncStore {
  SqliteLocalSyncStore(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const _syncedStatus = 'synced';

  /// SQL condition selecting transactions of [scope].
  static ({String sql, List<Object?> args}) _scopeSql(
    DataScope scope, [
    String alias = '',
  ]) {
    final p = alias.isEmpty ? '' : '$alias.';
    return scope.isPersonal
        ? (sql: "${p}scope = 'personal'", args: const [])
        : (
            sql: "${p}scope = 'shared' AND ${p}household_id = ?",
            args: [scope.householdId],
          );
  }

  @override
  Future<String?> getSetting(String key) async {
    final rows = await _db.query(
      Tables.appSettings,
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> setSetting(String key, String value) async {
    await _db.insert(Tables.appSettings, {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> removeSetting(String key) async {
    await _db.delete(Tables.appSettings, where: 'key = ?', whereArgs: [key]);
  }

  @override
  Future<List<LocalChange>> pendingChanges({
    int limit = 200,
    DataScope scope = const DataScope.personal(),
  }) async {
    final where = _scopeSql(scope, 't');
    final rows = await _db.rawQuery(
      'SELECT t.*, c.name AS c_name, c.type AS c_type, '
      'c.icon_key AS c_icon_key, c.color_value AS c_color_value '
      'FROM ${Tables.transactions} t '
      'LEFT JOIN ${Tables.categories} c ON c.id = t.category_id '
      "WHERE t.sync_status != '$_syncedStatus' AND ${where.sql} "
      'ORDER BY t.updated_at ASC LIMIT ?',
      [...where.args, limit],
    );
    final tombstones = await _db.query(
      Tables.syncTombstones,
      where: 'household_id = ?',
      whereArgs: [scope.storageKey],
      orderBy: 'deleted_at ASC',
      limit: limit,
    );
    return [
      for (final r in rows)
        LocalUpsert(
          TransactionModel.fromMap(r),
          category: r['c_name'] == null
              ? null
              : CategorySnapshot(
                  id: r['category_id']! as String,
                  name: r['c_name']! as String,
                  type: TransactionType.fromName(r['c_type']! as String),
                  iconKey: r['c_icon_key']! as String,
                  colorValue: r['c_color_value']! as int,
                ),
        ),
      for (final r in tombstones)
        LocalDeletion(
          r['id']! as String,
          DateTime.fromMillisecondsSinceEpoch(r['deleted_at']! as int),
        ),
    ];
  }

  @override
  Future<Map<String, LocalSyncRecord>> getRecords(Iterable<String> ids) =>
      _getRecords(_db, ids);

  static Future<Map<String, LocalSyncRecord>> _getRecords(
    DatabaseExecutor db,
    Iterable<String> ids,
  ) async {
    final list = ids.toSet().toList();
    final result = <String, LocalSyncRecord>{};
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, (i + 500).clamp(0, list.length));
      final rows = await db.query(
        Tables.transactions,
        where: 'id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      for (final r in rows) {
        final cloud = r['cloud_updated_at'] as int?;
        result[r['id']! as String] = LocalSyncRecord(
          transaction: TransactionModel.fromMap(r),
          status: RecordSyncStatus.fromName(r['sync_status'] as String?),
          cloudUpdatedAt: cloud == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(cloud),
        );
      }
    }
    return result;
  }

  @override
  Future<Map<String, DateTime>> getTombstones(
    Iterable<String> ids, {
    DataScope scope = const DataScope.personal(),
  }) => _getTombstones(_db, ids, scope);

  static Future<Map<String, DateTime>> _getTombstones(
    DatabaseExecutor db,
    Iterable<String> ids,
    DataScope scope,
  ) async {
    final list = ids.toSet().toList();
    final result = <String, DateTime>{};
    for (var i = 0; i < list.length; i += 500) {
      final chunk = list.sublist(i, (i + 500).clamp(0, list.length));
      final rows = await db.query(
        Tables.syncTombstones,
        where:
            'household_id = ? AND '
            'id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [scope.storageKey, ...chunk],
      );
      for (final r in rows) {
        result[r['id']! as String] = DateTime.fromMillisecondsSinceEpoch(
          r['deleted_at']! as int,
        );
      }
    }
    return result;
  }

  @override
  Future<Set<String>> allTombstoneIds({DataScope? scope}) async {
    final rows = await _db.query(
      Tables.syncTombstones,
      columns: ['id'],
      where: scope == null ? null : 'household_id = ?',
      whereArgs: scope == null ? null : [scope.storageKey],
    );
    return {for (final r in rows) r['id']! as String};
  }

  @override
  Future<bool> markSynced(String id, DateTime updatedAt) async {
    final ms = updatedAt.millisecondsSinceEpoch;
    final count = await _db.update(
      Tables.transactions,
      {
        'sync_status': _syncedStatus,
        'cloud_updated_at': ms,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
        'sync_error': null,
      },
      where: 'id = ? AND updated_at = ?',
      whereArgs: [id, ms],
    );
    return count > 0;
  }

  @override
  Future<void> clearTombstone(
    String id,
    DateTime deletedAt, {
    DataScope scope = const DataScope.personal(),
  }) async {
    await _db.delete(
      Tables.syncTombstones,
      where: 'id = ? AND household_id = ? AND deleted_at <= ?',
      whereArgs: [id, scope.storageKey, deletedAt.millisecondsSinceEpoch],
    );
  }

  @override
  Future<void> markFailed(
    Iterable<LocalChange> changes,
    String error, {
    DataScope scope = const DataScope.personal(),
  }) async {
    final batch = _db.batch();
    for (final change in changes) {
      switch (change) {
        case LocalUpsert(:final transaction):
          batch.update(
            Tables.transactions,
            {'sync_status': RecordSyncStatus.failed.name, 'sync_error': error},
            where: "id = ? AND updated_at = ? AND sync_status != 'synced'",
            whereArgs: [
              transaction.id,
              transaction.updatedAt.millisecondsSinceEpoch,
            ],
          );
        case LocalDeletion(:final id, :final deletedAt):
          batch.update(
            Tables.syncTombstones,
            {'sync_status': RecordSyncStatus.failed.name, 'sync_error': error},
            where: 'id = ? AND household_id = ? AND deleted_at = ?',
            whereArgs: [id, scope.storageKey, deletedAt.millisecondsSinceEpoch],
          );
      }
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<RemoteApplyOutcome> applyRemote(
    CloudTransaction remote, {
    required DateTime retentionCutoff,
    DataScope scope = const DataScope.personal(),
  }) {
    return _db.transaction((txn) async {
      final id = remote.id;
      final local = (await _getRecords(txn, [id]))[id];
      // The same ID in another scope (a transaction moved between personal
      // and shared) is handled by that scope's own sync.
      if (local != null && local.scope != scope) {
        return RemoteApplyOutcome.unchanged;
      }
      final tombstone = (await _getTombstones(txn, [id], scope))[id];
      if (local == null && tombstone == null) {
        await _trackArchived(txn, remote, scope, retentionCutoff);
      }
      final action = SyncConflictResolver.resolvePull(
        remote: remote,
        local: local,
        tombstoneDeletedAt: tombstone,
        retentionCutoff: retentionCutoff,
      );
      switch (action) {
        case PullAction.keepLocal:
          return RemoteApplyOutcome.unchanged;
        case PullAction.skipArchived:
          if (tombstone != null) await _dropTombstone(txn, id, scope);
          return RemoteApplyOutcome.skippedArchived;
        case PullAction.confirmLocal:
          await _markSyncedTxn(txn, remote.transaction);
          return RemoteApplyOutcome.unchanged;
        case PullAction.deleteLocal:
          if (tombstone != null) await _dropTombstone(txn, id, scope);
          if (local == null) return RemoteApplyOutcome.unchanged;
          await txn.delete(
            Tables.transactions,
            where: 'id = ?',
            whereArgs: [id],
          );
          return RemoteApplyOutcome.deleted;
        case PullAction.clearTombstone:
          await _dropTombstone(txn, id, scope);
          return RemoteApplyOutcome.unchanged;
        case PullAction.writeRemote:
          if (tombstone != null) await _dropTombstone(txn, id, scope);
          final categoryId = await _ensureCategory(
            txn,
            remote.transaction.categoryId,
            remote.category,
            householdId: scope.householdId,
          );
          if (categoryId == null) {
            throw StateError('No category available for cloud transaction $id');
          }
          final row = {
            ...remote.transaction.copyWith(categoryId: categoryId).toMap(),
            // The collection decides the scope, never the document.
            'scope': scope.transactionScope.name,
            'household_id': scope.householdId,
            'sync_status': _syncedStatus,
            'cloud_updated_at': remote.updatedAtMs,
            'synced_at': DateTime.now().millisecondsSinceEpoch,
            'sync_error': null,
          };
          if (local == null) {
            await txn.insert(Tables.transactions, row);
            return RemoteApplyOutcome.inserted;
          }
          await txn.update(
            Tables.transactions,
            row,
            where: 'id = ?',
            whereArgs: [id],
          );
          return RemoteApplyOutcome.updated;
      }
    });
  }

  /// Keeps `archived_totals` in step with a cloud record that is not
  /// stored on this device: counted while it is older than the retention
  /// window and not deleted.
  static Future<void> _trackArchived(
    DatabaseExecutor db,
    CloudTransaction remote,
    DataScope scope,
    DateTime retentionCutoff,
  ) async {
    if (remote.deleted || !remote.transaction.date.isBefore(retentionCutoff)) {
      await db.delete(
        Tables.archivedTotals,
        where: 'id = ?',
        whereArgs: [remote.id],
      );
      return;
    }
    await db.insert(Tables.archivedTotals, {
      'id': remote.id,
      'household_id': scope.storageKey,
      'type': remote.transaction.type.name,
      'amount_minor': remote.transaction.amountMinor,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> _dropTombstone(
    DatabaseExecutor db,
    String id,
    DataScope scope,
  ) => db.delete(
    Tables.syncTombstones,
    where: 'id = ? AND household_id = ?',
    whereArgs: [id, scope.storageKey],
  );

  static Future<void> _markSyncedTxn(DatabaseExecutor db, TransactionModel t) =>
      db.update(
        Tables.transactions,
        {
          'sync_status': _syncedStatus,
          'cloud_updated_at': t.updatedAt.millisecondsSinceEpoch,
          'synced_at': DateTime.now().millisecondsSinceEpoch,
          'sync_error': null,
        },
        where: 'id = ? AND updated_at = ?',
        whereArgs: [t.id, t.updatedAt.millisecondsSinceEpoch],
      );

  @override
  Future<String?> ensureCategory(
    String categoryId,
    CategorySnapshot? snapshot, {
    String? householdId,
  }) => _db.transaction(
    (txn) =>
        _ensureCategory(txn, categoryId, snapshot, householdId: householdId),
  );

  /// Uses the category with [categoryId] if it exists, else a local
  /// category with the same name and type, else creates it from [snapshot].
  /// Existing categories are never modified.
  static Future<String?> _ensureCategory(
    DatabaseExecutor db,
    String categoryId,
    CategorySnapshot? snapshot, {
    String? householdId,
  }) async {
    final byId = await db.query(
      Tables.categories,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [categoryId],
      limit: 1,
    );
    if (byId.isNotEmpty) return categoryId;
    if (snapshot == null) return null;

    final byName = await db.query(
      Tables.categories,
      columns: ['id'],
      where: 'name = ? COLLATE NOCASE AND type = ?',
      whereArgs: [snapshot.name, snapshot.type.name],
      limit: 1,
    );
    if (byName.isNotEmpty) return byName.first['id']! as String;

    final order = await db.rawQuery(
      'SELECT COALESCE(MAX(sort_order), 0) + 1 AS n FROM ${Tables.categories}',
    );
    final category = CategoryModel(
      id: categoryId,
      name: snapshot.name,
      type: snapshot.type,
      iconKey: snapshot.iconKey,
      colorValue: snapshot.colorValue,
      sortOrder: (order.first['n'] as int?) ?? 0,
    );
    await db.insert(Tables.categories, {
      ...category.toMap(),
      // Received from the cloud: nothing to upload. Household categories are
      // marked so they never go to the personal collection.
      'household_id': householdId,
      'sync_status': _syncedStatus,
    });
    return categoryId;
  }

  @override
  Future<List<TransactionModel>> archiveCandidates(
    DateTime cutoff, {
    int limit = 200,
    DataScope scope = const DataScope.personal(),
  }) async {
    final where = _scopeSql(scope, 't');
    final rows = await _db.rawQuery(
      'SELECT t.* FROM ${Tables.transactions} t '
      "WHERE t.sync_status = '$_syncedStatus' "
      'AND t.cloud_updated_at = t.updated_at '
      'AND t.date < ? '
      'AND ${where.sql} '
      'AND NOT EXISTS (SELECT 1 FROM ${Tables.syncTombstones} s '
      'WHERE s.id = t.id) '
      'ORDER BY t.date ASC LIMIT ?',
      [cutoff.millisecondsSinceEpoch, ...where.args, limit],
    );
    return rows.map(TransactionModel.fromMap).toList();
  }

  @override
  Future<int> removeArchived(List<TransactionModel> verified) async {
    if (verified.isEmpty) return 0;
    return _db.transaction((txn) async {
      var removed = 0;
      for (final t in verified) {
        // Row-by-row and fully conditioned: an edit made after verification
        // changes updated_at / sync_status, and the row is then kept.
        final count = await txn.delete(
          Tables.transactions,
          where:
              "id = ? AND updated_at = ? AND sync_status = '$_syncedStatus' "
              'AND cloud_updated_at = updated_at',
          whereArgs: [t.id, t.updatedAt.millisecondsSinceEpoch],
        );
        if (count > 0) {
          // Still counted in all-time balances.
          await txn.insert(Tables.archivedTotals, {
            'id': t.id,
            'household_id': t.householdId ?? '',
            'type': t.type.name,
            'amount_minor': t.amountMinor,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        removed += count;
      }
      return removed;
    });
  }

  @override
  Future<void> requeue(List<TransactionModel> transactions) async {
    final batch = _db.batch();
    for (final t in transactions) {
      batch.update(
        Tables.transactions,
        {
          'sync_status': RecordSyncStatus.pending.name,
          'cloud_updated_at': null,
        },
        where: 'id = ? AND updated_at = ?',
        whereArgs: [t.id, t.updatedAt.millisecondsSinceEpoch],
      );
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<({int pending, int failed})> countUnsynced({DataScope? scope}) async {
    final t = scope == null ? null : _scopeSql(scope);
    final tWhere = t == null ? '' : ' AND ${t.sql}';
    final sWhere = scope == null ? '' : ' AND household_id = ?';
    final rows = await _db.rawQuery(
      'SELECT '
      "(SELECT COUNT(*) FROM ${Tables.transactions} WHERE sync_status = 'pending'$tWhere) + "
      "(SELECT COUNT(*) FROM ${Tables.syncTombstones} WHERE sync_status = 'pending'$sWhere) AS p, "
      "(SELECT COUNT(*) FROM ${Tables.transactions} WHERE sync_status = 'failed'$tWhere) + "
      "(SELECT COUNT(*) FROM ${Tables.syncTombstones} WHERE sync_status = 'failed'$sWhere) AS f",
      [
        if (t != null) ...t.args,
        if (scope != null) scope.storageKey,
        if (t != null) ...t.args,
        if (scope != null) scope.storageKey,
      ],
    );
    return (
      pending: (rows.first['p'] as int?) ?? 0,
      failed: (rows.first['f'] as int?) ?? 0,
    );
  }

  @override
  Future<HouseholdReleaseResult> releaseHousehold(
    String householdId, {
    required String uid,
  }) async {
    final scope = DataScope.household(householdId);
    final result = await _db.transaction((txn) async {
      // Created here by this user and never confirmed in the cloud: the
      // only copy is on this device, so keep it as a personal transaction.
      final kept = await txn.rawUpdate(
        'UPDATE ${Tables.transactions} SET '
        "scope = 'personal', household_id = NULL, "
        "sync_status = 'pending', cloud_updated_at = NULL, sync_error = NULL "
        "WHERE scope = 'shared' AND household_id = ? AND created_by = ? "
        'AND cloud_updated_at IS NULL',
        [householdId, uid],
      );
      // Everything else is a cached copy of the household's cloud data.
      final removed = await txn.delete(
        Tables.transactions,
        where: "scope = 'shared' AND household_id = ?",
        whereArgs: [householdId],
      );
      await txn.delete(
        Tables.syncTombstones,
        where: 'household_id = ?',
        whereArgs: [householdId],
      );
      await txn.delete(
        Tables.cloudTombstones,
        where: 'household_id = ?',
        whereArgs: [householdId],
      );
      await txn.delete(
        Tables.archivedTotals,
        where: 'household_id = ?',
        whereArgs: [householdId],
      );
      await txn.delete(
        Tables.budgets,
        where: 'household_id = ?',
        whereArgs: [householdId],
      );
      await txn.delete(
        Tables.categoryBudgets,
        where: 'household_id = ?',
        whereArgs: [householdId],
      );
      // Shared rules can no longer add to the household.
      await txn.delete(
        Tables.recurringRules,
        where: 'household_id = ?',
        whereArgs: [householdId],
      );
      // The household's savings goals and their history (cached copies).
      await txn.rawDelete(
        'DELETE FROM ${Tables.savingsEntries} WHERE goal_id IN (SELECT id '
        "FROM ${Tables.savingsGoals} WHERE ownership = 'household' "
        'AND household_id = ?)',
        [householdId],
      );
      await txn.delete(
        Tables.savingsGoals,
        where: "ownership = 'household' AND household_id = ?",
        whereArgs: [householdId],
      );
      // The household's loans, repayments and reminder settings (cached
      // copies; the cloud keeps them for the household).
      await deleteLoansOf(txn, householdId);
      for (final key in [
        SyncKeys.cursorMicros(scope),
        SyncKeys.cursorDocId(scope),
      ]) {
        await txn.delete(
          Tables.appSettings,
          where: 'key = ?',
          whereArgs: [key],
        );
      }
      await txn.delete(
        Tables.appSettings,
        where: 'key LIKE ? OR key LIKE ?',
        whereArgs: ['alert.h.$householdId.%', 'sync.household:$householdId.%'],
      );
      return HouseholdReleaseResult(kept: kept, removed: removed);
    });
    return result;
  }

  @override
  Future<void> clearPersonalData({
    required DateTime resetAt,
    DateTime? changedBefore,
    String? householdId,
  }) async {
    final before = changedBefore?.millisecondsSinceEpoch;
    // " AND updated_at < ?" when only older records are removed.
    String older(String column) => before == null ? '' : ' AND $column < ?';
    List<Object?> args([List<Object?> base = const []]) => [
      ...base,
      if (before != null) before,
    ];

    await _db.transaction((txn) async {
      if (householdId != null) {
        // The household is gone for this user: drop its cached copy without
        // turning unsent shared records into personal ones.
        for (final table in [
          Tables.syncTombstones,
          Tables.cloudTombstones,
          Tables.archivedTotals,
          Tables.budgets,
          Tables.categoryBudgets,
          Tables.recurringRules,
        ]) {
          await txn.delete(
            table,
            where: 'household_id = ?',
            whereArgs: [householdId],
          );
        }
        await txn.delete(
          Tables.transactions,
          where: "scope = 'shared' AND household_id = ?",
          whereArgs: [householdId],
        );
        // The household's savings goals and their history (cached copies).
        await txn.rawDelete(
          'DELETE FROM ${Tables.savingsEntries} WHERE goal_id IN (SELECT id '
          "FROM ${Tables.savingsGoals} WHERE ownership = 'household' "
          'AND household_id = ?)',
          [householdId],
        );
        await txn.delete(
          Tables.savingsGoals,
          where: "ownership = 'household' AND household_id = ?",
          whereArgs: [householdId],
        );
        await deleteLoansOf(txn, householdId);
        final scope = DataScope.household(householdId);
        await txn.delete(
          Tables.appSettings,
          where: 'key IN (?, ?) OR key LIKE ?',
          whereArgs: [
            SyncKeys.cursorMicros(scope),
            SyncKeys.cursorDocId(scope),
            'alert.h.$householdId.%',
          ],
        );
      }

      // Pending and synced personal records alike: nothing old may be
      // uploaded again.
      await txn.delete(
        Tables.transactions,
        where: "scope = 'personal'${older('updated_at')}",
        whereArgs: args(),
      );
      await txn.delete(
        Tables.syncTombstones,
        where: "household_id = ''${older('deleted_at')}",
        whereArgs: args(),
      );
      // The cloud history these describe no longer exists; the next pull
      // rebuilds them from what is left.
      await txn.delete(Tables.archivedTotals, where: "household_id = ''");
      await txn.delete(Tables.cloudTombstones, where: "household_id = ''");
      await txn.delete(
        Tables.categoryBudgets,
        where: "household_id = ''${older('updated_at')}",
        whereArgs: args(),
      );
      await txn.delete(
        Tables.budgets,
        where: "household_id = ''${older('updated_at')}",
        whereArgs: args(),
      );
      await txn.delete(
        Tables.recurringRules,
        where: "household_id = ''${older('created_at')}",
        whereArgs: args(),
      );
      // Personal savings only; household and shared goals belong to others
      // too and are not part of a personal reset.
      await txn.rawDelete(
        'DELETE FROM ${Tables.savingsEntries} WHERE goal_id IN (SELECT id '
        "FROM ${Tables.savingsGoals} WHERE ownership = 'personal')"
        '${older('updated_at')}',
        args(),
      );
      await txn.delete(
        Tables.savingsGoals,
        where: "ownership = 'personal'${older('updated_at')}",
        whereArgs: args(),
      );
      // Personal lending only. Instalments, repayments and settings go with
      // their loan.
      await txn.delete(
        Tables.loans,
        where: "household_id = ''${older('updated_at')}",
        whereArgs: args(),
      );
      await deleteOrphanedLoanRows(txn);
      // Custom personal categories, unless remaining (shared) records use
      // them.
      await txn.rawDelete(
        'DELETE FROM ${Tables.categories} WHERE is_default = 0 '
        'AND household_id IS NULL${older('updated_at')} '
        'AND id NOT IN (SELECT category_id FROM ${Tables.transactions}) '
        'AND id NOT IN (SELECT category_id FROM ${Tables.categoryBudgets})',
        args(),
      );
      // Built-in categories back to their original names and colours.
      for (final c in DefaultCategories.all) {
        await txn.update(
          Tables.categories,
          {
            ...c.toMap()..remove('id'),
            'updated_at': 0,
            'sync_status': RecordSyncStatus.pending.name,
          },
          where: 'id = ?${older('updated_at')}',
          whereArgs: args([c.id]),
        );
      }
      await AppDatabase.ensureDefaultCategories(txn);

      // Personal sync position, status and budget alert state.
      await txn.delete(
        Tables.appSettings,
        where:
            'key IN (?, ?, ?, ?, ?, ?, ?) OR (key LIKE ? AND key NOT LIKE ?)',
        whereArgs: [
          SyncKeys.pullCursorMicros,
          SyncKeys.pullCursorDocId,
          SyncKeys.lastSyncedAt,
          SyncKeys.savingsGoalsCursorMicros,
          SyncKeys.savingsGoalsCursorDocId,
          SyncKeys.savingsEntriesCursorMicros,
          SyncKeys.savingsEntriesCursorDocId,
          'alert.%',
          'alert.h.%',
        ],
      );
      await txn.delete(
        Tables.appSettings,
        where: 'key LIKE ?',
        whereArgs: ['${SyncKeys.personalLoansPrefix}%'],
      );
      await txn.insert(Tables.appSettings, {
        'key': SyncKeys.personalResetAt,
        'value': resetAt.millisecondsSinceEpoch.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<void> clearLocalData({required DateTime resetAt}) async {
    await _db.transaction((txn) async {
      // Every scope, synced or not: nothing old may be uploaded again.
      for (final table in [
        Tables.syncTombstones,
        Tables.cloudTombstones,
        Tables.archivedTotals,
        Tables.categoryBudgets,
        Tables.budgets,
        Tables.transactions,
        Tables.recurringRules,
        Tables.savingsGoals,
        Tables.savingsEntries,
        Tables.savingsMembers,
        Tables.savingsInvitations,
        Tables.loans,
        Tables.loanInstallments,
        Tables.loanRepayments,
        Tables.loanReminders,
      ]) {
        await txn.delete(table);
      }
      await txn.delete(Tables.categories, where: 'is_default = 0');
      // Built-in categories back to their original names and colours
      // (updated_at 0: never uploaded, so no cloud category is overwritten).
      for (final c in DefaultCategories.all) {
        await txn.update(
          Tables.categories,
          {
            ...c.toMap()..remove('id'),
            'household_id': null,
            'updated_at': 0,
            'sync_status': RecordSyncStatus.pending.name,
          },
          where: 'id = ?',
          whereArgs: [c.id],
        );
      }
      await AppDatabase.ensureDefaultCategories(txn);

      // Pull positions of every scope, last sync time and budget alerts.
      await txn.delete(
        Tables.appSettings,
        where: 'key IN (?, ?, ?) OR key LIKE ? OR key LIKE ?',
        whereArgs: [
          SyncKeys.pullCursorMicros,
          SyncKeys.pullCursorDocId,
          SyncKeys.lastSyncedAt,
          'sync.%.pull_cursor_%',
          'alert.%',
        ],
      );
      await txn.insert(Tables.appSettings, {
        'key': SyncKeys.restorePending,
        'value': resetAt.millisecondsSinceEpoch.toString(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
}

/// Reads the configured local retention period, falling back to
/// [AppConstants.defaultLocalRetentionDays].
int parseRetentionDays(String? value) {
  final days = int.tryParse(value ?? '');
  if (days == null || days < AppConstants.minLocalRetentionDays) {
    return AppConstants.defaultLocalRetentionDays;
  }
  return days;
}

/// Removes [householdId]'s loans with their schedules, repayments and
/// reminder settings from this device (cached copies of the household's
/// cloud data).
Future<void> deleteLoansOf(DatabaseExecutor db, String householdId) async {
  await db.delete(
    Tables.loans,
    where: 'household_id = ?',
    whereArgs: [householdId],
  );
  await deleteOrphanedLoanRows(db);
}

/// Removes instalments, repayments and reminder settings whose loan is no
/// longer on this device.
Future<void> deleteOrphanedLoanRows(DatabaseExecutor db) async {
  for (final table in [
    Tables.loanInstallments,
    Tables.loanRepayments,
    Tables.loanReminders,
  ]) {
    await db.rawDelete(
      'DELETE FROM $table WHERE loan_id NOT IN '
      '(SELECT id FROM ${Tables.loans})',
    );
  }
}
