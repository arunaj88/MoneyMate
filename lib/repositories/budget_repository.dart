import 'package:sqflite/sqflite.dart';

import '../core/database/app_database.dart';
import '../models/budget_model.dart';
import '../models/scope_models.dart';
import 'category_repository.dart';

/// Data access for overall budget targets and category budgets.
///
/// Personal and shared household budgets are stored side by side and kept
/// apart by [DataScope]; every method works on one scope only. Each change
/// is queued for cloud sync.
abstract class BudgetRepository {
  /// All versions of the target for [period], oldest first.
  Future<List<BudgetTarget>> getTargetVersions(
    BudgetPeriod period, {
    DataScope scope = const DataScope.personal(),
  });

  /// Sets the target for [period] starting from [effectiveFrom] (the start
  /// of the current period). Earlier versions are kept for history.
  /// An [amountMinor] of 0 removes the target from that period onwards.
  Future<void> setTarget({
    required BudgetPeriod period,
    required int amountMinor,
    required DateTime effectiveFrom,
    DataScope scope = const DataScope.personal(),
    String? updatedBy,
  });

  Future<List<CategoryBudget>> getCategoryBudgets({
    DataScope scope = const DataScope.personal(),
  });

  /// Inserts or replaces the budget for a category/period pair in the
  /// budget's own scope.
  Future<void> upsertCategoryBudget(CategoryBudget budget);

  Future<void> deleteCategoryBudget(String id);
}

class SqliteBudgetRepository implements BudgetRepository {
  SqliteBudgetRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const _pending = 'pending';

  @override
  Future<List<BudgetTarget>> getTargetVersions(
    BudgetPeriod period, {
    DataScope scope = const DataScope.personal(),
  }) async {
    final rows = await _db.query(
      Tables.budgets,
      where: 'period = ? AND household_id = ?',
      whereArgs: [period.name, scope.storageKey],
      orderBy: 'effective_from ASC',
    );
    return rows.map(BudgetTarget.fromMap).toList();
  }

  @override
  Future<void> setTarget({
    required BudgetPeriod period,
    required int amountMinor,
    required DateTime effectiveFrom,
    DataScope scope = const DataScope.personal(),
    String? updatedBy,
  }) async {
    if (amountMinor < 0) {
      throw ArgumentError.value(amountMinor, 'amountMinor', 'must be >= 0');
    }
    await _db.insert(
      Tables.budgets,
      {
        ...BudgetTarget(
          period: period,
          amountMinor: amountMinor,
          effectiveFrom: effectiveFrom,
          updatedAt: DateTime.now(),
          householdId: scope.householdId,
          updatedBy: updatedBy,
        ).toMap(),
        'sync_status': _pending,
      },
      // Changing the target twice in the same period replaces that period's
      // version; older periods keep their own versions.
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<CategoryBudget>> getCategoryBudgets({
    DataScope scope = const DataScope.personal(),
  }) async {
    final rows = await _db.query(
      Tables.categoryBudgets,
      where: 'household_id = ?',
      whereArgs: [scope.storageKey],
      orderBy: 'created_at ASC',
    );
    return rows.map(CategoryBudget.fromMap).toList();
  }

  @override
  Future<void> upsertCategoryBudget(CategoryBudget budget) async {
    await _db.transaction((txn) async {
      final household = budget.householdId ?? '';
      // Respect UNIQUE(household_id, category_id, period): an existing
      // budget for the same pair is replaced (and deleted in the cloud).
      final replaced = await txn.query(
        Tables.categoryBudgets,
        columns: ['id'],
        where:
            'household_id = ? AND category_id = ? AND period = ? AND id != ?',
        whereArgs: [
          household,
          budget.categoryId,
          budget.period.name,
          budget.id,
        ],
      );
      for (final r in replaced) {
        await _deleteWithin(txn, r['id']! as String, household);
      }
      await txn.insert(Tables.categoryBudgets, {
        ...budget.toMap(),
        'sync_status': _pending,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.delete(
        Tables.cloudTombstones,
        where: 'collection = ? AND household_id = ? AND id = ?',
        whereArgs: [CloudCollections.budgets, household, budget.cloudId],
      );
    });
  }

  @override
  Future<void> deleteCategoryBudget(String id) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        Tables.categoryBudgets,
        columns: ['household_id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      await _deleteWithin(txn, id, rows.first['household_id']! as String);
    });
  }

  static Future<void> _deleteWithin(
    Transaction txn,
    String id,
    String household,
  ) async {
    await txn.delete(Tables.categoryBudgets, where: 'id = ?', whereArgs: [id]);
    await txn.insert(Tables.cloudTombstones, {
      'collection': CloudCollections.budgets,
      'household_id': household,
      'id': 'category_$id',
      'deleted_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
