import 'package:sqflite/sqflite.dart';

import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/cloud_loan_store.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/sync_models.dart';

export 'package:money_mate/models/loan_model.dart' show LoanException;

/// Storage of loans given, their schedules, repayments and reminder
/// settings, personal and household alike.
///
/// Everything is written on the device first and marked for upload, so the
/// whole feature works offline. Nothing here is touched by the 90-day
/// transaction clean-up.
abstract class LoanRepository {
  /// Every loan with its schedule and what was repaid, newest first.
  Future<List<Loan>> getLoans();

  /// Every repayment (voided and refused ones included), newest first.
  Future<List<LoanRepayment>> getRepayments();

  /// Reminder settings by loan ID.
  Future<Map<String, LoanReminderSettings>> getReminderSettings();

  /// Stores a new loan with its schedule and reminder settings, in one
  /// database transaction.
  Future<void> insertLoan(Loan loan, LoanReminderSettings reminders);

  /// Saves [loan]'s details and schedule. Throws [LoanException] if it no
  /// longer exists.
  Future<void> updateLoan(Loan loan);

  /// Deletes a loan with its schedule, repayments and settings on this
  /// device and queues the deletion for the cloud (the cloud keeps the
  /// repayment records).
  Future<void> deleteLoan(String loanId, DateTime deletedAt);

  /// Records a repayment ([synced] when the cloud already has it). Throws
  /// [LoanException] when the loan does not exist or the repayment exceeds
  /// what is still owed; the check and the insert are one transaction.
  Future<void> addRepayment(LoanRepayment repayment, {bool synced = false});

  /// Stores a void the cloud has confirmed.
  Future<void> applyVoid(LoanRepayment voided);

  /// Saves reminder settings ([synced] when the cloud already has them).
  Future<void> saveReminderSettings(
    LoanReminderSettings settings, {
    bool synced = false,
  });
}

/// A local loan or reminder change ready to upload.
class PendingLoanRecord {
  const PendingLoanRecord({
    required this.record,
    required this.isTombstone,
    required this.stamp,
  });

  final CloudRecord record;
  final bool isTombstone;

  /// `updated_at` / `deleted_at` the upload was built from; confirmation
  /// only applies while the row still has it.
  final int stamp;

  String get id => record.id;
}

/// Local side of lending synchronisation.
abstract class LocalLoanSyncStore {
  /// Unsent loan changes and deletions of [partition].
  Future<List<PendingLoanRecord>> pendingLoans(CloudPartition partition);

  /// Unsent reminder settings of [partition]'s loans.
  Future<List<PendingLoanRecord>> pendingReminders(CloudPartition partition);

  /// Repayments of [partition]'s loans waiting for upload, oldest first.
  Future<List<LoanRepayment>> pendingRepayments(CloudPartition partition);

  /// Marks uploaded rows of [collection] as synced (unless changed since)
  /// and drops uploaded tombstones.
  Future<void> confirmUploaded(
    CloudPartition partition,
    LoanCollection collection,
    List<PendingLoanRecord> uploaded,
  );

  /// Records the outcome of uploading repayment [id].
  Future<void> markRepayment(
    String id,
    RepaymentSyncState state, {
    String? error,
  });

  /// Applies one cloud document (last writer wins by `updatedAt`; a newer
  /// unsent local change or deletion is kept). Returns true when local data
  /// changed.
  Future<bool> applyRemote(
    CloudPartition partition,
    LoanCollection collection,
    CloudRecord remote,
  );
}

class SqliteLoanRepository implements LoanRepository, LocalLoanSyncStore {
  SqliteLoanRepository(this._database);

  final AppDatabase _database;

  Database get _db => _database.db;

  static const _pending = 'pending';
  static const _synced = 'synced';

  /// Counted repayments (not voided, not refused by the cloud), in SQL.
  static const _counted = "r.voided = 0 AND r.sync_status != 'rejected'";

  // --------------------------------------------------------------- reads

  @override
  Future<List<Loan>> getLoans() async {
    final rows = await _db.rawQuery(
      'SELECT l.*, '
      '(SELECT COALESCE(SUM(r.amount_minor), 0) FROM ${Tables.loanRepayments} '
      'r WHERE r.loan_id = l.id AND $_counted) AS received_minor, '
      '(SELECT COUNT(*) FROM ${Tables.loanRepayments} r '
      "WHERE r.loan_id = l.id AND r.sync_status = 'pending') "
      'AS pending_repayments '
      'FROM ${Tables.loans} l ORDER BY l.lent_date DESC, l.created_at DESC',
    );
    final schedules = <String, List<LoanInstallment>>{};
    final installmentRows = await _db.query(
      Tables.loanInstallments,
      orderBy: 'loan_id, number',
    );
    for (final r in installmentRows) {
      try {
        final i = LoanInstallment.fromMap(r);
        schedules.putIfAbsent(i.loanId, () => []).add(i);
      } on FormatException {
        // A malformed row is skipped rather than hiding the loan.
      }
    }
    final loans = <Loan>[];
    for (final r in rows) {
      try {
        loans.add(
          Loan.fromMap(
            r,
            schedule: List.unmodifiable(schedules[r['id']] ?? const []),
          ),
        );
      } on FormatException {
        // Skipped, see above.
      }
    }
    return loans;
  }

  @override
  Future<List<LoanRepayment>> getRepayments() async {
    final rows = await _db.query(
      Tables.loanRepayments,
      orderBy: 'date DESC, created_at DESC',
    );
    final result = <LoanRepayment>[];
    for (final r in rows) {
      try {
        result.add(LoanRepayment.fromMap(r));
      } on FormatException {
        // Skipped, see getLoans.
      }
    }
    return result;
  }

  @override
  Future<Map<String, LoanReminderSettings>> getReminderSettings() async {
    final rows = await _db.query(Tables.loanReminders);
    return {
      for (final r in rows)
        r['loan_id']! as String: LoanReminderSettings.fromMap(r),
    };
  }

  static Future<Map<String, Object?>?> _loanRow(
    DatabaseExecutor db,
    String loanId,
  ) async {
    final rows = await db.query(
      Tables.loans,
      where: 'id = ?',
      whereArgs: [loanId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  static Future<int> _received(DatabaseExecutor db, String loanId) async {
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(r.amount_minor), 0) AS s '
      'FROM ${Tables.loanRepayments} r WHERE r.loan_id = ? AND $_counted',
      [loanId],
    );
    return (rows.first['s'] as int?) ?? 0;
  }

  // -------------------------------------------------------------- writes

  static Future<void> _replaceSchedule(
    DatabaseExecutor db,
    String loanId,
    List<LoanInstallment> schedule,
  ) async {
    await db.delete(
      Tables.loanInstallments,
      where: 'loan_id = ?',
      whereArgs: [loanId],
    );
    for (final i in schedule) {
      await db.insert(
        Tables.loanInstallments,
        i.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  @override
  Future<void> insertLoan(Loan loan, LoanReminderSettings reminders) =>
      _db.transaction((txn) async {
        await txn.insert(Tables.loans, {
          ...loan.toMap(),
          'sync_status': _pending,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await _replaceSchedule(txn, loan.id, loan.schedule);
        await txn.insert(Tables.loanReminders, {
          ...reminders.toMap(),
          'sync_status': _pending,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await _dropTombstone(txn, loan.householdId ?? '', loan.id);
      });

  @override
  Future<void> updateLoan(Loan loan) => _db.transaction((txn) async {
    final values = loan.toMap()
      ..remove('id')
      ..remove('household_id')
      ..remove('created_at')
      ..remove('created_by')
      ..remove('created_by_name');
    final count = await txn.update(
      Tables.loans,
      {...values, 'sync_status': _pending},
      where: 'id = ?',
      whereArgs: [loan.id],
    );
    if (count == 0) {
      throw const LoanException('This lending record no longer exists.');
    }
    await _replaceSchedule(txn, loan.id, loan.schedule);
  });

  @override
  Future<void> deleteLoan(String loanId, DateTime deletedAt) =>
      _db.transaction((txn) async {
        final loan = await _loanRow(txn, loanId);
        if (loan == null) return;
        await _removeLoanRows(txn, loanId);
        await _tombstone(
          txn,
          loan['household_id'] as String? ?? '',
          loanId,
          deletedAt.millisecondsSinceEpoch,
        );
      });

  static Future<void> _removeLoanRows(DatabaseExecutor db, String id) async {
    await db.delete(Tables.loans, where: 'id = ?', whereArgs: [id]);
    for (final table in [
      Tables.loanInstallments,
      Tables.loanRepayments,
      Tables.loanReminders,
    ]) {
      await db.delete(table, where: 'loan_id = ?', whereArgs: [id]);
    }
  }

  @override
  Future<void> addRepayment(LoanRepayment repayment, {bool synced = false}) =>
      _db.transaction((txn) async {
        final loan = await _loanRow(txn, repayment.loanId);
        if (loan == null) {
          throw const LoanException('This lending record no longer exists.');
        }
        final owed =
            (loan['principal_minor']! as int) +
            ((loan['interest_minor'] as int?) ?? 0);
        final received = await _received(txn, repayment.loanId);
        // A repayment the cloud already accepted is stored even if this
        // device has not seen every other repayment yet.
        if (!synced && received + repayment.amountMinor > owed) {
          throw const LoanException(
            'The repayment cannot be more than the outstanding amount.',
          );
        }
        await txn.insert(Tables.loanRepayments, {
          ...repayment.toMap(),
          'sync_status': synced ? _synced : _pending,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });

  @override
  Future<void> applyVoid(LoanRepayment voided) => _db.update(
    Tables.loanRepayments,
    {
      'voided': 1,
      'voided_at': voided.voidedAt?.millisecondsSinceEpoch,
      'voided_by': voided.voidedBy,
      'void_reason': voided.voidReason,
      'updated_at': voided.updatedAt.millisecondsSinceEpoch,
      'sync_status': _synced,
    },
    where: 'id = ?',
    whereArgs: [voided.id],
  );

  @override
  Future<void> saveReminderSettings(
    LoanReminderSettings settings, {
    bool synced = false,
  }) => _db.insert(Tables.loanReminders, {
    ...settings.toMap(),
    'sync_status': synced ? _synced : _pending,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // ---------------------------------------------------------- tombstones

  static Future<void> _tombstone(
    DatabaseExecutor db,
    String household,
    String id,
    int at,
  ) => db.insert(Tables.cloudTombstones, {
    'collection': LoanCollection.loans.path,
    'household_id': household,
    'id': id,
    'deleted_at': at,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<int?> _tombstoneAt(
    DatabaseExecutor db,
    String household,
    String id,
  ) async {
    final rows = await db.query(
      Tables.cloudTombstones,
      columns: ['deleted_at'],
      where: 'collection = ? AND household_id = ? AND id = ?',
      whereArgs: [LoanCollection.loans.path, household, id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['deleted_at']! as int;
  }

  static Future<void> _dropTombstone(
    DatabaseExecutor db,
    String household,
    String id,
  ) => db.delete(
    Tables.cloudTombstones,
    where: 'collection = ? AND household_id = ? AND id = ?',
    whereArgs: [LoanCollection.loans.path, household, id],
  );

  // ---------------------------------------------------------------- sync

  /// Loans of [p]'s scope, in SQL.
  static const _loansOf =
      'SELECT id FROM ${Tables.loans} WHERE household_id = ?';

  @override
  Future<List<PendingLoanRecord>> pendingLoans(CloudPartition p) async {
    final key = p.scope.storageKey;
    final rows = await _db.query(
      Tables.loans,
      where: "sync_status = '$_pending' AND household_id = ?",
      whereArgs: [key],
    );
    final ids = [for (final r in rows) r['id']! as String];
    final schedules = <String, List<LoanInstallment>>{};
    if (ids.isNotEmpty) {
      final installments = await _db.query(
        Tables.loanInstallments,
        where: 'loan_id IN ($_loansOf AND sync_status = ?)',
        whereArgs: [key, _pending],
        orderBy: 'loan_id, number',
      );
      for (final r in installments) {
        final i = LoanInstallment.fromMap(r);
        schedules.putIfAbsent(i.loanId, () => []).add(i);
      }
    }
    final result = <PendingLoanRecord>[];
    for (final r in rows) {
      try {
        final loan = Loan.fromMap(r, schedule: schedules[r['id']] ?? const []);
        final at = loan.updatedAt.millisecondsSinceEpoch;
        result.add(
          PendingLoanRecord(
            record: CloudRecord(
              id: loan.id,
              data: loan.toCloudMap(),
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
    final tombstones = await _db.query(
      Tables.cloudTombstones,
      where: 'collection = ? AND household_id = ?',
      whereArgs: [LoanCollection.loans.path, key],
    );
    for (final t in tombstones) {
      final at = t['deleted_at']! as int;
      result.add(
        PendingLoanRecord(
          record: CloudRecord.deletion(t['id']! as String, at),
          isTombstone: true,
          stamp: at,
        ),
      );
    }
    return result;
  }

  @override
  Future<List<PendingLoanRecord>> pendingReminders(CloudPartition p) async {
    final rows = await _db.query(
      Tables.loanReminders,
      where: "sync_status = '$_pending' AND loan_id IN ($_loansOf)",
      whereArgs: [p.scope.storageKey],
    );
    return [
      for (final r in rows)
        if (LoanReminderSettings.fromMap(r) case final s)
          PendingLoanRecord(
            record: CloudRecord(
              id: s.loanId,
              data: s.toCloudMap(),
              updatedAtMs: s.updatedAt.millisecondsSinceEpoch,
            ),
            isTombstone: false,
            stamp: s.updatedAt.millisecondsSinceEpoch,
          ),
    ];
  }

  @override
  Future<List<LoanRepayment>> pendingRepayments(CloudPartition p) async {
    final rows = await _db.query(
      Tables.loanRepayments,
      where: "sync_status = '$_pending' AND loan_id IN ($_loansOf)",
      whereArgs: [p.scope.storageKey],
      orderBy: 'created_at',
    );
    return [
      for (final r in rows)
        if (_tryRepayment(r) case final repayment?) repayment,
    ];
  }

  static LoanRepayment? _tryRepayment(Map<String, Object?> row) {
    try {
      return LoanRepayment.fromMap(row);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> confirmUploaded(
    CloudPartition p,
    LoanCollection collection,
    List<PendingLoanRecord> uploaded,
  ) async {
    final batch = _db.batch();
    for (final u in uploaded) {
      if (u.isTombstone) {
        batch.delete(
          Tables.cloudTombstones,
          where:
              'collection = ? AND household_id = ? AND id = ? '
              'AND deleted_at <= ?',
          whereArgs: [collection.path, p.scope.storageKey, u.id, u.stamp],
        );
      } else if (collection == LoanCollection.reminders) {
        batch.update(
          Tables.loanReminders,
          {'sync_status': _synced},
          where: 'loan_id = ? AND updated_at = ?',
          whereArgs: [u.id, u.stamp],
        );
      } else {
        batch.update(
          Tables.loans,
          {'sync_status': _synced},
          where: 'id = ? AND updated_at = ?',
          whereArgs: [u.id, u.stamp],
        );
      }
    }
    await batch.commit(noResult: true);
  }

  @override
  Future<void> markRepayment(
    String id,
    RepaymentSyncState state, {
    String? error,
  }) => _db.update(
    Tables.loanRepayments,
    {'sync_status': state.name, 'sync_error': error},
    where: 'id = ?',
    whereArgs: [id],
  );

  static bool _localWins(Map<String, Object?> local, int remoteAt) =>
      local['sync_status'] == _pending &&
      (local['updated_at']! as int) > remoteAt;

  @override
  Future<bool> applyRemote(
    CloudPartition p,
    LoanCollection collection,
    CloudRecord remote,
  ) => _db.transaction(
    (txn) => switch (collection) {
      LoanCollection.loans => _applyLoan(txn, p, remote),
      LoanCollection.repayments => _applyRepayment(txn, p, remote),
      LoanCollection.reminders => _applyReminders(txn, p, remote),
    },
  );

  static Future<bool> _applyLoan(
    Transaction txn,
    CloudPartition p,
    CloudRecord remote,
  ) async {
    final id = remote.id;
    final household = p.scope.storageKey;
    final tombstone = await _tombstoneAt(txn, household, id);
    // Deleted here after the cloud version was written: the deletion wins
    // and is uploaded.
    if (tombstone != null && tombstone >= remote.updatedAtMs) return false;
    final local = await _loanRow(txn, id);
    if (local != null && local['household_id'] != household) return false;

    if (remote.deleted) {
      if (tombstone != null) await _dropTombstone(txn, household, id);
      if (local == null || _localWins(local, remote.updatedAtMs)) return false;
      await _removeLoanRows(txn, id);
      return true;
    }
    final loan = Loan.fromCloudMap(
      id,
      remote.data,
      remote.updatedAtMs,
      householdId: p.householdId,
    );
    if (loan == null) return false;
    if (local != null) {
      final localAt = local['updated_at']! as int;
      if (_localWins(local, remote.updatedAtMs)) return false;
      if (localAt == remote.updatedAtMs) {
        await txn.update(
          Tables.loans,
          {'sync_status': _synced},
          where: 'id = ? AND updated_at = ?',
          whereArgs: [id, localAt],
        );
        return false;
      }
      if (remote.updatedAtMs < localAt) {
        // The cloud holds an older version than one this device already
        // uploaded: send ours again so every device converges.
        if (local['sync_status'] == _synced) {
          await txn.update(
            Tables.loans,
            {'sync_status': _pending},
            where: 'id = ? AND updated_at = ?',
            whereArgs: [id, localAt],
          );
        }
        return false;
      }
    }
    await txn.insert(Tables.loans, {
      ...loan.toMap(),
      'sync_status': _synced,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _replaceSchedule(txn, id, loan.schedule);
    if (tombstone != null) await _dropTombstone(txn, household, id);
    return true;
  }

  /// Rows of loans that are not on this device (deleted here, or of another
  /// scope) are not stored.
  static Future<bool> _ownsLoan(
    Transaction txn,
    CloudPartition p,
    String loanId,
  ) async {
    final loan = await _loanRow(txn, loanId);
    return loan != null && loan['household_id'] == p.scope.storageKey;
  }

  static Future<bool> _applyRepayment(
    Transaction txn,
    CloudPartition p,
    CloudRecord remote,
  ) async {
    final repayment = LoanRepayment.fromCloudMap(
      remote.id,
      remote.data,
      remote.updatedAtMs,
    );
    if (repayment == null || !await _ownsLoan(txn, p, repayment.loanId)) {
      return false;
    }
    final rows = await txn.query(
      Tables.loanRepayments,
      where: 'id = ?',
      whereArgs: [repayment.id],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final local = rows.first;
      // Already confirmed and unchanged.
      if (local['sync_status'] == _synced &&
          (local['voided'] == 1) == repayment.voided &&
          local['updated_at'] == remote.updatedAtMs) {
        return false;
      }
    }
    // The cloud copy is authoritative: repayments are created once and only
    // ever change by being voided.
    await txn.insert(Tables.loanRepayments, {
      ...repayment.toMap(),
      'sync_status': _synced,
      'sync_error': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }

  static Future<bool> _applyReminders(
    Transaction txn,
    CloudPartition p,
    CloudRecord remote,
  ) async {
    final settings = LoanReminderSettings.fromCloudMap(
      remote.id,
      remote.data,
      remote.updatedAtMs,
    );
    if (settings == null || !await _ownsLoan(txn, p, settings.loanId)) {
      return false;
    }
    final rows = await txn.query(
      Tables.loanReminders,
      where: 'loan_id = ?',
      whereArgs: [settings.loanId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final local = rows.first;
      if (_localWins(local, remote.updatedAtMs)) return false;
      if (local['updated_at'] == remote.updatedAtMs &&
          LoanReminderSettings.fromMap(local) == settings) {
        if (local['sync_status'] != _synced) {
          await txn.update(
            Tables.loanReminders,
            {'sync_status': _synced},
            where: 'loan_id = ?',
            whereArgs: [settings.loanId],
          );
        }
        return false;
      }
    }
    await txn.insert(Tables.loanReminders, {
      ...settings.toMap(),
      'sync_status': _synced,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return true;
  }
}
