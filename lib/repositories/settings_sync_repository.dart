import 'package:sqflite/sqflite.dart';

import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/category_repository.dart';

/// Which local row a [PendingRecord] confirms once uploaded.
enum PendingSource { category, target, categoryBudget, tombstone }

/// A local budget / category change ready to upload.
class PendingRecord {
  const PendingRecord({
    required this.record,
    required this.source,
    required this.localId,
    required this.stamp,
  });

  final CloudRecord record;
  final PendingSource source;

  /// Primary key of the local row (or tombstone id).
  final Object localId;

  /// `updated_at` / `deleted_at` the upload was built from; confirmation
  /// only applies while the row still has it.
  final int stamp;
}

/// Local side of budget and category synchronisation.
///
/// Budgets and categories are small, so each sync uploads pending rows and
/// then reads the whole cloud collection, merging by `updatedAt` (last
/// writer wins). Deletions travel as tombstones.
abstract class LocalSettingsSyncStore {
  /// Local changes of [kind] in [scope] waiting for upload.
  Future<List<PendingRecord>> pendingRecords(
    DataScope scope,
    CloudRecordKind kind,
  );

  /// Marks uploaded rows as synced (unless changed since) and drops
  /// uploaded tombstones.
  Future<void> confirmUploaded(DataScope scope, List<PendingRecord> uploaded);

  /// Applies one cloud document; returns true when local data changed.
  Future<bool> applyRemote(
    DataScope scope,
    CloudRecordKind kind,
    CloudRecord remote,
  );

  /// Custom categories used by [scope]'s shared records that the household
  /// collection does not have yet (or has an older version of), given the
  /// `updatedAt` of every category document already in the cloud.
  Future<List<CloudRecord>> householdCategoryUploads(
    DataScope scope,
    Map<String, int> cloudUpdatedAt,
  );
}

class SqliteSettingsSyncStore implements LocalSettingsSyncStore {
  SqliteSettingsSyncStore(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const _synced = 'synced';
  static const _pending = 'pending';

  // ------------------------------------------------------------ encoding

  static Map<String, Object?> _categoryData(Map<String, Object?> row) => {
    'name': row['name'],
    'type': row['type'],
    'iconKey': row['icon_key'],
    'colorValue': row['color_value'],
    'sortOrder': row['sort_order'],
  };

  static CloudRecord _categoryRecord(Map<String, Object?> row) {
    final updated = row['updated_at']! as int;
    return CloudRecord(
      id: row['id']! as String,
      data: _categoryData(row),
      updatedAtMs: updated,
    );
  }

  static CloudRecord _targetRecord(BudgetTarget t) => CloudRecord(
    id: t.cloudId,
    data: {
      'kind': 'target',
      'period': t.period.name,
      'amountMinor': t.amountMinor,
      'effectiveFrom': t.effectiveFrom.millisecondsSinceEpoch,
    },
    updatedAtMs: t.updatedAt.millisecondsSinceEpoch,
  );

  static CloudRecord _categoryBudgetRecord(
    CategoryBudget b,
    CategorySnapshot? category,
  ) => CloudRecord(
    id: b.cloudId,
    data: {
      'kind': 'category',
      'budgetId': b.id,
      'categoryId': b.categoryId,
      'period': b.period.name,
      'amountMinor': b.amountMinor,
      'createdAt': b.createdAt.millisecondsSinceEpoch,
      if (category != null) 'category': category.toCloudMap(),
    },
    updatedAtMs: b.updatedAt.millisecondsSinceEpoch,
  );

  // -------------------------------------------------------------- upload

  @override
  Future<List<PendingRecord>> pendingRecords(
    DataScope scope,
    CloudRecordKind kind,
  ) async {
    final result = <PendingRecord>[];
    switch (kind) {
      case CloudRecordKind.categories:
        // Household categories are uploaded from the records that use them
        // (householdCategoryUploads); only personal ones are tracked here.
        if (scope.isHousehold) break;
        final rows = await _db.query(
          Tables.categories,
          where:
              "sync_status = '$_pending' AND household_id IS NULL "
              'AND updated_at > 0',
        );
        for (final r in rows) {
          result.add(
            PendingRecord(
              record: _categoryRecord(r),
              source: PendingSource.category,
              localId: r['id']! as String,
              stamp: r['updated_at']! as int,
            ),
          );
        }
      case CloudRecordKind.budgets:
        final targets = await _db.query(
          Tables.budgets,
          where: "sync_status = '$_pending' AND household_id = ?",
          whereArgs: [scope.storageKey],
        );
        for (final r in targets) {
          final t = BudgetTarget.fromMap(r);
          result.add(
            PendingRecord(
              record: _targetRecord(t),
              source: PendingSource.target,
              localId: t.id!,
              stamp: t.updatedAt.millisecondsSinceEpoch,
            ),
          );
        }
        final budgets = await _db.rawQuery(
          'SELECT b.*, c.name AS c_name, c.type AS c_type, '
          'c.icon_key AS c_icon_key, c.color_value AS c_color_value '
          'FROM ${Tables.categoryBudgets} b '
          'LEFT JOIN ${Tables.categories} c ON c.id = b.category_id '
          "WHERE b.sync_status = '$_pending' AND b.household_id = ?",
          [scope.storageKey],
        );
        for (final r in budgets) {
          final b = CategoryBudget.fromMap(r);
          result.add(
            PendingRecord(
              record: _categoryBudgetRecord(
                b,
                r['c_name'] == null
                    ? null
                    : CategorySnapshot(
                        id: b.categoryId,
                        name: r['c_name']! as String,
                        type: TransactionType.fromName(r['c_type']! as String),
                        iconKey: r['c_icon_key']! as String,
                        colorValue: r['c_color_value']! as int,
                      ),
              ),
              source: PendingSource.categoryBudget,
              localId: b.id,
              stamp: b.updatedAt.millisecondsSinceEpoch,
            ),
          );
        }
    }

    final tombstones = await _db.query(
      Tables.cloudTombstones,
      where: 'collection = ? AND household_id = ?',
      whereArgs: [_collection(kind), scope.storageKey],
    );
    for (final r in tombstones) {
      final id = r['id']! as String;
      final at = r['deleted_at']! as int;
      result.add(
        PendingRecord(
          record: CloudRecord.deletion(id, at),
          source: PendingSource.tombstone,
          localId: id,
          stamp: at,
        ),
      );
    }
    return result;
  }

  static String _collection(CloudRecordKind kind) =>
      kind == CloudRecordKind.budgets
      ? CloudCollections.budgets
      : CloudCollections.categories;

  @override
  Future<void> confirmUploaded(
    DataScope scope,
    List<PendingRecord> uploaded,
  ) async {
    final batch = _db.batch();
    for (final p in uploaded) {
      switch (p.source) {
        case PendingSource.category:
          batch.update(
            Tables.categories,
            {'sync_status': _synced},
            where: 'id = ? AND updated_at = ?',
            whereArgs: [p.localId, p.stamp],
          );
        case PendingSource.target:
          batch.update(
            Tables.budgets,
            {'sync_status': _synced},
            where: 'id = ? AND updated_at = ?',
            whereArgs: [p.localId, p.stamp],
          );
        case PendingSource.categoryBudget:
          batch.update(
            Tables.categoryBudgets,
            {'sync_status': _synced},
            where: 'id = ? AND updated_at = ?',
            whereArgs: [p.localId, p.stamp],
          );
        case PendingSource.tombstone:
          batch.delete(
            Tables.cloudTombstones,
            where:
                'collection IN (?, ?) AND household_id = ? AND id = ? '
                'AND deleted_at <= ?',
            whereArgs: [
              CloudCollections.budgets,
              CloudCollections.categories,
              scope.storageKey,
              p.localId,
              p.stamp,
            ],
          );
      }
    }
    await batch.commit(noResult: true);
  }

  // ---------------------------------------------------------------- pull

  @override
  Future<bool> applyRemote(
    DataScope scope,
    CloudRecordKind kind,
    CloudRecord remote,
  ) {
    return _db.transaction(
      (txn) => switch (kind) {
        CloudRecordKind.categories => _applyCategory(txn, scope, remote),
        CloudRecordKind.budgets => _applyBudget(txn, scope, remote),
      },
    );
  }

  static Future<int?> _tombstoneAt(
    DatabaseExecutor db,
    String collection,
    DataScope scope,
    String id,
  ) async {
    final rows = await db.query(
      Tables.cloudTombstones,
      columns: ['deleted_at'],
      where: 'collection = ? AND household_id = ? AND id = ?',
      whereArgs: [collection, scope.storageKey, id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['deleted_at']! as int;
  }

  static Future<void> _dropTombstone(
    DatabaseExecutor db,
    String collection,
    DataScope scope,
    String id,
  ) => db.delete(
    Tables.cloudTombstones,
    where: 'collection = ? AND household_id = ? AND id = ?',
    whereArgs: [collection, scope.storageKey, id],
  );

  static bool _localWins(Map<String, Object?> local, int remoteAt) =>
      local['sync_status'] == _pending &&
      (local['updated_at']! as int) > remoteAt;

  Future<bool> _applyCategory(
    Transaction txn,
    DataScope scope,
    CloudRecord remote,
  ) async {
    final id = remote.id;
    final tombstone = await _tombstoneAt(
      txn,
      CloudCollections.categories,
      scope,
      id,
    );
    if (tombstone != null && tombstone >= remote.updatedAtMs) return false;

    final rows = await txn.query(
      Tables.categories,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final local = rows.isEmpty ? null : rows.first;
    // Only categories of this scope may be changed by its collection.
    final owned = local == null || local['household_id'] == scope.householdId;

    if (remote.deleted) {
      if (tombstone != null) {
        await _dropTombstone(txn, CloudCollections.categories, scope, id);
      }
      if (local == null || !owned || (local['is_default'] as int? ?? 0) == 1) {
        return false;
      }
      if (_localWins(local, remote.updatedAtMs)) return false;
      final usedByShared = await txn.rawQuery(
        'SELECT '
        "(SELECT COUNT(*) FROM ${Tables.transactions} WHERE category_id = ? AND scope = 'shared') + "
        "(SELECT COUNT(*) FROM ${Tables.categoryBudgets} WHERE category_id = ? AND household_id != '') AS n",
        [id, id],
      );
      if (((usedByShared.first['n'] as int?) ?? 0) > 0) return false;
      await SqliteCategoryRepository.deleteWithin(
        txn,
        id,
        TransactionType.fromName(local['type']! as String),
      );
      // Already deleted in the cloud: no new tombstone needed.
      await _dropTombstone(txn, CloudCollections.categories, scope, id);
      return true;
    }

    final data = remote.data;
    final name = data['name'];
    final type = data['type'];
    final icon = data['iconKey'];
    final color = data['colorValue'];
    if (name is! String || name.trim().isEmpty || type is! String) {
      return false;
    }
    if (icon is! String || color is! int) return false;
    final TransactionType parsedType;
    try {
      parsedType = TransactionType.fromName(type);
    } on FormatException {
      return false;
    }
    final sortOrder = data['sortOrder'] is int ? data['sortOrder']! as int : 50;

    if (local == null) {
      final clash = await txn.query(
        Tables.categories,
        columns: ['id'],
        where: 'name = ? COLLATE NOCASE AND type = ?',
        whereArgs: [name, parsedType.name],
        limit: 1,
      );
      // A local category with the same name is used instead.
      if (clash.isNotEmpty) return false;
      await txn.insert(Tables.categories, {
        'id': id,
        'name': name,
        'type': parsedType.name,
        'icon_key': icon,
        'color_value': color,
        'is_default': DefaultCategories.all.any((c) => c.id == id) ? 1 : 0,
        'sort_order': sortOrder,
        'household_id': scope.householdId,
        'updated_at': remote.updatedAtMs,
        'sync_status': _synced,
      });
      return true;
    }

    if (!owned) return false;
    final localAt = local['updated_at']! as int;
    if (_localWins(local, remote.updatedAtMs)) return false;
    if (localAt == remote.updatedAtMs) {
      await txn.update(
        Tables.categories,
        {'sync_status': _synced},
        where: 'id = ? AND updated_at = ?',
        whereArgs: [id, localAt],
      );
      return false;
    }
    if (remote.updatedAtMs < localAt) return false;
    try {
      await txn.update(
        Tables.categories,
        {
          'name': name,
          'icon_key': icon,
          'color_value': color,
          'sort_order': sortOrder,
          'updated_at': remote.updatedAtMs,
          'sync_status': _synced,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } on DatabaseException {
      // The new name clashes with another local category; keep ours.
      return false;
    }
    return true;
  }

  Future<bool> _applyBudget(
    Transaction txn,
    DataScope scope,
    CloudRecord remote,
  ) async {
    final data = remote.data;
    final BudgetPeriod period;
    try {
      period = BudgetPeriod.fromName(data['period'] as String? ?? '');
    } on FormatException {
      return false;
    }
    final amount = data['amountMinor'];
    if (amount is! int || amount < 0) return false;
    final household = scope.storageKey;

    if (data['kind'] == 'target') {
      final from = data['effectiveFrom'];
      if (from is! int || remote.deleted) return false;
      final rows = await txn.query(
        Tables.budgets,
        where: 'household_id = ? AND period = ? AND effective_from = ?',
        whereArgs: [household, period.name, from],
        limit: 1,
      );
      final values = {
        'household_id': household,
        'period': period.name,
        'amount_minor': amount,
        'effective_from': from,
        'updated_at': remote.updatedAtMs,
        'updated_by': data['updatedBy'] as String?,
        'sync_status': _synced,
      };
      if (rows.isEmpty) {
        await txn.insert(Tables.budgets, values);
        return true;
      }
      final local = rows.first;
      final localAt = local['updated_at']! as int;
      if (_localWins(local, remote.updatedAtMs)) return false;
      if (localAt == remote.updatedAtMs && local['amount_minor'] == amount) {
        await txn.update(
          Tables.budgets,
          {'sync_status': _synced},
          where: 'id = ? AND updated_at = ?',
          whereArgs: [local['id'], localAt],
        );
        return false;
      }
      if (remote.updatedAtMs < localAt) return false;
      await txn.update(
        Tables.budgets,
        values,
        where: 'id = ?',
        whereArgs: [local['id']],
      );
      return true;
    }

    if (data['kind'] != 'category') return false;
    final budgetId = data['budgetId'];
    final categoryId = data['categoryId'];
    final createdAt = data['createdAt'];
    if (budgetId is! String || categoryId is! String || createdAt is! int) {
      return false;
    }
    final tombstone = await _tombstoneAt(
      txn,
      CloudCollections.budgets,
      scope,
      remote.id,
    );
    final rows = await txn.query(
      Tables.categoryBudgets,
      where: 'id = ? AND household_id = ?',
      whereArgs: [budgetId, household],
      limit: 1,
    );
    final local = rows.isEmpty ? null : rows.first;

    if (remote.deleted) {
      if (tombstone != null) {
        await _dropTombstone(txn, CloudCollections.budgets, scope, remote.id);
      }
      if (local == null || _localWins(local, remote.updatedAtMs)) return false;
      await txn.delete(
        Tables.categoryBudgets,
        where: 'id = ?',
        whereArgs: [budgetId],
      );
      return true;
    }
    if (amount <= 0) return false;
    if (tombstone != null && tombstone >= remote.updatedAtMs) return false;
    if (local != null) {
      final localAt = local['updated_at']! as int;
      if (_localWins(local, remote.updatedAtMs)) return false;
      if (localAt == remote.updatedAtMs) {
        await txn.update(
          Tables.categoryBudgets,
          {'sync_status': _synced},
          where: 'id = ? AND updated_at = ?',
          whereArgs: [budgetId, localAt],
        );
        return false;
      }
      if (remote.updatedAtMs < localAt) return false;
    }

    final category = CategorySnapshot.fromCloudMap(data['category']);
    final resolved = await _ensureCategory(
      txn,
      categoryId,
      category,
      scope.householdId,
    );
    if (resolved == null) return false;

    // Another budget for the same category and period: the newer one wins
    // and the other is deleted everywhere.
    final clashes = await txn.query(
      Tables.categoryBudgets,
      where: 'household_id = ? AND category_id = ? AND period = ? AND id != ?',
      whereArgs: [household, resolved, period.name, budgetId],
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final other in clashes) {
      if (_localWins(other, remote.updatedAtMs)) {
        await txn.insert(Tables.cloudTombstones, {
          'collection': CloudCollections.budgets,
          'household_id': household,
          'id': remote.id,
          'deleted_at': now,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        return false;
      }
    }
    for (final other in clashes) {
      await txn.delete(
        Tables.categoryBudgets,
        where: 'id = ?',
        whereArgs: [other['id']],
      );
      await txn.insert(Tables.cloudTombstones, {
        'collection': CloudCollections.budgets,
        'household_id': household,
        'id': 'category_${other['id']}',
        'deleted_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    await txn.insert(Tables.categoryBudgets, {
      'id': budgetId,
      'household_id': household,
      'category_id': resolved,
      'period': period.name,
      'amount_minor': amount,
      'created_at': createdAt,
      'updated_at': remote.updatedAtMs,
      'updated_by': data['updatedBy'] as String?,
      'sync_status': _synced,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (tombstone != null) {
      await _dropTombstone(txn, CloudCollections.budgets, scope, remote.id);
    }
    return true;
  }

  static Future<String?> _ensureCategory(
    DatabaseExecutor db,
    String categoryId,
    CategorySnapshot? snapshot,
    String? householdId,
  ) async {
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
    await db.insert(Tables.categories, {
      ...snapshot.toCategory(sortOrder: 50).toMap(),
      'household_id': householdId,
      'sync_status': _synced,
    });
    return categoryId;
  }

  // ---------------------------------------------------- household labels

  @override
  Future<List<CloudRecord>> householdCategoryUploads(
    DataScope scope,
    Map<String, int> cloudUpdatedAt,
  ) async {
    if (scope.isPersonal) return const [];
    final hid = scope.householdId!;
    final rows = await _db.rawQuery(
      'SELECT * FROM ${Tables.categories} '
      'WHERE (household_id IS NULL OR household_id = ?) AND id IN ('
      "SELECT category_id FROM ${Tables.transactions} WHERE scope = 'shared' "
      'AND household_id = ? '
      'UNION SELECT category_id FROM ${Tables.categoryBudgets} '
      'WHERE household_id = ?)',
      [hid, hid, hid],
    );
    return [
      for (final r in rows)
        if (cloudUpdatedAt[r['id']] == null ||
            (r['updated_at']! as int) > cloudUpdatedAt[r['id']]!)
          _categoryRecord(r),
    ];
  }
}
