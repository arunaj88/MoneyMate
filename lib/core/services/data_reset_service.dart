import 'package:money_mate/core/services/transaction_sync_service.dart';

/// Reset App and Restore My Cloud Data.
///
/// Reset App only clears this device: it never deletes, changes or
/// overwrites anything in the cloud, and the sign-in account is kept. The
/// user's cloud data stays where it is until they restore it.
abstract class DataResetService {
  /// Clears every user-specific record on this device (pending uploads
  /// included) and marks a restore as pending, so nothing is downloaded
  /// again until [restoreCloudData]. Atomic: on failure nothing changed.
  Future<void> clearDevice();

  /// True after [clearDevice] until a restore succeeded (kept across app
  /// restarts).
  Future<bool> isRestorePending();

  /// Downloads the user's personal cloud data and, when they are still an
  /// active member, [householdId]'s shared data into this device. Safe to
  /// retry: records are matched by their cloud IDs.
  Future<SyncResult> restoreCloudData(
    String uid, {
    String? householdId,
    RestoreProgressCallback? onProgress,
  });
}

/// [DataResetService] backed by the SQLite sync store and cloud sync.
class SyncDataResetService implements DataResetService {
  SyncDataResetService(this._sync);

  final TransactionSyncService _sync;

  @override
  Future<void> clearDevice() => _sync.resetLocalData();

  @override
  Future<bool> isRestorePending() => _sync.isRestorePending();

  @override
  Future<SyncResult> restoreCloudData(
    String uid, {
    String? householdId,
    RestoreProgressCallback? onProgress,
  }) => _sync.restoreFromCloud(
    uid,
    householdId: householdId,
    onProgress: onProgress,
  );
}
