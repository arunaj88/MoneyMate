import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/sync_models.dart';

/// The lending collections of a personal or household partition:
/// `users/{uid}/…` or `households/{householdId}/…`.
enum LoanCollection {
  /// Loan terms and schedule, plus the cloud running total.
  loans('loans'),

  /// Repayments (permanent; voided, never deleted).
  repayments('loanRepayments'),

  /// Reminder settings and household reminder recipients, one per loan.
  reminders('loanReminders');

  const LoanCollection(this.path);

  /// Collection name; also the `collection` value of local tombstones.
  final String path;
}

/// A lending document read from the change feed.
class CloudLoanChange {
  const CloudLoanChange(this.record, this.position);

  /// Null when the document cannot be read; it is skipped, but its
  /// [position] still moves the pull cursor past it.
  final CloudRecord? record;
  final SyncCursor? position;
}

/// Result of writing (or voiding) one repayment.
enum RepaymentWriteOutcome {
  /// Written together with the loan's new running total.
  recorded,

  /// Already in the cloud (an earlier attempt succeeded, or it was voided
  /// already): nothing was written again.
  alreadyRecorded,

  /// The loan no longer exists (deleted on another device).
  loanMissing,

  /// Together with repayments recorded elsewhere it would exceed what is
  /// owed.
  exceedsBalance,
}

/// Cloud side of lending.
///
/// Documents keep their local IDs, so retrying an upload never duplicates
/// anything. Loans are deleted softly (`deleted: true`); repayments and
/// reminder settings are never deleted.
///
/// Every loan document keeps a running total of what was repaid
/// (`receivedMinor`). Each repayment is written, and each void applied, in
/// a Firestore transaction together with the new total; security rules
/// check that the total moves by exactly that repayment's amount and stays
/// between zero and what is owed. Concurrent repayments recorded by
/// several household members therefore never exceed the balance and are
/// never counted twice.
abstract class CloudLoanStore {
  /// Writes loan terms (merged, so the running total is never
  /// overwritten).
  Future<void> upsertLoans(CloudPartition partition, List<CloudRecord> loans);

  /// Writes reminder settings.
  Future<void> upsertReminders(
    CloudPartition partition,
    List<CloudRecord> settings,
  );

  /// Writes one repayment and the loan's new total in one transaction.
  Future<RepaymentWriteOutcome> recordRepayment(
    CloudPartition partition,
    LoanRepayment repayment,
  );

  /// Marks [voided] (already carrying its void details) as voided and
  /// lowers the loan's total, in one transaction.
  Future<RepaymentWriteOutcome> voidRepayment(
    CloudPartition partition,
    LoanRepayment voided,
  );

  /// Documents of [collection] written after [after], oldest first.
  Future<List<CloudLoanChange>> fetchChangedSince(
    CloudPartition partition,
    LoanCollection collection,
    SyncCursor? after, {
    int limit = 300,
  });
}

/// [CloudLoanStore] backed by Cloud Firestore (server reads only).
class FirestoreLoanStore implements CloudLoanStore {
  FirestoreLoanStore({FirebaseFirestore? firestore, Duration? timeout})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _timeout = timeout ?? const Duration(seconds: 30);

  final FirebaseFirestore _firestore;
  final Duration _timeout;

  static const _serverField = 'serverUpdatedAt';
  static const _serverOnly = GetOptions(source: Source.server);
  static const _batchSize = 400;

  Object get _now => FieldValue.serverTimestamp();

  CollectionReference<Map<String, dynamic>> _collection(
    CloudPartition p,
    LoanCollection c,
  ) => p.isPersonal
      ? _firestore.collection(CloudPaths.users).doc(p.uid).collection(c.path)
      : _firestore
            .collection(CloudPaths.households)
            .doc(p.householdId)
            .collection(c.path);

  Future<T> _guard<T>(CloudPartition p, Future<T> Function() action) =>
      guardFirestore(p, action);

  @override
  Future<void> upsertLoans(CloudPartition p, List<CloudRecord> loans) =>
      _guard(p, () async {
        final ref = _collection(p, LoanCollection.loans);
        for (var i = 0; i < loans.length; i += _batchSize) {
          final batch = _firestore.batch();
          for (final r in loans.skip(i).take(_batchSize)) {
            batch.set(
              ref.doc(r.id),
              r.deleted
                  ? {
                      'id': r.id,
                      'deleted': true,
                      'deletedAt': r.updatedAtMs,
                      'updatedAt': r.updatedAtMs,
                      'updatedBy': p.uid,
                      _serverField: _now,
                    }
                  : {
                      ...r.data,
                      'id': r.id,
                      'updatedAt': r.updatedAtMs,
                      'deleted': false,
                      'updatedBy': p.uid,
                      _serverField: _now,
                    },
              // The running total is never overwritten by an edit.
              SetOptions(merge: true),
            );
          }
          await batch.commit().timeout(_timeout);
        }
      });

  @override
  Future<void> upsertReminders(CloudPartition p, List<CloudRecord> settings) =>
      _guard(p, () async {
        final ref = _collection(p, LoanCollection.reminders);
        for (var i = 0; i < settings.length; i += _batchSize) {
          final batch = _firestore.batch();
          for (final r in settings.skip(i).take(_batchSize)) {
            batch.set(ref.doc(r.id), {
              ...r.data,
              'id': r.id,
              'updatedAt': r.updatedAtMs,
              'deleted': false,
              'updatedBy': p.uid,
              _serverField: _now,
            });
          }
          await batch.commit().timeout(_timeout);
        }
      });

  @override
  Future<RepaymentWriteOutcome> recordRepayment(
    CloudPartition p,
    LoanRepayment r,
  ) => _guard(p, () async {
    final loanRef = _collection(p, LoanCollection.loans).doc(r.loanId);
    final repaymentRef = _collection(p, LoanCollection.repayments).doc(r.id);
    return _firestore
        .runTransaction((tx) async {
          // Idempotent: a retry after a lost response writes nothing.
          if ((await tx.get(repaymentRef)).exists) {
            return RepaymentWriteOutcome.alreadyRecorded;
          }
          final loan = (await tx.get(loanRef)).data();
          if (loan == null || loan['deleted'] == true) {
            return RepaymentWriteOutcome.loanMissing;
          }
          final received = loan['receivedMinor'];
          final owed = loan['totalOwedMinor'];
          final next = (received is int ? received : 0) + r.amountMinor;
          if (owed is! int || next > owed) {
            return RepaymentWriteOutcome.exceedsBalance;
          }
          tx.set(repaymentRef, {
            ...r.toCloudMap(),
            'id': r.id,
            'voided': false,
            'updatedAt': r.updatedAt.millisecondsSinceEpoch,
            'deleted': false,
            _serverField: _now,
          });
          tx.update(loanRef, {
            'receivedMinor': next,
            'lastRepaymentId': r.id,
            'lastRepaymentOp': 'add',
          });
          return RepaymentWriteOutcome.recorded;
        })
        .timeout(_timeout);
  });

  @override
  Future<RepaymentWriteOutcome> voidRepayment(
    CloudPartition p,
    LoanRepayment r,
  ) => _guard(p, () async {
    final loanRef = _collection(p, LoanCollection.loans).doc(r.loanId);
    final repaymentRef = _collection(p, LoanCollection.repayments).doc(r.id);
    return _firestore
        .runTransaction((tx) async {
          final current = (await tx.get(repaymentRef)).data();
          if (current == null) return RepaymentWriteOutcome.loanMissing;
          if (current['voided'] == true) {
            return RepaymentWriteOutcome.alreadyRecorded;
          }
          final loan = (await tx.get(loanRef)).data();
          if (loan == null || loan['deleted'] == true) {
            return RepaymentWriteOutcome.loanMissing;
          }
          final received = loan['receivedMinor'];
          final amount = current['amountMinor'];
          final next =
              (received is int ? received : 0) - (amount is int ? amount : 0);
          tx.update(repaymentRef, {
            'voided': true,
            'voidedAt': r.voidedAt?.millisecondsSinceEpoch,
            'voidedBy': r.voidedBy,
            'voidReason': r.voidReason,
            'updatedAt': r.updatedAt.millisecondsSinceEpoch,
            _serverField: _now,
          });
          tx.update(loanRef, {
            'receivedMinor': next < 0 ? 0 : next,
            'lastRepaymentId': r.id,
            'lastRepaymentOp': 'void',
          });
          return RepaymentWriteOutcome.recorded;
        })
        .timeout(_timeout);
  });

  @override
  Future<List<CloudLoanChange>> fetchChangedSince(
    CloudPartition p,
    LoanCollection c,
    SyncCursor? after, {
    int limit = 300,
  }) => _guard(p, () async {
    Query<Map<String, dynamic>> query = _collection(
      p,
      c,
    ).orderBy(_serverField).orderBy(FieldPath.documentId);
    if (after != null) {
      query = query.startAfter([
        Timestamp.fromMicrosecondsSinceEpoch(after.serverMicros),
        after.docId,
      ]);
    }
    final snap = await query.limit(limit).get(_serverOnly).timeout(_timeout);
    return [
      for (final doc in snap.docs)
        CloudLoanChange(
          CloudRecord.fromCloudMap(doc.id, doc.data()),
          _position(doc),
        ),
    ];
  });

  static SyncCursor? _position(DocumentSnapshot<Map<String, dynamic>> doc) {
    final server = doc.data()?[_serverField];
    return server is Timestamp
        ? SyncCursor(server.microsecondsSinceEpoch, doc.id)
        : null;
  }
}
