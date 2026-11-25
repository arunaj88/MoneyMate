import 'package:flutter/foundation.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/cloud_loan_store.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/repositories/loan_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';

/// Synchronises loans given, their repayments and reminder settings; run
/// by `TransactionSyncService` for the personal partition and, while the
/// user belongs to one, the household partition.
///
/// For each partition and collection (loans first, so repayments and
/// settings always find their loan):
///
/// 1. **Pull** changes since the collection's cursor. Loans and settings
///    are last-writer-wins by `updatedAt` (a newer unsent local edit or
///    deletion is kept); repayments come from the cloud as they are.
/// 2. **Push** pending changes. Loans and settings are batched; each
///    repayment is written in a Firestore transaction with the loan's
///    running total, which is idempotent (an already uploaded repayment is
///    only confirmed) and safe against several members recording
///    repayments at once. A repayment the cloud refuses because the loan
///    has meanwhile been repaid elsewhere is kept, marked as refused, and
///    no longer counts.
///
/// Rows are marked synced only after the cloud confirmed them. Lending data
/// is never removed by the 90-day transaction clean-up. A refused lending
/// collection (e.g. security rules not deployed yet, or a member's change
/// only the household owner may make) never stops the rest of the sync.
class LoanSyncEngine {
  LoanSyncEngine({
    required LocalLoanSyncStore local,
    required CloudLoanStore cloud,
    required LocalSyncStore settings,
    this.pageSize = 300,
  }) : _local = local,
       _cloud = cloud,
       _settings = settings;

  final LocalLoanSyncStore _local;
  final CloudLoanStore _cloud;
  final LocalSyncStore _settings;
  final int pageSize;

  Future<void> sync(
    CloudPartition partition,
    SyncReport report, {
    required bool download,
    required bool restore,
  }) async {
    for (final collection in LoanCollection.values) {
      try {
        if (download) await _pull(partition, collection, report, restore);
        switch (collection) {
          case LoanCollection.loans:
            await _pushRecords(partition, collection, report);
          case LoanCollection.repayments:
            await _pushRepayments(partition, report);
          case LoanCollection.reminders:
            await _pushRecords(partition, collection, report);
        }
      } on CloudUnavailableException {
        rethrow;
      } on CloudAccessDeniedException {
        debugPrint('Lending ${collection.path} of $partition not accessible.');
        report.loansUnavailable = true;
        // Without the loans, repayments and settings cannot be matched.
        if (collection == LoanCollection.loans) return;
      } catch (e, stack) {
        debugPrint(
          'Syncing ${collection.path} of $partition failed: $e\n$stack',
        );
        report.failed++;
        if (collection == LoanCollection.loans) return;
      }
    }
  }

  Future<void> _pushRecords(
    CloudPartition p,
    LoanCollection c,
    SyncReport report,
  ) async {
    final pending = c == LoanCollection.loans
        ? await _local.pendingLoans(p)
        : await _local.pendingReminders(p);
    if (pending.isEmpty) return;
    final records = [for (final r in pending) r.record];
    if (c == LoanCollection.loans) {
      await _cloud.upsertLoans(p, records);
    } else {
      await _cloud.upsertReminders(p, records);
    }
    await _local.confirmUploaded(p, c, pending);
    report.loansUploaded += pending.length;
  }

  Future<void> _pushRepayments(CloudPartition p, SyncReport report) async {
    final pending = await _local.pendingRepayments(p);
    for (final repayment in pending) {
      final outcome = await _cloud.recordRepayment(p, repayment);
      switch (outcome) {
        case RepaymentWriteOutcome.recorded:
        case RepaymentWriteOutcome.alreadyRecorded:
          await _local.markRepayment(repayment.id, RepaymentSyncState.synced);
          report.loansUploaded++;
        case RepaymentWriteOutcome.exceedsBalance:
          await _local.markRepayment(
            repayment.id,
            RepaymentSyncState.rejected,
            error:
                'Other repayments recorded meanwhile already cover the '
                'outstanding amount.',
          );
          report.repaymentsRejected++;
        case RepaymentWriteOutcome.loanMissing:
          // Kept until the loan's deletion arrives, which removes it.
          report.failed++;
      }
    }
  }

  String _cursorKey(CloudPartition p, LoanCollection c, String part) =>
      p.isPersonal
      ? SyncKeys.personalLoansCursor(c.path, part)
      : SyncKeys.householdLoansCursor(p.householdId!, c.path, part);

  Future<void> _pull(
    CloudPartition p,
    LoanCollection collection,
    SyncReport report,
    bool restore,
  ) async {
    final microsKey = _cursorKey(p, collection, 'micros');
    final docKey = _cursorKey(p, collection, 'doc_id');
    if (restore) {
      // Read everything again; rows are matched by ID, so nothing is
      // duplicated.
      await _settings.removeSetting(microsKey);
      await _settings.removeSetting(docKey);
    }
    final micros = int.tryParse(await _settings.getSetting(microsKey) ?? '');
    final docId = await _settings.getSetting(docKey);
    var cursor = micros == null || docId == null
        ? null
        : SyncCursor(micros, docId);
    while (true) {
      final page = await _cloud.fetchChangedSince(
        p,
        collection,
        cursor,
        limit: pageSize,
      );
      for (final change in page) {
        final record = change.record;
        if (record != null && await _local.applyRemote(p, collection, record)) {
          report.loansDownloaded++;
        }
        final position = change.position;
        if (position != null && (cursor == null || position.isAfter(cursor))) {
          cursor = position;
        }
      }
      if (cursor != null) {
        await _settings.setSetting(microsKey, cursor.serverMicros.toString());
        await _settings.setSetting(docKey, cursor.docId);
      }
      if (page.length < pageSize) break;
    }
  }
}
