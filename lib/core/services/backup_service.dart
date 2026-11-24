import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';

import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/utils/money.dart';

/// Thrown when a backup file cannot be restored.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Parsed and validated contents of a backup file.
class BackupContents {
  const BackupContents({
    required this.exportedAt,
    required this.categories,
    required this.transactions,
    required this.budgetTargets,
    required this.categoryBudgets,
    required this.settings,
    this.recurringRules = const [],
    this.savingsGoals = const [],
    this.savingsEntries = const [],
  });

  final DateTime? exportedAt;
  final List<CategoryModel> categories;
  final List<TransactionModel> transactions;
  final List<BudgetTarget> budgetTargets;
  final List<CategoryBudget> categoryBudgets;
  final Map<String, dynamic> settings;

  /// Personal recurring rules (absent from backups made before they
  /// existed).
  final List<RecurringRule> recurringRules;

  /// Savings goals and their history (absent from older backups).
  final List<SavingsGoal> savingsGoals;
  final List<SavingsEntry> savingsEntries;
}

/// Creates and restores JSON backups and exports CSV files.
abstract class BackupService {
  /// Serialises the user's personal data to a JSON document. Shared
  /// household records belong to the household and are not included.
  Future<String> createBackupJson({Map<String, Object>? settings});

  /// Exports the transactions stored on this device as CSV (newest first),
  /// with their scope and, for shared ones, who added them.
  Future<String> createTransactionsCsv({required String currencyCode});

  /// Replaces the personal data stored on this device with [contents]
  /// atomically. Shared household data is left untouched, and everything
  /// restored is personal.
  Future<void> restore(BackupContents contents);

  static String backupFileName(DateTime now) =>
      'moneymate_backup_${DateFormat('yyyyMMdd_HHmmss').format(now)}.json';

  static String csvFileName(DateTime now) =>
      'moneymate_transactions_${DateFormat('yyyyMMdd_HHmmss').format(now)}.csv';

  /// Escapes values per RFC 4180 and guards against spreadsheet formula
  /// injection for text cells.
  static String buildCsvRow(List<String> values) {
    return values
        .map((value) {
          var v = value;
          if (v.isNotEmpty && '=+@'.contains(v[0])) v = "'$v";
          final needsQuotes = v.contains(RegExp(r'[",\r\n]'));
          v = v.replaceAll('"', '""');
          return needsQuotes ? '"$v"' : v;
        })
        .join(',');
  }

  /// Parses and validates a backup without changing any data.
  static BackupContents parse(String jsonText) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      throw const BackupFormatException('The file is not valid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const BackupFormatException('Unexpected backup structure.');
    }
    final appId = decoded['app'];
    if (appId != AppConstants.backupAppId &&
        !AppConstants.legacyBackupAppIds.contains(appId)) {
      throw const BackupFormatException('This file is not a MoneyMate backup.');
    }
    final version = decoded['schemaVersion'];
    if (version is! int || version < 1) {
      throw const BackupFormatException('Missing backup version.');
    }
    if (version > AppConstants.backupSchemaVersion) {
      throw const BackupFormatException(
        'This backup was made by a newer version of MoneyMate. '
        'Please update the app first.',
      );
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw const BackupFormatException('Backup data section is missing.');
    }

    List<T> parseList<T>(String key, T Function(Map<String, dynamic>) parse) {
      final raw = data[key];
      if (raw == null) return <T>[];
      if (raw is! List) {
        throw BackupFormatException('"$key" must be a list.');
      }
      final result = <T>[];
      for (var i = 0; i < raw.length; i++) {
        final item = raw[i];
        if (item is! Map<String, dynamic>) {
          throw BackupFormatException('Invalid entry #${i + 1} in "$key".');
        }
        try {
          result.add(parse(item));
        } catch (_) {
          throw BackupFormatException('Invalid entry #${i + 1} in "$key".');
        }
      }
      return result;
    }

    if (data['transactions'] is! List || data['categories'] is! List) {
      throw const BackupFormatException(
        'Backup must contain categories and transactions.',
      );
    }

    final categories = parseList('categories', CategoryModel.fromJson);
    final transactions = parseList('transactions', (m) {
      final t = TransactionModel.fromJson(m);
      if (t.amountMinor <= 0) throw const FormatException('amount');
      return t;
    });
    final budgets = parseList('budgets', (m) {
      final b = BudgetTarget.fromJson(m);
      if (b.amountMinor < 0) throw const FormatException('amount');
      return b;
    });
    final categoryBudgets = parseList('categoryBudgets', (m) {
      final b = CategoryBudget.fromJson(m);
      if (b.amountMinor <= 0) throw const FormatException('amount');
      return b;
    });

    final recurringRules = parseList('recurringRules', (m) {
      final r = RecurringRule.fromJson(m);
      if (r.isShared) throw const FormatException('scope');
      return r;
    });

    // Referential integrity: every transaction / category budget must point
    // at a category in the backup or a built-in category.
    final knownIds = {
      ...categories.map((c) => c.id),
      ...DefaultCategories.all.map((c) => c.id),
    };
    final ids = <String>{};
    for (final t in transactions) {
      if (!knownIds.contains(t.categoryId)) {
        throw BackupFormatException(
          'A transaction references an unknown category (${t.categoryId}).',
        );
      }
      if (!ids.add(t.id)) {
        throw BackupFormatException('Duplicate transaction id ${t.id}.');
      }
    }
    for (final b in categoryBudgets) {
      if (!knownIds.contains(b.categoryId)) {
        throw const BackupFormatException(
          'A category budget references an unknown category.',
        );
      }
    }
    for (final r in recurringRules) {
      if (!knownIds.contains(r.categoryId)) {
        throw const BackupFormatException(
          'A recurring transaction references an unknown category.',
        );
      }
    }

    final savingsGoals = parseList('savingsGoals', SavingsGoal.fromJson);
    final savingsEntries = parseList('savingsEntries', SavingsEntry.fromJson);
    final goalIds = {for (final g in savingsGoals) g.id};
    if (goalIds.length != savingsGoals.length) {
      throw const BackupFormatException('Duplicate savings goal id.');
    }
    final balances = <String, int>{};
    for (final e in savingsEntries) {
      if (!goalIds.contains(e.goalId)) {
        throw const BackupFormatException(
          'A savings entry references an unknown goal.',
        );
      }
      balances[e.goalId] = (balances[e.goalId] ?? 0) + e.signedMinor;
    }
    if (balances.values.any((b) => b < 0)) {
      throw const BackupFormatException(
        'A savings goal has more withdrawn than saved.',
      );
    }

    final settings = data['settings'];
    return BackupContents(
      exportedAt: DateTime.tryParse(decoded['exportedAt']?.toString() ?? ''),
      categories: categories,
      transactions: transactions,
      budgetTargets: budgets,
      categoryBudgets: categoryBudgets,
      settings: settings is Map<String, dynamic> ? settings : const {},
      recurringRules: recurringRules,
      savingsGoals: savingsGoals,
      savingsEntries: savingsEntries,
    );
  }
}

class SqliteBackupService implements BackupService {
  SqliteBackupService(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  // ----------------------------------------------------------------- export

  @override
  Future<String> createBackupJson({Map<String, Object>? settings}) async {
    final categories = await _db.query(Tables.categories);
    final transactions = await _db.query(
      Tables.transactions,
      where: "scope = 'personal'",
      orderBy: 'date ASC',
    );
    final budgets = await _db.query(
      Tables.budgets,
      where: "household_id = ''",
      orderBy: 'period, effective_from',
    );
    final categoryBudgets = await _db.query(
      Tables.categoryBudgets,
      where: "household_id = ''",
    );
    final recurringRules = await _db.query(
      Tables.recurringRules,
      where: "household_id = ''",
      orderBy: 'created_at',
    );
    // Personal goals only: household and shared goals belong to other
    // people too and live in the cloud.
    final savingsGoals = await _db.query(
      Tables.savingsGoals,
      where: "ownership = 'personal'",
      orderBy: 'created_at',
    );
    final savingsEntries = await _db.query(
      Tables.savingsEntries,
      where:
          'goal_id IN (SELECT id FROM ${Tables.savingsGoals} '
          "WHERE ownership = 'personal')",
      orderBy: 'date, created_at',
    );

    final document = {
      'app': AppConstants.backupAppId,
      'schemaVersion': AppConstants.backupSchemaVersion,
      'appVersion': AppConstants.appVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'data': {
        // Sync bookkeeping columns are not part of the backup format.
        'categories': categories
            .map((c) => CategoryModel.fromMap(c).toJson())
            .toList(growable: false),
        // Sync bookkeeping columns are not part of the backup format.
        'transactions': transactions
            .map((t) => TransactionModel.fromMap(t).toJson())
            .toList(growable: false),
        'budgets': budgets
            .map((b) => BudgetTarget.fromMap(b).toJson())
            .toList(growable: false),
        'categoryBudgets': categoryBudgets
            .map((b) => CategoryBudget.fromMap(b).toJson())
            .toList(growable: false),
        'recurringRules': recurringRules
            .map((r) => RecurringRule.fromMap(r).toJson())
            .toList(growable: false),
        'savingsGoals': savingsGoals
            .map((g) => SavingsGoal.fromMap(g).toJson())
            .toList(growable: false),
        'savingsEntries': savingsEntries
            .map((e) => SavingsEntry.fromMap(e).toJson())
            .toList(growable: false),
        'settings': settings ?? const <String, Object>{},
      },
    };
    return const JsonEncoder.withIndent('  ').convert(document);
  }

  @override
  Future<String> createTransactionsCsv({required String currencyCode}) async {
    final rows = await _db.rawQuery(
      'SELECT t.*, c.name AS category_name FROM ${Tables.transactions} t '
      'LEFT JOIN ${Tables.categories} c ON c.id = t.category_id '
      'ORDER BY t.date DESC, t.created_at DESC',
    );
    final dateFormat = DateFormat('yyyy-MM-dd');
    final buffer = StringBuffer()
      ..writeln(
        BackupService.buildCsvRow([
          'Date',
          'Type',
          'Category',
          'Amount',
          'Currency',
          'Payment Method',
          'Note',
          'Scope',
          'Added By',
        ]),
      );
    for (final r in rows) {
      final t = TransactionModel.fromMap(r);
      buffer.writeln(
        BackupService.buildCsvRow([
          dateFormat.format(t.date),
          t.type.label,
          (r['category_name'] as String?) ?? 'Unknown',
          '${t.isExpense ? '-' : ''}${Money.toInputString(t.amountMinor)}',
          currencyCode,
          t.paymentMethod.label,
          t.note,
          t.isShared ? 'Shared' : 'Personal',
          t.isShared ? (t.createdByName ?? '') : '',
        ]),
      );
    }
    return buffer.toString();
  }

  /// Runs in a single database transaction: if anything fails, the
  /// existing data is left untouched.
  @override
  Future<void> restore(BackupContents contents) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.transaction((txn) async {
      // Only personal data is replaced; shared household records stay.
      await txn.delete(Tables.categoryBudgets, where: "household_id = ''");
      await txn.delete(Tables.budgets, where: "household_id = ''");
      await txn.delete(Tables.transactions, where: "scope = 'personal'");
      await txn.delete(Tables.recurringRules, where: "household_id = ''");
      // Savings are replaced too. Goals left out of the backup are deleted
      // everywhere; restored ones are uploaded again (same IDs, so no
      // duplicates in the cloud).
      final restoredGoals = {for (final g in contents.savingsGoals) g.id};
      final restoredEntries = {for (final e in contents.savingsEntries) e.id};
      const personalGoals =
          "SELECT id FROM ${Tables.savingsGoals} WHERE ownership = 'personal'";
      for (final (table, collection, keep, where) in [
        (
          Tables.savingsEntries,
          'savingsEntries',
          restoredEntries,
          'goal_id IN ($personalGoals)',
        ),
        (
          Tables.savingsGoals,
          'savingsGoals',
          restoredGoals,
          "ownership = 'personal'",
        ),
      ]) {
        final rows = await txn.query(table, columns: ['id'], where: where);
        for (final row in rows) {
          final id = row['id']! as String;
          if (keep.contains(id)) continue;
          await txn.insert(Tables.cloudTombstones, {
            'collection': collection,
            'household_id': '',
            'id': id,
            'deleted_at': now,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await txn.delete(table, where: where);
      }
      // Categories still used by shared records are kept.
      await txn.rawDelete(
        'DELETE FROM ${Tables.categories} WHERE '
        'id NOT IN (SELECT category_id FROM ${Tables.transactions}) AND '
        'id NOT IN (SELECT category_id FROM ${Tables.categoryBudgets}) AND '
        'id NOT IN (SELECT category_id FROM ${Tables.recurringRules})',
      );
      await txn.delete(
        Tables.appSettings,
        where: 'key LIKE ? AND key NOT LIKE ?',
        whereArgs: ['alert.%', 'alert.h.%'],
      );
      await AppDatabase.ensureDefaultCategories(txn);

      // Backup category ID -> local category ID.
      final idMap = <String, String>{};
      for (final c in contents.categories) {
        final byId = await txn.query(
          Tables.categories,
          columns: ['id', 'household_id'],
          where: 'id = ?',
          whereArgs: [c.id],
          limit: 1,
        );
        if (byId.isNotEmpty) {
          idMap[c.id] = c.id;
          if (byId.first['household_id'] == null) {
            await txn.update(
              Tables.categories,
              {
                ...c.toMap(),
                'updated_at': now,
                'sync_status': RecordSyncStatus.pending.name,
              },
              where: 'id = ?',
              whereArgs: [c.id],
            );
          }
          continue;
        }
        final byName = await txn.query(
          Tables.categories,
          columns: ['id'],
          where: 'name = ? COLLATE NOCASE AND type = ?',
          whereArgs: [c.name, c.type.name],
          limit: 1,
        );
        if (byName.isNotEmpty) {
          idMap[c.id] = byName.first['id']! as String;
          continue;
        }
        await txn.insert(Tables.categories, {
          ...c.toMap(),
          'updated_at': c.isDefault ? 0 : now,
          'sync_status': RecordSyncStatus.pending.name,
        });
        idMap[c.id] = c.id;
      }

      final dataBatch = txn.batch();
      for (final t in contents.transactions) {
        // Restored rows are personal, uploaded again and reconciled by
        // updatedAt.
        final row = t.toMap()
          ..['category_id'] = idMap[t.categoryId] ?? t.categoryId
          ..['scope'] = 'personal'
          ..['household_id'] = null;
        dataBatch.insert(
          Tables.transactions,
          row,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        dataBatch.delete(
          Tables.syncTombstones,
          where: "id = ? AND household_id = ''",
          whereArgs: [t.id],
        );
        dataBatch.delete(
          Tables.archivedTotals,
          where: 'id = ?',
          whereArgs: [t.id],
        );
      }
      for (final b in contents.budgetTargets) {
        dataBatch.insert(Tables.budgets, {
          ...b.toMap(),
          'household_id': '',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final b in contents.categoryBudgets) {
        dataBatch.insert(Tables.categoryBudgets, {
          ...b.toMap(),
          'household_id': '',
          'category_id': idMap[b.categoryId] ?? b.categoryId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final r in contents.recurringRules) {
        // Occurrence IDs are stable, so ones already restored above (or
        // deleted on this device) are not added again when the rule runs.
        dataBatch.insert(Tables.recurringRules, {
          ...r.toMap(),
          'category_id': idMap[r.categoryId] ?? r.categoryId,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final g in contents.savingsGoals) {
        // A newer change time, so the restored version wins everywhere.
        dataBatch.insert(Tables.savingsGoals, {
          ...g.toMap(),
          'updated_at': now,
          'sync_status': RecordSyncStatus.pending.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        dataBatch.delete(
          Tables.cloudTombstones,
          where: "collection = 'savingsGoals' AND household_id = '' AND id = ?",
          whereArgs: [g.id],
        );
      }
      for (final e in contents.savingsEntries) {
        dataBatch.insert(Tables.savingsEntries, {
          ...e.toMap(),
          'updated_at': now,
          'sync_status': RecordSyncStatus.pending.name,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        dataBatch.delete(
          Tables.cloudTombstones,
          where:
              "collection = 'savingsEntries' AND household_id = '' AND id = ?",
          whereArgs: [e.id],
        );
      }
      await dataBatch.commit(noResult: true);
    });
  }
}
