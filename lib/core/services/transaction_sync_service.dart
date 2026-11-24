import 'package:flutter/foundation.dart';

import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/savings_repository.dart';
import 'package:money_mate/repositories/settings_sync_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/cloud_savings_store.dart';
import 'package:money_mate/core/services/savings_sync.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/core/services/sync_conflict_resolver.dart';

/// How many days of transactions stay in the on-device database.
class RetentionPolicy {
  const RetentionPolicy({this.days = AppConstants.defaultLocalRetentionDays})
    : assert(days > 0, 'Retention must be at least one day');

  final int days;

  /// Transactions dated before this local midnight may be removed from the
  /// device (once verified in the cloud). Everything from the cutoff
  /// onwards – the latest [days] days, including today – is always kept.
  DateTime cutoff(DateTime now) =>
      DateTime(now.year, now.month, now.day - days);
}

enum SyncOutcome {
  /// Push, pull and (when allowed) clean-up all finished.
  completed,

  /// The cloud could not be reached; nothing was lost and it will retry.
  offline,

  /// This device's data is linked to a different account.
  accountMismatch,

  /// An unexpected error; unsynchronised records stay pending.
  failed,
}

class SyncResult {
  const SyncResult(this.outcome, this.report, {this.error});

  final SyncOutcome outcome;
  final SyncReport report;
  final String? error;
}

/// Which part of the user's cloud data a restore is downloading.
enum RestoreStep { personal, household }

/// Progress of Restore My Cloud Data.
class RestoreProgress {
  const RestoreProgress(this.step, this.downloaded);

  final RestoreStep step;

  /// Transactions, budgets and categories saved on this device so far.
  final int downloaded;
}

typedef RestoreProgressCallback = void Function(RestoreProgress progress);

/// Transactions loaded from the cloud history for display.
class HistoryResult {
  const HistoryResult({
    required this.transactions,
    required this.cursor,
    required this.hasMore,
    required this.categoriesAdded,
  });

  final List<TransactionModel> transactions;
  final Object? cursor;
  final bool hasMore;

  /// True when categories were created locally for these transactions.
  final bool categoriesAdded;
}

/// Two-way synchronisation between SQLite and Cloud Firestore, plus the
/// 90-day local retention clean-up.
///
/// One cycle synchronises the user's personal data and then, when the user
/// belongs to one, their household's shared data. Each data scope is
/// handled separately – its own collections, cursor, conflict resolution
/// and clean-up – so personal and shared records are never mixed:
///
/// 1. **Push** – upload pending/failed local changes (conflicts resolved by
///    `updatedAt`), then re-read every uploaded document from the server and
///    mark only matching rows as synced.
/// 2. **Pull** – apply cloud changes made on other devices (or by other
///    household members) since the last cursor. Documents older than the
///    retention window are left in the cloud.
/// 3. **Clean-up** – only when nothing local in that scope is pending or
///    failed: re-verify each old synced row against the server copy and
///    remove from the device only those that match exactly. Cloud
///    documents are never deleted.
/// 4. **Budgets and categories** – upload pending changes, then merge the
///    whole (small) cloud collection by `updatedAt`.
/// 5. **Savings** – personal, household and shared goals and their
///    history (see [SavingsSyncEngine]). Savings are never removed by the
///    retention clean-up.
///
/// If the household refuses access (the user was removed), the personal
/// sync still completes and the household is reported in
/// [SyncReport.householdsDenied].
///
/// After Reset App ([resetLocalData]) a restore is pending: cycles still
/// upload changes made on this device since the reset, but download
/// nothing (no pull, no budget or category merge, no cloud history), so
/// the app stays fresh. [restoreFromCloud] downloads everything again and
/// ends that state once it fully succeeded.
class TransactionSyncService {
  TransactionSyncService({
    required LocalSyncStore local,
    required CloudTransactionStore cloud,
    LocalSettingsSyncStore? settings,
    CloudRecordStore? records,
    LocalSavingsSyncStore? savingsLocal,
    CloudSavingsStore? savingsCloud,
    DateTime Function()? clock,
    this.pushBatchSize = 200,
    this.pullPageSize = 300,
  }) : _local = local,
       _cloud = cloud,
       _settings = settings,
       _records = records,
       _savings = savingsLocal == null || savingsCloud == null
           ? null
           : SavingsSyncEngine(
               local: savingsLocal,
               cloud: savingsCloud,
               settings: local,
               pageSize: pullPageSize,
             ),
       _clock = clock ?? DateTime.now;

  final LocalSyncStore _local;
  final CloudTransactionStore _cloud;
  final LocalSettingsSyncStore? _settings;
  final CloudRecordStore? _records;
  final SavingsSyncEngine? _savings;
  final DateTime Function() _clock;
  final int pushBatchSize;
  final int pullPageSize;

  Future<SyncResult>? _running;

  Future<RetentionPolicy> retentionPolicy() async => RetentionPolicy(
    days: parseRetentionDays(await _local.getSetting(SyncKeys.retentionDays)),
  );

  /// Start of the local retention window.
  Future<DateTime> retentionCutoff() async =>
      (await retentionPolicy()).cutoff(_clock());

  /// Unsynced changes in [scope], or in every scope when null.
  Future<({int pending, int failed})> countUnsynced({DataScope? scope}) =>
      _local.countUnsynced(scope: scope);

  Future<DateTime?> lastSyncedAt() async {
    final ms = int.tryParse(
      await _local.getSetting(SyncKeys.lastSyncedAt) ?? '',
    );
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// UID this device's data is linked to, if it has synced before.
  Future<String?> ownerUid() => _local.getSetting(SyncKeys.ownerUid);

  /// True after Reset App until Restore My Cloud Data succeeded.
  Future<bool> isRestorePending() async =>
      await _local.getSetting(SyncKeys.restorePending) != null;

  /// Reset App: clears this device's data and marks a restore as pending
  /// (see [LocalSyncStore.clearLocalData]). Cloud data is not touched.
  /// Callers make sure no sync cycle is running.
  Future<void> resetLocalData() => _local.clearLocalData(resetAt: _clock());

  /// Restore My Cloud Data: downloads the user's personal data and, while
  /// they are still an active member, [householdId]'s shared data. Records
  /// keep their cloud IDs and are matched by ID, so a retry after an
  /// interruption never creates duplicates. Transactions older than the
  /// retention window stay in the cloud, as in every sync. The pending
  /// restore ends only when the cycle completed without errors.
  ///
  /// Waits for a cycle that is already running.
  Future<SyncResult> restoreFromCloud(
    String uid, {
    String? householdId,
    RestoreProgressCallback? onProgress,
  }) async {
    while (_running != null) {
      await _running;
    }
    return _running = _run(
      uid,
      householdId,
      restore: true,
      onProgress: onProgress,
    ).whenComplete(() => _running = null);
  }

  /// Runs one sync cycle for [uid] (and [householdId]'s shared data when
  /// given). Concurrent calls share the running cycle.
  Future<SyncResult> synchronize(String uid, {String? householdId}) {
    return _running ??= _run(
      uid,
      householdId,
    ).whenComplete(() => _running = null);
  }

  Future<SyncResult> _run(
    String uid,
    String? householdId, {
    bool restore = false,
    RestoreProgressCallback? onProgress,
  }) async {
    final report = SyncReport();
    final owner = await _local.getSetting(SyncKeys.ownerUid);
    if (owner != null && owner != uid) {
      return SyncResult(SyncOutcome.accountMismatch, report);
    }
    try {
      if (owner == null) await _local.setSetting(SyncKeys.ownerUid, uid);
      final cutoff = await retentionCutoff();
      // After Reset App nothing is downloaded until the user restores.
      final download = restore || !await isRestorePending();
      report.restorePending = !download;

      void progress(RestoreStep step) => onProgress?.call(
        RestoreProgress(
          step,
          report.downloaded +
              report.budgetsDownloaded +
              report.categoriesDownloaded,
        ),
      );

      final personal = CloudPartition.personal(uid);
      if (restore) {
        // Read everything again: rows are matched by ID, so what is
        // already on this device is confirmed rather than duplicated.
        await _forgetPullPosition(personal.scope);
        progress(RestoreStep.personal);
      }
      if (download) await _applyRemoteReset(uid, report);
      await _syncTransactions(
        personal,
        report,
        cutoff,
        download: download,
        onPage: restore ? () => progress(RestoreStep.personal) : null,
      );
      await _syncSettings(personal, report, download: download);
      await _savings?.syncPersonal(
        uid,
        report,
        download: download,
        restore: restore,
      );

      if (householdId != null) {
        final shared = CloudPartition.household(uid, householdId);
        try {
          if (restore) {
            await _forgetPullPosition(shared.scope);
            progress(RestoreStep.household);
          }
          await _syncTransactions(
            shared,
            report,
            cutoff,
            download: download,
            onPage: restore ? () => progress(RestoreStep.household) : null,
          );
          await _syncSettings(shared, report, download: download);
          await _savings?.syncHousehold(
            uid,
            householdId,
            report,
            download: download,
            restore: restore,
          );
        } on CloudAccessDeniedException {
          // No longer an active member: nothing is uploaded or deleted; the
          // household provider confirms the membership and releases the
          // cached data.
          report.householdsDenied.add(householdId);
        }
      }

      // Independent shared goals do not depend on the household.
      await _savings?.syncShared(
        uid,
        report,
        download: download,
        restore: restore,
      );

      if (restore) {
        if (report.failed > 0) {
          // The restore stays pending; a retry continues safely.
          return SyncResult(
            SyncOutcome.failed,
            report,
            error: '${report.failed} record(s) could not be restored.',
          );
        }
        await _local.removeSetting(SyncKeys.restorePending);
        report.restored = true;
      }

      await _local.setSetting(
        SyncKeys.lastSyncedAt,
        _clock().millisecondsSinceEpoch.toString(),
      );
      return SyncResult(SyncOutcome.completed, report);
    } on CloudUnavailableException catch (e) {
      return SyncResult(SyncOutcome.offline, report, error: e.message);
    } catch (e, stack) {
      debugPrint('Sync failed: $e\n$stack');
      return SyncResult(SyncOutcome.failed, report, error: e.toString());
    }
  }

  /// The user reset their personal data on another device: remove this
  /// device's copies of records from before the reset, so they are not
  /// uploaded again (records changed here since then are kept).
  Future<void> _applyRemoteReset(String uid, SyncReport report) async {
    final DateTime? resetAt;
    try {
      resetAt = await _cloud.personalResetAt(uid);
    } on CloudAccessDeniedException {
      // The user document is unreadable (e.g. deployed security rules older
      // than this app). The marker only matters after a cloud reset, so it
      // must not stop the user's own data from syncing.
      debugPrint('Personal reset marker not readable; skipped.');
      return;
    }
    if (resetAt == null) return;
    final applied = await _local.getSetting(SyncKeys.personalResetAt);
    if (applied == resetAt.millisecondsSinceEpoch.toString()) return;
    await _local.clearPersonalData(resetAt: resetAt, changedBefore: resetAt);
    report.resetApplied = true;
  }

  Future<void> _forgetPullPosition(DataScope scope) async {
    await _local.removeSetting(SyncKeys.cursorMicros(scope));
    await _local.removeSetting(SyncKeys.cursorDocId(scope));
  }

  Future<void> _syncTransactions(
    CloudPartition partition,
    SyncReport report,
    DateTime cutoff, {
    required bool download,
    void Function()? onPage,
  }) async {
    await _push(partition, report, cutoff);
    if (download) await _pull(partition, report, cutoff, onPage: onPage);

    // Clean-up only after every local record of this scope has been
    // uploaded and verified: anything pending or failed blocks it entirely.
    final unsynced = await _local.countUnsynced(scope: partition.scope);
    if (unsynced.pending == 0 && unsynced.failed == 0) {
      await _cleanup(partition, report, cutoff);
    }
  }

  // ------------------------------------------------------------------ push

  Future<void> _push(
    CloudPartition partition,
    SyncReport report,
    DateTime cutoff,
  ) async {
    final attempted = <String>{};
    while (true) {
      final changes = (await _local.pendingChanges(
        limit: pushBatchSize,
        scope: partition.scope,
      )).where((c) => attempted.add('${c.runtimeType}:${c.id}')).toList();
      if (changes.isEmpty) return;
      await _pushBatch(partition, changes, report, cutoff);
    }
  }

  Future<void> _pushBatch(
    CloudPartition partition,
    List<LocalChange> changes,
    SyncReport report,
    DateTime cutoff,
  ) async {
    final scope = partition.scope;
    final remote = await _cloud.fetchByIds(partition, [
      for (final c in changes) c.id,
    ]);

    final uploads = <LocalChange, CloudTransaction>{};
    for (final change in changes) {
      final cloud = remote[change.id];
      switch (SyncConflictResolver.resolvePush(change, cloud)) {
        case PushAction.confirm:
          await _confirm(change, scope);
        case PushAction.acceptRemote:
          final outcome = await _local.applyRemote(
            cloud!,
            retentionCutoff: cutoff,
            scope: scope,
          );
          if (outcome != RemoteApplyOutcome.unchanged) {
            report.conflictsWonByCloud++;
          }
        case PushAction.upload:
          uploads[change] = switch (change) {
            LocalUpsert(:final transaction, :final category) =>
              CloudTransaction(transaction: transaction, category: category),
            LocalDeletion(:final deletedAt) => CloudTransaction(
              transaction: cloud!.transaction.copyWith(updatedAt: deletedAt),
              deleted: true,
              category: cloud.category,
            ),
          };
      }
    }
    if (uploads.isEmpty) return;

    try {
      await _cloud.upsertAll(partition, uploads.values.toList());
    } on CloudUnavailableException {
      rethrow; // Stays pending; retried when back online.
    } on CloudAccessDeniedException {
      rethrow; // Membership ended; handled by the caller.
    } catch (e) {
      await _local.markFailed(uploads.keys, 'Upload failed: $e', scope: scope);
      report.failed += uploads.length;
      rethrow;
    }

    // Verify against the server copy before marking anything synced.
    final stored = await _cloud.fetchByIds(partition, [
      for (final c in uploads.keys) c.id,
    ]);
    final unverified = <LocalChange>[];
    for (final MapEntry(key: change, value: sent) in uploads.entries) {
      final cloud = stored[change.id];
      final ok = switch (change) {
        LocalUpsert(:final transaction) => cloud?.matches(transaction) ?? false,
        LocalDeletion() =>
          cloud != null &&
              cloud.deleted &&
              cloud.updatedAtMs == sent.updatedAtMs,
      };
      if (!ok) {
        unverified.add(change);
        continue;
      }
      await _confirm(change, scope);
      if (change is LocalDeletion) {
        report.deletionsUploaded++;
      } else {
        report.uploaded++;
      }
    }
    if (unverified.isNotEmpty) {
      await _local.markFailed(
        unverified,
        'Cloud copy could not be verified',
        scope: scope,
      );
      report.failed += unverified.length;
    }
  }

  Future<void> _confirm(LocalChange change, DataScope scope) async {
    switch (change) {
      case LocalUpsert(:final transaction):
        await _local.markSynced(transaction.id, transaction.updatedAt);
      case LocalDeletion(:final id, :final deletedAt):
        await _local.clearTombstone(id, deletedAt, scope: scope);
    }
  }

  // ------------------------------------------------------------------ pull

  Future<void> _pull(
    CloudPartition partition,
    SyncReport report,
    DateTime cutoff, {
    void Function()? onPage,
  }) async {
    final scope = partition.scope;
    final micros = int.tryParse(
      await _local.getSetting(SyncKeys.cursorMicros(scope)) ?? '',
    );
    final docId = await _local.getSetting(SyncKeys.cursorDocId(scope));
    var cursor = micros == null || docId == null
        ? null
        : SyncCursor(micros, docId);
    final legacy = <CloudTransaction>[];

    while (true) {
      final page = await _cloud.fetchChangedSince(
        partition,
        cursor,
        limit: pullPageSize,
      );
      for (final remote in page) {
        if (partition.isPersonal && remote.isLegacy) legacy.add(remote);
        try {
          final outcome = await _local.applyRemote(
            remote,
            retentionCutoff: cutoff,
            scope: scope,
          );
          switch (outcome) {
            case RemoteApplyOutcome.inserted:
            case RemoteApplyOutcome.updated:
              report.downloaded++;
            case RemoteApplyOutcome.deleted:
              report.deletedFromCloud++;
            case RemoteApplyOutcome.unchanged:
            case RemoteApplyOutcome.skippedArchived:
              break;
          }
        } catch (e) {
          // The document stays in the cloud and appears in cloud history.
          debugPrint('Could not apply cloud transaction ${remote.id}: $e');
        }
        final position = remote.position;
        if (position != null && (cursor == null || position.isAfter(cursor))) {
          cursor = position;
        }
      }
      if (cursor != null) {
        await _local.setSetting(
          SyncKeys.cursorMicros(scope),
          cursor.serverMicros.toString(),
        );
        await _local.setSetting(SyncKeys.cursorDocId(scope), cursor.docId);
      }
      onPage?.call();
      if (page.length < pullPageSize) break;
    }

    // Personal documents written before households existed get their
    // scope / owner fields (content and updatedAt are left unchanged).
    if (legacy.isNotEmpty) {
      await _cloud.backfillOwnership(partition, legacy);
    }
  }

  // --------------------------------------------------------------- cleanup

  Future<void> _cleanup(
    CloudPartition partition,
    SyncReport report,
    DateTime cutoff,
  ) async {
    const pageSize = 200;
    while (true) {
      final candidates = await _local.archiveCandidates(
        cutoff,
        limit: pageSize,
        scope: partition.scope,
      );
      if (candidates.isEmpty) return;

      final cloud = await _cloud.fetchByIds(partition, [
        for (final t in candidates) t.id,
      ]);
      final verified = <TransactionModel>[];
      final mismatched = <TransactionModel>[];
      for (final t in candidates) {
        (cloud[t.id]?.matches(t) ?? false ? verified : mismatched).add(t);
      }
      // A row that says "synced" but has no matching cloud copy is never
      // removed; it is queued for upload again instead.
      if (mismatched.isNotEmpty) await _local.requeue(mismatched);
      report.archivedLocally += await _local.removeArchived(verified);

      if (candidates.length < pageSize || verified.isEmpty) return;
    }
  }

  // ---------------------------------------------- budgets and categories

  Future<void> _syncSettings(
    CloudPartition partition,
    SyncReport report, {
    required bool download,
  }) async {
    final settings = _settings;
    final records = _records;
    if (settings == null || records == null) return;
    final scope = partition.scope;

    // Categories first, so budgets can refer to them.
    for (final kind in [CloudRecordKind.categories, CloudRecordKind.budgets]) {
      try {
        final pending = await settings.pendingRecords(scope, kind);
        if (pending.isNotEmpty) {
          await records.upsertAll(partition, kind, [
            for (final p in pending) p.record,
          ]);
          // The commit has been confirmed by the server.
          await settings.confirmUploaded(scope, pending);
          report.settingsUploaded += pending.length;
        }
        if (!download) continue;

        final remote = await records.fetchAll(partition, kind);
        for (final r in remote) {
          if (await settings.applyRemote(scope, kind, r)) {
            if (kind == CloudRecordKind.budgets) {
              report.budgetsDownloaded++;
            } else {
              report.categoriesDownloaded++;
            }
          }
        }

        if (kind == CloudRecordKind.categories && !partition.isPersonal) {
          final labels = await settings.householdCategoryUploads(scope, {
            for (final r in remote) r.id: r.updatedAtMs,
          });
          if (labels.isNotEmpty) {
            await records.upsertAll(partition, kind, labels);
          }
        }
      } on CloudUnavailableException {
        rethrow;
      } on CloudAccessDeniedException {
        rethrow;
      } catch (e, stack) {
        // Unsynced rows stay pending and are retried on the next cycle.
        debugPrint(
          'Syncing ${kind.name} of ${partition.key} failed: $e\n$stack',
        );
        report.failed++;
      }
    }
  }

  // --------------------------------------------------------------- history

  /// Loads transactions of [partition] older than the local retention
  /// window from the cloud, matching [filter]. Records stored on this device
  /// or deleted on it are excluded, so the result can be shown next to
  /// local records without duplicates.
  Future<HistoryResult> loadHistory(
    CloudPartition partition, {
    required TransactionFilter filter,
    required Map<String, String> categoryNames,
    Object? cursor,
    int pageSize = 50,
    int maxPages = 4,
  }) async {
    if (await isRestorePending()) {
      // Reset App: older cloud records stay hidden until the user restores.
      return const HistoryResult(
        transactions: [],
        cursor: null,
        hasMore: false,
        categoriesAdded: false,
      );
    }
    final cutoff = await retentionCutoff();
    final end = filter.end;
    final before = end != null && end.isBefore(cutoff) ? end : cutoff;
    if (filter.start != null && !filter.start!.isBefore(before)) {
      return const HistoryResult(
        transactions: [],
        cursor: null,
        hasMore: false,
        categoriesAdded: false,
      );
    }

    final found = <TransactionModel>[];
    var categoriesAdded = false;
    var hasMore = true;
    for (var i = 0; i < maxPages && hasMore && found.isEmpty; i++) {
      final page = await _cloud.fetchHistory(
        partition,
        before: before,
        start: filter.start,
        cursor: cursor,
        limit: pageSize,
      );
      cursor = page.cursor;
      hasMore = page.hasMore;

      final live = page.records.where((r) => !r.deleted).toList();
      final ids = [for (final r in live) r.id];
      final localIds = (await _local.getRecords(ids)).keys.toSet();
      final deletedIds = (await _local.getTombstones(
        ids,
        scope: partition.scope,
      )).keys.toSet();

      for (final record in live) {
        if (localIds.contains(record.id) || deletedIds.contains(record.id)) {
          continue;
        }
        var t = record.transaction;
        var categoryName = categoryNames[t.categoryId];
        if (categoryName == null) {
          final localId = await _local.ensureCategory(
            t.categoryId,
            record.category,
            householdId: partition.householdId,
          );
          if (localId != null) {
            categoriesAdded = true;
            t = t.copyWith(categoryId: localId);
            categoryName = record.category?.name;
          }
        }
        if (_matches(t, filter, categoryName ?? '')) found.add(t);
      }
    }
    return HistoryResult(
      transactions: found,
      cursor: cursor,
      hasMore: hasMore,
      categoriesAdded: categoriesAdded,
    );
  }

  /// Removes this device's cached copy of [householdId]'s data after the
  /// user lost access to it (see [LocalSyncStore.releaseHousehold]).
  Future<HouseholdReleaseResult> releaseHousehold(
    String householdId, {
    required String uid,
  }) => _local.releaseHousehold(householdId, uid: uid);

  /// Same rules as the SQLite search in `getTransactions`.
  static bool _matches(
    TransactionModel t,
    TransactionFilter filter,
    String categoryName,
  ) {
    if (filter.type != null && t.type != filter.type) return false;
    if (filter.categoryIds.isNotEmpty &&
        !filter.categoryIds.contains(t.categoryId)) {
      return false;
    }
    if (filter.start != null && t.date.isBefore(filter.start!)) return false;
    if (filter.end != null && !t.date.isBefore(filter.end!)) return false;
    final q = filter.query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return t.note.toLowerCase().contains(q) ||
        categoryName.toLowerCase().contains(q) ||
        t.paymentMethod.name.toLowerCase().contains(q);
  }
}
