import 'package:sqflite/sqflite.dart';

import '../core/database/app_database.dart';
import '../core/services/recurring_scheduler.dart';
import '../models/category_model.dart';
import '../models/recurring_model.dart';

/// Storage of recurring transaction rules.
///
/// Rules live on the device that created them. The transactions they create
/// are ordinary transactions, so they sync (and reach household members)
/// like any other.
abstract class RecurringRepository {
  /// Every stored rule, soonest next occurrence first.
  Future<List<RecurringRule>> getRules();

  Future<void> insert(RecurringRule rule);

  /// Stops [id] repeating. Transactions it already added are kept.
  Future<void> delete(String id);

  /// Stores [due]'s transactions and advances its rule to
  /// [DueOccurrences.nextIndex], atomically. A transaction whose ID already
  /// exists (or was deleted on this device) is not added again. Returns
  /// how many transactions were added.
  Future<int> commit(DueOccurrences due);
}

class SqliteRecurringRepository implements RecurringRepository {
  SqliteRecurringRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  @override
  Future<List<RecurringRule>> getRules() async {
    final rows = await _db.query(
      Tables.recurringRules,
      orderBy: 'created_at ASC',
    );
    final rules = <RecurringRule>[];
    for (final r in rows) {
      try {
        rules.add(RecurringRule.fromMap(r));
      } on FormatException {
        // A malformed row is skipped rather than hiding every rule.
      }
    }
    rules.sort((a, b) => a.nextDate.compareTo(b.nextDate));
    return rules;
  }

  @override
  Future<void> insert(RecurringRule rule) =>
      _db.insert(Tables.recurringRules, rule.toMap());

  @override
  Future<void> delete(String id) =>
      _db.delete(Tables.recurringRules, where: 'id = ?', whereArgs: [id]);

  @override
  Future<int> commit(DueOccurrences due) {
    return _db.transaction((txn) async {
      final rule = due.rule;
      // Stopped meanwhile, or already advanced by another run: do nothing.
      final current = await txn.query(
        Tables.recurringRules,
        columns: ['next_index'],
        where: 'id = ?',
        whereArgs: [rule.id],
        limit: 1,
      );
      if (current.isEmpty || current.first['next_index'] != rule.nextIndex) {
        return 0;
      }

      // The rule's category may have been deleted since: use "Other".
      final category = await txn.query(
        Tables.categories,
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [rule.categoryId],
        limit: 1,
      );
      final categoryId = category.isNotEmpty
          ? rule.categoryId
          : DefaultCategories.otherIdFor(rule.type);
      if (category.isEmpty) await AppDatabase.ensureDefaultCategories(txn);

      var added = 0;
      for (final t in due.transactions) {
        final known = await txn.rawQuery(
          'SELECT 1 FROM ${Tables.transactions} WHERE id = ? '
          'UNION ALL SELECT 1 FROM ${Tables.syncTombstones} WHERE id = ? '
          'LIMIT 1',
          [t.id, t.id],
        );
        if (known.isNotEmpty) continue;
        await txn.insert(Tables.transactions, {
          ...t.toMap(),
          'category_id': categoryId,
          'sync_status': RecordSyncStatus.pending.name,
        });
        added++;
      }
      await txn.update(
        Tables.recurringRules,
        {
          'next_index': due.nextIndex,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
          if (category.isEmpty) 'category_id': categoryId,
        },
        where: 'id = ?',
        whereArgs: [rule.id],
      );
      return added;
    });
  }
}
