import 'package:money_mate/core/services/cloud_loan_store.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/repositories/loan_repository.dart';

/// [LoanRepository] in memory, for widget tests (same rules as SQLite).
class InMemoryLoanRepository implements LoanRepository {
  final Map<String, Loan> loans = {};
  final Map<String, LoanRepayment> repayments = {};
  final Map<String, LoanReminderSettings> reminders = {};
  final List<String> deleted = [];

  int _received(String loanId) => repayments.values
      .where((r) => r.loanId == loanId && r.counts)
      .fold(0, (s, r) => s + r.amountMinor);

  @override
  Future<List<Loan>> getLoans() async {
    final list = [
      for (final l in loans.values)
        l.copyWith(
          receivedMinor: _received(l.id),
          pendingRepayments: repayments.values
              .where((r) => r.loanId == l.id && r.isPending)
              .length,
        ),
    ]..sort((a, b) => b.lentDate.compareTo(a.lentDate));
    return list;
  }

  @override
  Future<List<LoanRepayment>> getRepayments() async =>
      repayments.values.toList()..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : b.createdAt.compareTo(a.createdAt);
      });

  @override
  Future<Map<String, LoanReminderSettings>> getReminderSettings() async => {
    ...reminders,
  };

  @override
  Future<void> insertLoan(Loan loan, LoanReminderSettings settings) async {
    loans[loan.id] = loan;
    reminders[loan.id] = settings;
  }

  @override
  Future<void> updateLoan(Loan loan) async {
    if (!loans.containsKey(loan.id)) {
      throw const LoanException('This lending record no longer exists.');
    }
    loans[loan.id] = loan;
  }

  @override
  Future<void> deleteLoan(String loanId, DateTime deletedAt) async {
    loans.remove(loanId);
    repayments.removeWhere((_, r) => r.loanId == loanId);
    reminders.remove(loanId);
    deleted.add(loanId);
  }

  @override
  Future<void> addRepayment(
    LoanRepayment repayment, {
    bool synced = false,
  }) async {
    final loan = loans[repayment.loanId];
    if (loan == null) {
      throw const LoanException('This lending record no longer exists.');
    }
    if (!synced &&
        _received(loan.id) + repayment.amountMinor > loan.totalOwedMinor) {
      throw const LoanException(
        'The repayment cannot be more than the outstanding amount.',
      );
    }
    repayments.putIfAbsent(repayment.id, () => repayment);
  }

  @override
  Future<void> applyVoid(LoanRepayment voided) async =>
      repayments[voided.id] = voided;

  @override
  Future<void> saveReminderSettings(
    LoanReminderSettings settings, {
    bool synced = false,
  }) async => reminders[settings.loanId] = settings;
}

/// In-memory Firestore stand-in for lending that enforces what the
/// security rules enforce: running totals that only move with a repayment
/// and never exceed what is owed, immutable repayments, household access
/// for members only, and reminder recipients changed only by the owner.
class InMemoryLoanCloud implements CloudLoanStore {
  /// `partitionKey/collection` → id → document.
  final Map<String, Map<String, Map<String, Object?>>> docs = {};

  /// Household → owner UID.
  final Map<String, String> householdOwners = {};

  /// Household → active members (all signed-in users when absent).
  final Map<String, Set<String>> householdMembers = {};

  bool offline = false;
  int repaymentWrites = 0;
  int _clock = 0;

  String _key(CloudPartition p, LoanCollection c) =>
      '${p.isPersonal ? 'users/${p.uid}' : 'households/${p.householdId}'}/'
      '${c.path}';

  Map<String, Map<String, Object?>> _col(CloudPartition p, LoanCollection c) =>
      docs.putIfAbsent(_key(p, c), () => {});

  void _check(CloudPartition p) {
    if (offline) throw const CloudUnavailableException('offline');
    if (p.isPersonal) return;
    final members = householdMembers[p.householdId];
    if (members != null && !members.contains(p.uid)) {
      throw CloudAccessDeniedException(p);
    }
  }

  Map<String, Object?> _stamp(Map<String, Object?> data) => {
    ...data,
    'serverUpdatedAt': ++_clock,
  };

  Map<String, Object?>? loanDoc(CloudPartition p, String id) =>
      _col(p, LoanCollection.loans)[id];

  Map<String, Object?>? repaymentDoc(CloudPartition p, String id) =>
      _col(p, LoanCollection.repayments)[id];

  Map<String, Object?>? reminderDoc(CloudPartition p, String id) =>
      _col(p, LoanCollection.reminders)[id];

  @override
  Future<void> upsertLoans(CloudPartition p, List<CloudRecord> loans) async {
    _check(p);
    final col = _col(p, LoanCollection.loans);
    for (final r in loans) {
      final existing = col[r.id];
      final merged = {
        ...?existing,
        ...r.data,
        'id': r.id,
        'updatedAt': r.updatedAtMs,
        'deleted': r.deleted,
        'updatedBy': p.uid,
      };
      if (!r.deleted &&
          (merged['receivedMinor'] as int? ?? 0) >
              (merged['totalOwedMinor']! as int)) {
        throw CloudAccessDeniedException(p);
      }
      col[r.id] = _stamp(merged);
    }
  }

  @override
  Future<void> upsertReminders(
    CloudPartition p,
    List<CloudRecord> settings,
  ) async {
    _check(p);
    final col = _col(p, LoanCollection.reminders);
    for (final r in settings) {
      if (!p.isPersonal) {
        final owner = householdOwners[p.householdId];
        final isOwner = owner == p.uid;
        final uids = (r.data['notifyUids'] as List?)?.cast<String>() ?? [];
        final allowedCreate =
            !col.containsKey(r.id) && uids.every((u) => u == owner);
        if (!isOwner && !allowedCreate) throw CloudAccessDeniedException(p);
      }
      col[r.id] = _stamp({
        ...r.data,
        'id': r.id,
        'updatedAt': r.updatedAtMs,
        'deleted': false,
        'updatedBy': p.uid,
      });
    }
  }

  @override
  Future<RepaymentWriteOutcome> recordRepayment(
    CloudPartition p,
    LoanRepayment r,
  ) async {
    _check(p);
    final repayments = _col(p, LoanCollection.repayments);
    if (repayments.containsKey(r.id)) {
      return RepaymentWriteOutcome.alreadyRecorded;
    }
    final loans = _col(p, LoanCollection.loans);
    final loan = loans[r.loanId];
    if (loan == null || loan['deleted'] == true) {
      return RepaymentWriteOutcome.loanMissing;
    }
    final next = (loan['receivedMinor'] as int? ?? 0) + r.amountMinor;
    if (next > (loan['totalOwedMinor']! as int)) {
      return RepaymentWriteOutcome.exceedsBalance;
    }
    repaymentWrites++;
    repayments[r.id] = _stamp({
      ...r.toCloudMap(),
      'id': r.id,
      'voided': false,
      'updatedAt': r.updatedAt.millisecondsSinceEpoch,
      'deleted': false,
    });
    loans[r.loanId] = {
      ...loan,
      'receivedMinor': next,
      'lastRepaymentId': r.id,
      'lastRepaymentOp': 'add',
    };
    return RepaymentWriteOutcome.recorded;
  }

  @override
  Future<RepaymentWriteOutcome> voidRepayment(
    CloudPartition p,
    LoanRepayment r,
  ) async {
    _check(p);
    final repayments = _col(p, LoanCollection.repayments);
    final current = repayments[r.id];
    if (current == null) return RepaymentWriteOutcome.loanMissing;
    if (current['voided'] == true) return RepaymentWriteOutcome.alreadyRecorded;
    final loans = _col(p, LoanCollection.loans);
    final loan = loans[r.loanId]!;
    repayments[r.id] = _stamp({
      ...current,
      'voided': true,
      'voidedAt': r.voidedAt?.millisecondsSinceEpoch,
      'voidedBy': r.voidedBy,
      'voidReason': r.voidReason,
      'updatedAt': r.updatedAt.millisecondsSinceEpoch,
    });
    loans[r.loanId] = {
      ...loan,
      'receivedMinor':
          (loan['receivedMinor'] as int? ?? 0) -
          (current['amountMinor']! as int),
      'lastRepaymentId': r.id,
      'lastRepaymentOp': 'void',
    };
    return RepaymentWriteOutcome.recorded;
  }

  @override
  Future<List<CloudLoanChange>> fetchChangedSince(
    CloudPartition p,
    LoanCollection c,
    SyncCursor? after, {
    int limit = 300,
  }) async {
    _check(p);
    final entries =
        _col(p, c).entries
            .map(
              (e) => (
                id: e.key,
                data: e.value,
                position: SyncCursor(e.value['serverUpdatedAt']! as int, e.key),
              ),
            )
            .where((e) => after == null || e.position.isAfter(after))
            .toList()
          ..sort((a, b) => a.position.compareTo(b.position));
    return [
      for (final e in entries.take(limit))
        CloudLoanChange(CloudRecord.fromCloudMap(e.id, e.data), e.position),
    ];
  }
}
