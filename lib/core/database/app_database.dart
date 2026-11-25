import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/core/constants/app_constants.dart';

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

  /// Personal savings goals. Never removed by the retention clean-up.
  static const String savingsGoals = 'savings_goals';

  /// Contributions to and withdrawals from savings goals (transfers, not
  /// income or expenses).
  static const String savingsEntries = 'savings_entries';

  /// Members of independent shared goals, as last read from the cloud.
  static const String savingsMembers = 'savings_members';

  /// Shared-goal invitations the user sent or received, as last read from
  /// the cloud.
  static const String savingsInvitations = 'savings_invitations';

  /// Money lent to someone (personal or household). Lending records and
  /// everything below are never removed by the retention clean-up.
  static const String loans = 'loans';

  /// The repayment schedule of each loan (one row for a one-time loan).
  static const String loanInstallments = 'loan_installments';

  /// Money paid back. Permanent records: voided, never deleted.
  static const String loanRepayments = 'loan_repayments';

  /// Reminder settings of each loan, including the household members the
  /// household owner chose to remind.
  static const String loanReminders = 'loan_reminder_settings';
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

  /// Opens the on-device database of the account [uid].
  ///
  /// Every account has its own file, so signing in with another account on
  /// the same device never shows (or syncs) someone else's records. Older
  /// releases kept a single shared file ([AppConstants.databaseName]); it is
  /// handed over, untouched, to the account it belongs to — the one it was
  /// synchronised with, or the first account that opens it if it was never
  /// synchronised. Other accounts start with an empty database.
  static Future<AppDatabase> openForAccount(
    String uid, {
    DatabaseFactory? factory,
  }) async {
    final dbFactory = factory ?? databaseFactory;
    final dir = await dbFactory.getDatabasesPath();
    final path = p.join(dir, accountFileName(uid));
    if (!await dbFactory.databaseExists(path)) {
      await _claimLegacyDatabase(
        dbFactory,
        p.join(dir, AppConstants.databaseName),
        path,
        uid,
      );
    }
    return _openAt(dbFactory, path);
  }

  /// File name of [uid]'s database. Firebase UIDs are alphanumeric; any
  /// other character is replaced so the name is always a safe file name.
  @visibleForTesting
  static String accountFileName(String uid) {
    final safe = uid.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'money_mate_$safe.db';
  }

  /// Moves the shared database of older releases to [accountPath] when it
  /// belongs to [uid]. The owner is recorded first, so an interrupted
  /// hand-over is finished by the same account next time.
  static Future<void> _claimLegacyDatabase(
    DatabaseFactory factory,
    String legacyPath,
    String accountPath,
    String uid,
  ) async {
    if (!await factory.databaseExists(legacyPath)) return;
    final legacy = await _openAt(factory, legacyPath);
    try {
      final rows = await legacy.db.query(
        Tables.appSettings,
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [SyncKeys.ownerUid],
        limit: 1,
      );
      final owner = rows.isEmpty ? null : rows.first['value'] as String?;
      if (owner != null && owner != uid) return;
      if (owner == null) {
        await legacy.db.insert(Tables.appSettings, {
          'key': SyncKeys.ownerUid,
          'value': uid,
        });
      }
    } finally {
      await legacy.close();
    }
    // Same directory, so each rename is atomic. SQLite side files (rollback
    // journal or WAL) move with the database.
    for (final suffix in const ['', '-journal', '-wal', '-shm']) {
      final file = File('$legacyPath$suffix');
      if (await file.exists()) await file.rename('$accountPath$suffix');
    }
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
    5: _migrateToV5,
    6: _migrateToV6,
    7: _migrateToV7,
    8: _migrateToV8,
  };

  /// v8: extra repayments reduce the capital and revise the EMI.
  ///
  /// * Loans get their interest method ('flat' for every existing loan, so
  ///   nothing changes for them) and the EMI and term first agreed.
  /// * Instalments get their interest part (null for existing ones, which
  ///   are split in proportion when read).
  /// * Repayments keep how they were applied (JSON), for the record.
  static Future<void> _migrateToV8(Database db) async {
    final batch = db.batch();
    batch.execute(
      'ALTER TABLE ${Tables.loans} ADD COLUMN interest_method TEXT NOT NULL '
      "DEFAULT 'flat' CHECK (interest_method IN ('flat', 'reducing'))",
    );
    batch.execute(
      'ALTER TABLE ${Tables.loans} ADD COLUMN original_installment_minor '
      'INTEGER',
    );
    batch.execute(
      'ALTER TABLE ${Tables.loans} ADD COLUMN original_term_months INTEGER',
    );
    batch.execute(
      'ALTER TABLE ${Tables.loanInstallments} ADD COLUMN interest_minor '
      'INTEGER',
    );
    batch.execute(
      'ALTER TABLE ${Tables.loanRepayments} ADD COLUMN allocation TEXT',
    );
    await batch.commit(noResult: true);
  }

  /// v7: money lent (loans given), their schedules, repayments and reminder
  /// settings. Adds tables only; no existing row changes.
  ///
  /// Lending is a transfer, not income or an expense, so none of it is in
  /// the `transactions` table and reports and budgets never see it. There
  /// are no foreign keys from instalments, repayments and reminder
  /// settings to loans because they may arrive from the cloud in any order;
  /// rows of a missing loan are not counted.
  static Future<void> _migrateToV7(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE ${Tables.loans} (
        id TEXT PRIMARY KEY,
        household_id TEXT NOT NULL DEFAULT '',
        borrower_name TEXT NOT NULL,
        borrower_phone TEXT NOT NULL DEFAULT '',
        borrower_email TEXT NOT NULL DEFAULT '',
        principal_minor INTEGER NOT NULL CHECK (principal_minor > 0),
        interest_rate_bp INTEGER NOT NULL DEFAULT 0
          CHECK (interest_rate_bp >= 0),
        interest_minor INTEGER NOT NULL DEFAULT 0 CHECK (interest_minor >= 0),
        lent_date INTEGER NOT NULL,
        repayment_type TEXT NOT NULL
          CHECK (repayment_type IN ('monthly', 'oneTime')),
        installment_minor INTEGER,
        first_due_date INTEGER,
        due_day INTEGER,
        end_date INTEGER,
        due_date INTEGER,
        notes TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        created_by TEXT,
        created_by_name TEXT,
        updated_by TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'synced'))
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_loans_scope ON ${Tables.loans}(household_id)',
    );
    batch.execute('''
      CREATE TABLE ${Tables.loanInstallments} (
        id TEXT PRIMARY KEY,
        loan_id TEXT NOT NULL,
        number INTEGER NOT NULL CHECK (number > 0),
        due_date INTEGER NOT NULL,
        expected_minor INTEGER NOT NULL CHECK (expected_minor > 0)
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_loan_installments_loan '
      'ON ${Tables.loanInstallments}(loan_id, number)',
    );
    batch.execute('''
      CREATE TABLE ${Tables.loanRepayments} (
        id TEXT PRIMARY KEY,
        loan_id TEXT NOT NULL,
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        date INTEGER NOT NULL,
        method TEXT NOT NULL DEFAULT 'cash',
        note TEXT NOT NULL DEFAULT '',
        installment_id TEXT,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        user_uid TEXT,
        user_name TEXT,
        voided INTEGER NOT NULL DEFAULT 0,
        voided_at INTEGER,
        voided_by TEXT,
        void_reason TEXT NOT NULL DEFAULT '',
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'synced', 'rejected')),
        sync_error TEXT
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_loan_repayments_loan '
      'ON ${Tables.loanRepayments}(loan_id, date)',
    );
    batch.execute('''
      CREATE TABLE ${Tables.loanReminders} (
        loan_id TEXT PRIMARY KEY,
        enabled INTEGER NOT NULL DEFAULT 1,
        paused INTEGER NOT NULL DEFAULT 0,
        offsets TEXT NOT NULL DEFAULT '[]',
        notify_uids TEXT NOT NULL DEFAULT '[]',
        updated_at INTEGER NOT NULL,
        updated_by TEXT,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'synced'))
      )
    ''');
    await batch.commit(noResult: true);
  }

  /// v6: household and independent shared savings goals.
  ///
  /// * Goals get an ownership ('personal' / 'household' / 'shared'), the
  ///   household of household goals ('' otherwise) and who created / last
  ///   changed them. Every existing goal stays personal.
  /// * Entries record who made them.
  /// * Members and invitations of shared goals are cached so the goals can
  ///   be shown offline.
  static Future<void> _migrateToV6(Database db) async {
    final batch = db.batch();
    batch.execute(
      'ALTER TABLE ${Tables.savingsGoals} ADD COLUMN ownership TEXT NOT NULL '
      "DEFAULT 'personal' "
      "CHECK (ownership IN ('personal', 'household', 'shared'))",
    );
    batch.execute(
      'ALTER TABLE ${Tables.savingsGoals} ADD COLUMN household_id TEXT '
      "NOT NULL DEFAULT ''",
    );
    for (final column in [
      'owner_uid',
      'created_by',
      'created_by_name',
      'updated_by',
    ]) {
      batch.execute(
        'ALTER TABLE ${Tables.savingsGoals} ADD COLUMN $column TEXT',
      );
    }
    batch.execute(
      'CREATE INDEX idx_savings_goals_scope '
      'ON ${Tables.savingsGoals}(ownership, household_id)',
    );
    batch.execute(
      'ALTER TABLE ${Tables.savingsEntries} ADD COLUMN user_uid TEXT',
    );
    batch.execute(
      'ALTER TABLE ${Tables.savingsEntries} ADD COLUMN user_name TEXT',
    );
    batch.execute('''
      CREATE TABLE ${Tables.savingsMembers} (
        goal_id TEXT NOT NULL,
        uid TEXT NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'removed', 'left')),
        can_contribute INTEGER NOT NULL DEFAULT 1,
        can_withdraw INTEGER NOT NULL DEFAULT 0,
        display_name TEXT,
        email TEXT,
        joined_at INTEGER,
        PRIMARY KEY (goal_id, uid)
      )
    ''');
    batch.execute('''
      CREATE TABLE ${Tables.savingsInvitations} (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL,
        goal_name TEXT NOT NULL,
        invited_email TEXT,
        invited_by TEXT NOT NULL,
        invited_by_name TEXT,
        status TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        accepted_by TEXT,
        accepted_by_name TEXT,
        direction TEXT NOT NULL DEFAULT 'sent'
          CHECK (direction IN ('sent', 'received'))
      )
    ''');
    await batch.commit(noResult: true);
  }

  /// v5: savings goals and their contribution / withdrawal history. Adds
  /// tables only; no existing row changes.
  ///
  /// A goal's saved amount is not stored: it is the sum of its entries, so
  /// every device derives the same balance from the same history. There is
  /// no foreign key from entries to goals because entries may arrive from
  /// the cloud before their goal; entries of a missing goal are not counted.
  static Future<void> _migrateToV5(Database db) async {
    final batch = db.batch();
    batch.execute('''
      CREATE TABLE ${Tables.savingsGoals} (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        purpose TEXT NOT NULL DEFAULT 'other',
        custom_purpose TEXT NOT NULL DEFAULT '',
        target_minor INTEGER NOT NULL CHECK (target_minor > 0),
        target_date INTEGER,
        notes TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'active'
          CHECK (status IN ('active', 'paused', 'completed')),
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        completed_at INTEGER,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'synced'))
      )
    ''');
    batch.execute('''
      CREATE TABLE ${Tables.savingsEntries} (
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL,
        type TEXT NOT NULL CHECK (type IN ('deposit', 'withdrawal')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        date INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_status IN ('pending', 'synced'))
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_savings_entries_goal '
      'ON ${Tables.savingsEntries}(goal_id, date)',
    );
    await batch.commit(noResult: true);
  }

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
