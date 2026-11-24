import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/core/database/app_database.dart';

/// What to do with a cloud document received during a pull.
enum PullAction {
  /// The local copy (or local deletion) is newer; it will be uploaded.
  keepLocal,

  /// Local and cloud hold the same version; only mark it synced.
  confirmLocal,

  /// Store the cloud version locally (insert or overwrite).
  writeRemote,

  /// The cloud deleted it and that deletion is newer: remove the local row.
  deleteLocal,

  /// The local deletion already matches the cloud.
  clearTombstone,

  /// Older than the retention window and not on this device: leave it in
  /// the cloud only.
  skipArchived,
}

/// What to do with a local change before uploading it.
enum PushAction {
  /// The local version is newer than the cloud (or the cloud has none).
  upload,

  /// The cloud already holds exactly this version.
  confirm,

  /// The cloud has a newer (or equally new) different version: it wins and
  /// is applied locally instead.
  acceptRemote,
}

/// Last-writer-wins conflict resolution by `updatedAt`.
///
/// Every transaction has a stable ID and an `updatedAt` timestamp that is
/// bumped on every edit, deletion or undo. When both sides changed, the
/// version with the later `updatedAt` wins. Exact ties go to the cloud so
/// that every device converges on the same result.
class SyncConflictResolver {
  SyncConflictResolver._();

  static bool remoteWins(DateTime localUpdatedAt, DateTime remoteUpdatedAt) =>
      remoteUpdatedAt.millisecondsSinceEpoch >=
      localUpdatedAt.millisecondsSinceEpoch;

  static PushAction resolvePush(LocalChange change, CloudTransaction? remote) {
    switch (change) {
      case LocalUpsert(:final transaction):
        if (remote == null) return PushAction.upload;
        if (remote.matches(transaction)) return PushAction.confirm;
        return remoteWins(transaction.updatedAt, remote.updatedAt)
            ? PushAction.acceptRemote
            : PushAction.upload;
      case LocalDeletion(:final deletedAt):
        // Never reached the cloud, or already deleted there: nothing to do.
        if (remote == null || remote.deleted) return PushAction.confirm;
        return remoteWins(deletedAt, remote.updatedAt)
            ? PushAction.acceptRemote
            : PushAction.upload;
    }
  }

  static PullAction resolvePull({
    required CloudTransaction remote,
    required LocalSyncRecord? local,
    required DateTime? tombstoneDeletedAt,
    required DateTime retentionCutoff,
  }) {
    final isArchived = remote.transaction.date.isBefore(retentionCutoff);

    if (remote.deleted) {
      if (local != null &&
          local.status != RecordSyncStatus.synced &&
          !remoteWins(local.transaction.updatedAt, remote.updatedAt)) {
        return PullAction.keepLocal; // A newer local edit restores it.
      }
      if (local == null) {
        return tombstoneDeletedAt == null
            ? PullAction.keepLocal
            : PullAction.clearTombstone;
      }
      return PullAction.deleteLocal;
    }

    if (tombstoneDeletedAt != null) {
      if (!remoteWins(tombstoneDeletedAt, remote.updatedAt)) {
        return PullAction.keepLocal; // The local deletion is newer.
      }
      // Edited elsewhere after it was deleted here: the edit wins.
      if (local == null && isArchived) return PullAction.skipArchived;
      return PullAction.writeRemote;
    }

    if (local == null) {
      return isArchived ? PullAction.skipArchived : PullAction.writeRemote;
    }
    if (contentEquals(local.transaction, remote.transaction)) {
      return local.isVerifiedInCloud
          ? PullAction.keepLocal
          : PullAction.confirmLocal;
    }
    return remoteWins(local.transaction.updatedAt, remote.updatedAt)
        ? PullAction.writeRemote
        : PullAction.keepLocal;
  }
}
