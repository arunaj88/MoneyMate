import 'package:sqflite/sqflite.dart';

import '../core/database/app_database.dart';
import '../core/utils/date_range.dart';
import '../models/report_models.dart';
import '../models/scope_models.dart';
import '../models/transaction_model.dart';
import '../core/services/transaction_calculator.dart';

/// Data access for transactions.
///
/// Every query is limited to a [ScopeFilter] (personal by default), so
/// personal and shared household records are only combined when a caller
/// asks for it explicitly.
abstract class TransactionRepository {
  /// Returns transactions matching [filter], newest first.
  Future<List<TransactionModel>> getTransactions({
    TransactionFilter filter = const TransactionFilter(),
    int? limit,
  });

  Future<TransactionModel?> getById(String id);

  Future<void> insert(TransactionModel transaction);

  /// Saves an edit. When the scope changed (personal ↔ shared) the record
  /// is removed from its old cloud collection and uploaded to the new one.
  Future<void> update(TransactionModel transaction);

  /// Deletes the transaction. [scope] is used for cloud-only records that
  /// are not stored on this device.
  Future<void> delete(String id, {DataScope? scope});

  /// Sum of amounts of [type], optionally limited to [range] / [categoryId].
  Future<int> sumAmount({
    required TransactionType type,
    DateRange? range,
    String? categoryId,
    ScopeFilter scope = const ScopeFilter.personal(),
  });

  /// Income and expense totals for each of [ranges], in one query.
  Future<List<PeriodTotals>> totalsForRanges(
    List<DateRange> ranges, {
    ScopeFilter scope = const ScopeFilter.personal(),
  });

  /// Totals per category for [type] within [range], largest first.
  Future<List<CategoryTotal>> totalsByCategory({
    required TransactionType type,
    required DateRange range,
    ScopeFilter scope = const ScopeFilter.personal(),
  });

  /// Spending of [categoryId] within each of [ranges].
  Future<List<int>> categorySpendForRanges(
    String categoryId,
    List<DateRange> ranges, {
    ScopeFilter scope = const ScopeFilter.personal(),
  });

  /// Per-day totals for [type] within [range] (every day included).
  Future<List<DailyTotal>> dailyTotals({
    required TransactionType type,
    required DateRange range,
    ScopeFilter scope = const ScopeFilter.personal(),
  });

  /// Number of transactions (in any scope) using [categoryId].
  Future<int> countForCategory(String categoryId);

  /// Income and expense totals of cloud transactions that are older than
  /// the local retention window and no longer stored on this device.
  Future<({int income, int expense})> archivedTotals({
    ScopeFilter scope = const ScopeFilter.personal(),
  });
}

class SqliteTransactionRepository implements TransactionRepository {
  SqliteTransactionRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  @override
  Future<List<TransactionModel>> getTransactions({
    TransactionFilter filter = const TransactionFilter(),
    int? limit,
  }) async {
    final scope = filter.scope.sql('t');
    final where = <String>[scope.sql];
    final args = <Object?>[...scope.args];

    if (filter.type != null) {
      where.add('t.type = ?');
      args.add(filter.type!.name);
    }
    if (filter.categoryIds.isNotEmpty) {
      where.add(
        't.category_id IN (${List.filled(filter.categoryIds.length, '?').join(',')})',
      );
      args.addAll(filter.categoryIds);
    }
    if (filter.start != null) {
      where.add('t.date >= ?');
      args.add(filter.start!.millisecondsSinceEpoch);
    }
    if (filter.end != null) {
      where.add('t.date < ?');
      args.add(filter.end!.millisecondsSinceEpoch);
    }
    final query = filter.query.trim();
    if (query.isNotEmpty) {
      final like = '%${_escapeLike(query)}%';
      where.add(
        "(t.note LIKE ? ESCAPE '\\' OR c.name LIKE ? ESCAPE '\\' OR t.payment_method LIKE ? ESCAPE '\\')",
      );
      args.addAll([like, like, like]);
    }

    final sql = StringBuffer(
      'SELECT t.* FROM ${Tables.transactions} t '
      'LEFT JOIN ${Tables.categories} c ON c.id = t.category_id',
    );
    sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(' ORDER BY t.date DESC, t.created_at DESC');
    if (limit != null) {
      sql.write(' LIMIT ?');
      args.add(limit);
    }

    final rows = await _db.rawQuery(sql.toString(), args);
    return rows.map(TransactionModel.fromMap).toList();
  }

  static String _escapeLike(String input) => input
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');

  @override
  Future<TransactionModel?> getById(String id) async {
    final rows = await _db.query(
      Tables.transactions,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : TransactionModel.fromMap(rows.first);
  }

  static DataScope _scopeOf(TransactionModel t) => t.isShared
      ? DataScope.household(t.householdId!)
      : const DataScope.personal();

  /// Stores a new transaction as pending upload. Re-inserting a deleted
  /// transaction (undo) also cancels its pending cloud deletion.
  @override
  Future<void> insert(TransactionModel transaction) async {
    await _db.transaction((txn) async {
      await txn.insert(Tables.transactions, {
        ...transaction.toMap(),
        'sync_status': RecordSyncStatus.pending.name,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      await txn.delete(
        Tables.syncTombstones,
        where: 'id = ? AND household_id = ?',
        whereArgs: [transaction.id, _scopeOf(transaction).storageKey],
      );
      // An archived record edited from cloud history is stored here again.
      await txn.delete(
        Tables.archivedTotals,
        where: 'id = ?',
        whereArgs: [transaction.id],
      );
    });
  }

  @override
  Future<void> update(TransactionModel transaction) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        Tables.transactions,
        columns: ['scope', 'household_id'],
        where: 'id = ?',
        whereArgs: [transaction.id],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Transaction ${transaction.id} no longer exists');
      }
      final oldScope = DataScope.fromStorageKey(
        rows.first['scope'] == TransactionScope.shared.name
            ? rows.first['household_id'] as String?
            : null,
      );
      final newScope = _scopeOf(transaction);
      final moved = oldScope != newScope;
      await txn.update(
        Tables.transactions,
        {
          ...transaction.toMap(),
          'sync_status': RecordSyncStatus.pending.name,
          // The new collection has no verified copy yet.
          if (moved) 'cloud_updated_at': null,
          if (moved) 'synced_at': null,
        },
        where: 'id = ?',
        whereArgs: [transaction.id],
      );
      if (moved) {
        // Mark it deleted in the old collection (never hard-deleted).
        await txn.insert(Tables.syncTombstones, {
          'id': transaction.id,
          'household_id': oldScope.storageKey,
          'deleted_at': transaction.updatedAt.millisecondsSinceEpoch,
          'sync_status': RecordSyncStatus.pending.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.delete(
          Tables.syncTombstones,
          where: 'id = ? AND household_id = ?',
          whereArgs: [transaction.id, newScope.storageKey],
        );
      }
    });
  }

  /// Removes the transaction from this device and records a tombstone so
  /// the deletion is synchronised. Works for cloud-only (archived) records
  /// too. Cloud documents are only marked as deleted, never removed.
  @override
  Future<void> delete(String id, {DataScope? scope}) async {
    await _db.transaction((txn) async {
      final rows = await txn.query(
        Tables.transactions,
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      final owner = rows.isNotEmpty
          ? _scopeOf(TransactionModel.fromMap(rows.first))
          : scope ?? const DataScope.personal();
      await txn.delete(Tables.transactions, where: 'id = ?', whereArgs: [id]);
      await txn.delete(Tables.archivedTotals, where: 'id = ?', whereArgs: [id]);
      await txn.insert(Tables.syncTombstones, {
        'id': id,
        'household_id': owner.storageKey,
        'deleted_at': DateTime.now().millisecondsSinceEpoch,
        'sync_status': RecordSyncStatus.pending.name,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<int> sumAmount({
    required TransactionType type,
    DateRange? range,
    String? categoryId,
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async {
    final scopeSql = scope.sql();
    final where = <String>['type = ?', scopeSql.sql];
    final args = <Object?>[type.name, ...scopeSql.args];
    if (range != null) {
      where.add('date >= ? AND date < ?');
      args.addAll([
        range.start.millisecondsSinceEpoch,
        range.end.millisecondsSinceEpoch,
      ]);
    }
    if (categoryId != null) {
      where.add('category_id = ?');
      args.add(categoryId);
    }
    final rows = await _db.rawQuery(
      'SELECT COALESCE(SUM(amount_minor), 0) AS total '
      'FROM ${Tables.transactions} WHERE ${where.join(' AND ')}',
      args,
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  @override
  Future<List<PeriodTotals>> totalsForRanges(
    List<DateRange> ranges, {
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async {
    if (ranges.isEmpty) return const [];
    final columns = <String>[];
    final args = <Object?>[];
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      for (final type in TransactionType.values) {
        columns.add(
          "COALESCE(SUM(CASE WHEN type = '${type.name}' AND date >= ? AND date < ? "
          'THEN amount_minor END), 0) AS ${type.name}_$i',
        );
        args.addAll([
          r.start.millisecondsSinceEpoch,
          r.end.millisecondsSinceEpoch,
        ]);
      }
    }
    final overall = DateRange(
      ranges.map((r) => r.start).reduce((a, b) => a.isBefore(b) ? a : b),
      ranges.map((r) => r.end).reduce((a, b) => a.isAfter(b) ? a : b),
    );
    final scopeSql = scope.sql();
    args.addAll([
      overall.start.millisecondsSinceEpoch,
      overall.end.millisecondsSinceEpoch,
      ...scopeSql.args,
    ]);
    final rows = await _db.rawQuery(
      'SELECT ${columns.join(', ')} FROM ${Tables.transactions} '
      'WHERE date >= ? AND date < ? AND ${scopeSql.sql}',
      args,
    );
    final row = rows.first;
    return [
      for (var i = 0; i < ranges.length; i++)
        PeriodTotals(
          range: ranges[i],
          incomeMinor: (row['income_$i'] as int?) ?? 0,
          expenseMinor: (row['expense_$i'] as int?) ?? 0,
        ),
    ];
  }

  @override
  Future<List<CategoryTotal>> totalsByCategory({
    required TransactionType type,
    required DateRange range,
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async {
    final scopeSql = scope.sql();
    final rows = await _db.rawQuery(
      'SELECT category_id, SUM(amount_minor) AS total '
      'FROM ${Tables.transactions} '
      'WHERE type = ? AND date >= ? AND date < ? AND ${scopeSql.sql} '
      'GROUP BY category_id ORDER BY total DESC',
      [
        type.name,
        range.start.millisecondsSinceEpoch,
        range.end.millisecondsSinceEpoch,
        ...scopeSql.args,
      ],
    );
    return rows
        .map(
          (r) => CategoryTotal(
            categoryId: r['category_id']! as String,
            totalMinor: (r['total'] as int?) ?? 0,
          ),
        )
        .toList();
  }

  @override
  Future<List<int>> categorySpendForRanges(
    String categoryId,
    List<DateRange> ranges, {
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async {
    if (ranges.isEmpty) return const [];
    final columns = <String>[];
    final args = <Object?>[];
    for (var i = 0; i < ranges.length; i++) {
      columns.add(
        'COALESCE(SUM(CASE WHEN date >= ? AND date < ? '
        'THEN amount_minor END), 0) AS c_$i',
      );
      args.addAll([
        ranges[i].start.millisecondsSinceEpoch,
        ranges[i].end.millisecondsSinceEpoch,
      ]);
    }
    final scopeSql = scope.sql();
    args.addAll([categoryId, TransactionType.expense.name, ...scopeSql.args]);
    final rows = await _db.rawQuery(
      'SELECT ${columns.join(', ')} FROM ${Tables.transactions} '
      'WHERE category_id = ? AND type = ? AND ${scopeSql.sql}',
      args,
    );
    final row = rows.first;
    return [for (var i = 0; i < ranges.length; i++) (row['c_$i'] as int?) ?? 0];
  }

  @override
  Future<List<DailyTotal>> dailyTotals({
    required TransactionType type,
    required DateRange range,
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async {
    final scopeSql = scope.sql();
    final rows = await _db.query(
      Tables.transactions,
      columns: ['date', 'amount_minor'],
      where: 'type = ? AND date >= ? AND date < ? AND ${scopeSql.sql}',
      whereArgs: [
        type.name,
        range.start.millisecondsSinceEpoch,
        range.end.millisecondsSinceEpoch,
        ...scopeSql.args,
      ],
    );
    final entries = rows.map(
      (r) => (
        date: DateTime.fromMillisecondsSinceEpoch(r['date']! as int),
        amountMinor: r['amount_minor']! as int,
      ),
    );
    return TransactionCalculator.dailyTotalsFromEntries(entries, range);
  }

  @override
  Future<({int income, int expense})> archivedTotals({
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async {
    final parts = <String>[
      if (scope.includePersonal) "household_id = ''",
      if (scope.householdId != null) 'household_id = ?',
    ];
    final rows = await _db.rawQuery(
      'SELECT '
      "COALESCE(SUM(CASE WHEN type = 'income' THEN amount_minor END), 0) AS i, "
      "COALESCE(SUM(CASE WHEN type = 'expense' THEN amount_minor END), 0) AS e "
      'FROM ${Tables.archivedTotals} WHERE ${parts.join(' OR ')}',
      [if (scope.householdId != null) scope.householdId],
    );
    return (
      income: (rows.first['i'] as int?) ?? 0,
      expense: (rows.first['e'] as int?) ?? 0,
    );
  }

  @override
  Future<int> countForCategory(String categoryId) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS n FROM ${Tables.transactions} WHERE category_id = ?',
      [categoryId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }
}
