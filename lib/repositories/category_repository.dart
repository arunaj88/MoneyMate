import 'package:sqflite/sqflite.dart';

import '../core/database/app_database.dart';
import '../models/category_model.dart';
import '../models/transaction_model.dart';

/// Thrown when a category cannot be deleted because shared household
/// records use it (deleting it would change data other members see).
class CategoryInUseException implements Exception {
  const CategoryInUseException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Cloud collections that keep local deletions in `cloud_tombstones`.
class CloudCollections {
  CloudCollections._();

  static const String budgets = 'budgets';
  static const String categories = 'categories';
}

/// Data access for categories.
abstract class CategoryRepository {
  Future<List<CategoryModel>> getAll();

  Future<void> insert(CategoryModel category);

  Future<void> update(CategoryModel category);

  /// Deletes a custom category. Its transactions are moved to the built-in
  /// "Other" category of the same type so no transaction is lost.
  ///
  /// Throws [CategoryInUseException] when shared household transactions or
  /// budgets use it.
  Future<void> delete(CategoryModel category);

  Future<bool> nameExists(
    String name,
    TransactionType type, {
    String? excludeId,
  });
}

class SqliteCategoryRepository implements CategoryRepository {
  SqliteCategoryRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const _pending = 'pending';

  @override
  Future<List<CategoryModel>> getAll() async {
    final rows = await _db.query(
      Tables.categories,
      orderBy: 'type ASC, sort_order ASC, name COLLATE NOCASE ASC',
    );
    return rows.map(CategoryModel.fromMap).toList();
  }

  /// Every local change is queued for upload (built-ins too, once edited).
  static Map<String, Object?> _changed(CategoryModel category) => {
    ...category.toMap(),
    'updated_at': DateTime.now().millisecondsSinceEpoch,
    'sync_status': _pending,
  };

  @override
  Future<void> insert(CategoryModel category) async {
    await _db.insert(
      Tables.categories,
      _changed(category),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  @override
  Future<void> update(CategoryModel category) async {
    await _db.update(
      Tables.categories,
      _changed(category),
      where: 'id = ?',
      whereArgs: [category.id],
    );
  }

  @override
  Future<void> delete(CategoryModel category) async {
    if (category.isDefault) {
      throw StateError('Built-in categories cannot be deleted');
    }
    await _db.transaction((txn) async {
      final shared = await txn.rawQuery(
        'SELECT '
        "(SELECT COUNT(*) FROM ${Tables.transactions} WHERE category_id = ? AND scope = 'shared') + "
        "(SELECT COUNT(*) FROM ${Tables.categoryBudgets} WHERE category_id = ? AND household_id != '') "
        'AS n',
        [category.id, category.id],
      );
      if (((shared.first['n'] as int?) ?? 0) > 0) {
        throw const CategoryInUseException(
          'Shared household transactions or budgets use this category, so '
          'it cannot be deleted.',
        );
      }
      await deleteWithin(txn, category.id, category.type);
    });
  }

  /// Deletes custom category [id] inside [txn]: its personal transactions
  /// move to "Other", its personal category budgets and the category itself
  /// are recorded as deleted for the cloud. Used by local deletes and by
  /// deletions received from the cloud.
  static Future<void> deleteWithin(
    Transaction txn,
    String id,
    TransactionType type,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await AppDatabase.ensureDefaultCategories(txn);
    // Moving transactions is an edit: bump updated_at so it syncs.
    await txn.update(
      Tables.transactions,
      {
        'category_id': DefaultCategories.otherIdFor(type),
        'updated_at': now,
        'sync_status': RecordSyncStatus.pending.name,
      },
      // Callers make sure no shared transaction uses the category.
      where: "category_id = ? AND scope = 'personal'",
      whereArgs: [id],
    );
    final budgets = await txn.query(
      Tables.categoryBudgets,
      columns: ['id', 'household_id'],
      where: 'category_id = ?',
      whereArgs: [id],
    );
    for (final b in budgets) {
      await txn.insert(Tables.cloudTombstones, {
        'collection': CloudCollections.budgets,
        'household_id': b['household_id'],
        'id': 'category_${b['id']}',
        'deleted_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final origin = await txn.query(
      Tables.categories,
      columns: ['household_id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    // Only personal categories live in the personal cloud collection.
    if (origin.isNotEmpty && origin.first['household_id'] == null) {
      await txn.insert(Tables.cloudTombstones, {
        'collection': CloudCollections.categories,
        'household_id': '',
        'id': id,
        'deleted_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    // Category budgets cascade with the category.
    await txn.delete(Tables.categories, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<bool> nameExists(
    String name,
    TransactionType type, {
    String? excludeId,
  }) async {
    final rows = await _db.query(
      Tables.categories,
      columns: ['id'],
      where:
          'name = ? COLLATE NOCASE AND type = ?'
          '${excludeId != null ? ' AND id != ?' : ''}',
      whereArgs: [name.trim(), type.name, if (excludeId != null) excludeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
