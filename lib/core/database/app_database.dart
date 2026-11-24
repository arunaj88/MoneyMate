import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../models/category_model.dart';
import '../constants/app_constants.dart';

/// Table and column names, kept in one place to avoid typos in queries.
class Tables {
  Tables._();

  static const String transactions = 'transactions';
  static const String categories = 'categories';
  static const String budgets = 'budgets';
  static const String categoryBudgets = 'category_budgets';
  static const String appSettings = 'app_settings';

  /// Local transaction deletions waiting to be marked as deleted in the
  /// cloud, per data scope (`household_id` '' = personal).
  static const String syncTombstones = 'sync_tombstones';

  /// Local deletions of budgets and categories waiting to reach the cloud.
  static const String cloudTombstones = 'cloud_tombstones';

  /// Amount and type (only) of transactions that exist in the cloud but
  /// not on this device because they are older than the retention window,
  /// so all-time balances stay correct after the local clean-up.
  static const String archivedTotals = 'archived_totals';

  /// Recurring transaction rules (e.g. a monthly salary), kept on the
  /// device that created them.
  static const String recurringRules = 'recurring_rules';
}

/// Cloud sync state of a local row (`transactions.sync_status`).
enum RecordSyncStatus {
  /// Created or changed locally and not yet confirmed in the cloud.
  pending,

  /// Uploaded and verified: the cloud copy matches `updated_at`.
  synced,

  /// The last upload attempt failed; it is retried on the next sync.
  failed;

  static RecordSyncStatus fromName(String? value) =>
      RecordSyncStatus.values.firstWhere(
        (s) => s.name == value,
        orElse: () => RecordSyncStatus.pending,
      );
}

/// Owns the SQLite connection, schema creation and migrations.
class AppDatabase {
  AppDatabase._(this._db);

  final Database _db;

  Database get db => _db;

  /// Opens the on-device database, creating or migrating it as needed.
  static Future<AppDatabase> open({DatabaseFactory? factory}) async {
    final dbFactory = factory ?? databaseFactory;
    final dir = await dbFactory.getDatabasesPath();
    final path = p.join(dir, AppConstants.databaseName);
    return _openAt(dbFactory, path);
  }

  /// Opens an in-memory database (used by tests).
  static Future<AppDatabase> openInMemory(DatabaseFactory factory) =>
      _openAt(factory, inMemoryDatabasePath);

  /// Opens the database at [path] with an explicit schema [version], so
  /// tests can create an old schema and then upgrade it.
  @visibleForTesting
  static Future<AppDatabase> openAtPath(
    DatabaseFactory factory,
    String path, {
    int version = AppConstants.databaseVersion,
  }) => _openAt(factory, path, version: version);

  static Future<AppDatabase> _openAt(
    DatabaseFactory factory,
    String path, {
    int version = AppConstants.databaseVersion,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await _createSchemaV1(db);
          await _seedDefaults(db);
          // Apply any later migrations for fresh installs too.
          for (var v = 2; v <= version; v++) {
            await _migrations[v]?.call(db);
          }
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          for (var v = oldVersion + 1; v <= newVersion; v++) {
            await _migrations[v]?.call(db);
          }
        },
      ),
    );
    return AppDatabase._(db);
  }

  /// Incremental migrations keyed by the version they upgrade *to*.
  ///
  /// Add new entries here (and bump [AppConstants.databaseVersion]) when the
  /// schema changes. Never edit an existing migration: user data from older
  /// app versions is preserved by running every step in order.
  static final Map<int, Future<void> Function(Database db)> _migrations = {
    2: _migrateToV2,
    3: _migrateToV3,
    4: _migrateToV4,
  };

  /// v4: recurring transaction rules. Adds a table only; no existing row
  /// changes.
  ///
  /// There is no foreign key on `category_id`: deleting a category moves
  /// its rules to "Other" (see `SqliteCategoryRepository.deleteWithin`),
  /// and a rule whose category has gone uses "Other" when it runs.
  static Future<void> _migrateToV4(Database db) async {
    await db.execute('''
      CREATE TABLE ${Tables.recurringRules} (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        category_id TEXT NOT NULL,
        frequency TEXT NOT NULL
          CHECK (frequency IN ('weekly', 'monthly', 'yearly')),
        start_date INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        payment_method TEXT NOT NULL DEFAULT 'cash',
        scope TEXT NOT NULL DEFAULT 'personal'
          CHECK (scope IN ('personal', 'shared')),
        household_id TEXT NOT NULL DEFAULT '',
        next_index INTEGER NOT NULL DEFAULT 0 CHECK (next_index >= 0),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_by TEXT,
        created_by_name TEXT
      )
    ''');
  }

  /// v2: cloud sync state for transactions and a tombstone table for local
  /// deletions.
  ///
  /// Every existing transaction starts as `pending`, so it is uploaded (and
  /// verified) before the 90-day local retention clean-up may ever remove
  /// it. No existing row is changed or deleted by this migration.
  static Future<void> _migrateToV2(Database db) async {
    final batch = db.batch();
    batch.execute(
      "ALTER TABLE ${Tables.transactions} ADD COLUMN sync_status TEXT "
      "NOT NULL DEFAULT 'pending' "
      "CHECK (sync_status IN ('pending', 'synced', 'failed'))",
    );
    // `updated_at` of the version confirmed in the cloud, or NULL.
    batch.execute(
      'ALTER TABLE ${Tables.transactions} ADD COLUMN cloud_updated_at INTEGER',
    );
    batch.execute(
      'ALTER TABLE ${Tables.transactions} ADD COLUMN synced_at INTEGER',
    );
    batch.execute(
      'ALTER TABLE ${Tables.transactions} ADD COLUMN sync_error TEXT',
    );
    batch.execute(
      'CREATE INDEX idx_transactions_sync '
      'ON ${Tables.transactions}(sync_status, date)',
    );
    batch.execute('''
      CREATE TABLE ${Tables.syncTombstones} (
        id TEXT PRIMARY KEY,
        deleted_at INTEGER NOT NULL,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'failed')),
        sync_error TEXT
      )
    ''');
    await batch.commit(noResult: true);
  }

  /// v3: personal and shared household data.
  ///
  /// * Transactions get a scope ('personal' / 'shared'), the household of
  ///   shared ones and who created / last changed them. Every existing
  ///   transaction becomes personal; nothing is shared automatically.
  /// * Tombstones are kept per data scope.
  /// * Budgets and category budgets are rebuilt with a `household_id`
  ///   ('' = personal) in their UNIQUE constraints and a sync status; all
  ///   existing rows are kept, as personal, and queued for upload to the
  ///   user's personal cloud collections.
  /// * Categories get a sync status; existing custom categories are queued
  ///   for upload. `household_id` marks categories that came from a
  ///   household, so they are never uploaded to the personal collection.
  /// * `archived_totals` records the amount of every cloud transaction that
  ///   is older than the retention window and not on this device. The
  ///   personal pull cursor is reset once so transactions archived by v2
  ///   are counted (already stored rows are only confirmed, not changed).
  static Future<void> _migrateToV3(Database db) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();

    // ------------------------------------------------------- transactions
    batch.execute(
      'ALTER TABLE ${Tables.transactions} ADD COLUMN scope TEXT NOT NULL '
      "DEFAULT 'personal' CHECK (scope IN ('personal', 'shared'))",
    );
    for (final column in [
      'household_id',
      'created_by',
      'created_by_name',
      'updated_by',
    ]) {
      batch.execute(
        'ALTER TABLE ${Tables.transactions} ADD COLUMN $column TEXT',
      );
    }
    batch.execute(
      'CREATE INDEX idx_transactions_scope '
      'ON ${Tables.transactions}(scope, household_id, date)',
    );

    // --------------------------------------------------------- tombstones
    batch.execute(
      'ALTER TABLE ${Tables.syncTombstones} RENAME TO sync_tombstones_v2',
    );
    batch.execute('''
      CREATE TABLE ${Tables.syncTombstones} (
        id TEXT NOT NULL,
        household_id TEXT NOT NULL DEFAULT '',
        deleted_at INTEGER NOT NULL,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'failed')),
        sync_error TEXT,
        PRIMARY KEY (id, household_id)
      )
    ''');
    batch.execute(
      'INSERT INTO ${Tables.syncTombstones} '
      '(id, household_id, deleted_at, sync_status, sync_error) '
      "SELECT id, '', deleted_at, sync_status, sync_error "
      'FROM sync_tombstones_v2',
    );
    batch.execute('DROP TABLE sync_tombstones_v2');

    batch.execute('''
      CREATE TABLE ${Tables.archivedTotals} (
        id TEXT PRIMARY KEY,
        household_id TEXT NOT NULL DEFAULT '',
        type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0)
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_archived_totals_scope '
      'ON ${Tables.archivedTotals}(household_id, type)',
    );
    batch.delete(
      Tables.appSettings,
      where: 'key IN (?, ?)',
      whereArgs: ['sync.pull_cursor_micros', 'sync.pull_cursor_doc_id'],
    );

    batch.execute('''
      CREATE TABLE ${Tables.cloudTombstones} (
        collection TEXT NOT NULL,
        household_id TEXT NOT NULL DEFAULT '',
        id TEXT NOT NULL,
        deleted_at INTEGER NOT NULL,
        PRIMARY KEY (collection, household_id, id)
      )
    ''');

    // --------------------------------------------------------- categories
    batch.execute(
      'ALTER TABLE ${Tables.categories} ADD COLUMN household_id TEXT',
    );
    batch.execute(
      'ALTER TABLE ${Tables.categories} ADD COLUMN updated_at INTEGER '
      'NOT NULL DEFAULT 0',
    );
    batch.execute(
      'ALTER TABLE ${Tables.categories} ADD COLUMN sync_status TEXT '
      "NOT NULL DEFAULT 'pending' CHECK (sync_status IN ('pending', 'synced'))",
    );
    // Custom categories are uploaded; untouched built-ins (updated_at 0)
    // exist on every device and are never uploaded.
    batch.rawUpdate(
      'UPDATE ${Tables.categories} SET updated_at = ? WHERE is_default = 0',
      [now],
    );

    // ------------------------------------------------------------ budgets
    batch.execute('ALTER TABLE ${Tables.budgets} RENAME TO budgets_v2');
    batch.execute('''
      CREATE TABLE ${Tables.budgets} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        household_id TEXT NOT NULL DEFAULT '',
        period TEXT NOT NULL CHECK (period IN ('weekly', 'monthly')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
        effective_from INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        updated_by TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'synced')),
        UNIQUE (household_id, period, effective_from)
      )
    ''');
    batch.execute(
      'INSERT INTO ${Tables.budgets} '
      '(id, period, amount_minor, effective_from, updated_at) '
      'SELECT id, period, amount_minor, effective_from, updated_at '
      'FROM budgets_v2',
    );
    batch.execute('DROP TABLE budgets_v2');
    batch.execute(
      'CREATE INDEX idx_budgets_period '
      'ON ${Tables.budgets}(household_id, period, effective_from)',
    );

    batch.execute(
      'ALTER TABLE ${Tables.categoryBudgets} RENAME TO category_budgets_v2',
    );
    batch.execute('''
      CREATE TABLE ${Tables.categoryBudgets} (
        id TEXT PRIMARY KEY,
        household_id TEXT NOT NULL DEFAULT '',
        category_id TEXT NOT NULL
          REFERENCES ${Tables.categories}(id) ON DELETE CASCADE,
        period TEXT NOT NULL CHECK (period IN ('weekly', 'monthly')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        updated_by TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'synced')),
        UNIQUE (household_id, category_id, period)
      )
    ''');
    batch.execute(
      'INSERT INTO ${Tables.categoryBudgets} '
      '(id, category_id, period, amount_minor, created_at, updated_at) '
      'SELECT id, category_id, period, amount_minor, created_at, updated_at '
      'FROM category_budgets_v2',
    );
    batch.execute('DROP TABLE category_budgets_v2');

    await batch.commit(noResult: true);
  }

  static Future<void> _createSchemaV1(Database db) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE ${Tables.categories} (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
        icon_key TEXT NOT NULL,
        color_value INTEGER NOT NULL,
        is_default INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        UNIQUE (name, type)
      )
    ''');

    batch.execute('''
      CREATE TABLE ${Tables.transactions} (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL CHECK (type IN ('income', 'expense')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        category_id TEXT NOT NULL
          REFERENCES ${Tables.categories}(id) ON DELETE RESTRICT,
        date INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        payment_method TEXT NOT NULL DEFAULT 'cash',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_transactions_date ON ${Tables.transactions}(date)',
    );
    batch.execute(
      'CREATE INDEX idx_transactions_type_date ON ${Tables.transactions}(type, date)',
    );
    batch.execute(
      'CREATE INDEX idx_transactions_category ON ${Tables.transactions}(category_id, date)',
    );

    batch.execute('''
      CREATE TABLE ${Tables.budgets} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        period TEXT NOT NULL CHECK (period IN ('weekly', 'monthly')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
        effective_from INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (period, effective_from)
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_budgets_period ON ${Tables.budgets}(period, effective_from)',
    );

    batch.execute('''
      CREATE TABLE ${Tables.categoryBudgets} (
        id TEXT PRIMARY KEY,
        category_id TEXT NOT NULL
          REFERENCES ${Tables.categories}(id) ON DELETE CASCADE,
        period TEXT NOT NULL CHECK (period IN ('weekly', 'monthly')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        UNIQUE (category_id, period)
      )
    ''');

    batch.execute('''
      CREATE TABLE ${Tables.appSettings} (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
  }

  static Future<void> _seedDefaults(Database db) async {
    final batch = db.batch();
    for (final c in DefaultCategories.all) {
      batch.insert(
        Tables.categories,
        c.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    batch.insert(Tables.appSettings, {
      'key': 'installed_at',
      'value': DateTime.now().toIso8601String(),
    });
    await batch.commit(noResult: true);
  }

  /// Re-inserts any missing built-in categories (e.g. after a restore).
  static Future<void> ensureDefaultCategories(DatabaseExecutor db) async {
    final batch = db.batch();
    for (final c in DefaultCategories.all) {
      batch.insert(
        Tables.categories,
        c.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> close() => _db.close();
}
