import 'package:flutter/foundation.dart';

import 'package:money_mate/core/services/data_reset_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';

enum ResetStage {
  idle,
  preparing,
  device,
  downloading,
  refreshing;

  String get message => switch (this) {
    ResetStage.idle => '',
    ResetStage.preparing => 'Pausing sync…',
    ResetStage.device => 'Clearing this device…',
    ResetStage.downloading => 'Downloading from the cloud…',
    ResetStage.refreshing => 'Getting things ready…',
  };
}

/// The providers a reset or restore uses and refreshes.
class ResetTargets {
  const ResetTargets({
    required this.auth,
    required this.household,
    required this.sync,
    required this.scope,
    required this.categories,
    required this.transactions,
    required this.budgets,
  });

  final AuthProvider auth;
  final HouseholdProvider household;
  final SyncProvider sync;
  final TransactionScopeProvider scope;
  final CategoryProvider categories;
  final TransactionProvider transactions;
  final BudgetProvider budgets;
}

/// Runs Reset App (local data only) and Restore My Cloud Data.
///
/// **Reset** clears this device so the app looks freshly installed, and
/// never touches the cloud: no Firestore document is deleted, changed or
/// overwritten, households and memberships stay as they are, and the user
/// stays signed in. Steps:
/// 1. Sync is paused (waiting for a running cycle to finish).
/// 2. One SQLite transaction clears every user-specific table and marks a
///    restore as pending. If it fails, nothing changed.
/// 3. Cached household details are forgotten, the view returns to Personal
///    and every screen reloads (empty).
/// 4. Sync resumes, but downloads nothing while the restore is pending:
///    new records made on this device are still backed up.
///
/// **Restore** downloads the user's cloud data again (household data only
/// while they are still an active member) and ends the pending state only
/// when it fully succeeded, so an interrupted restore can be retried.
class ResetProvider extends ChangeNotifier {
  ResetProvider(this._service) {
    if (_service != null) _loadPending();
  }

  final DataResetService? _service;

  ResetStage _stage = ResetStage.idle;
  bool _busy = false;
  bool _restorePending = false;
  RestoreProgress? _progress;
  String? _error;
  bool _disposed = false;

  /// False in builds without cloud services.
  bool get isAvailable => _service != null;
  ResetStage get stage => _stage;

  /// True from the moment a reset or restore starts until it has fully
  /// finished (sync resumed included).
  bool get isRunning => _busy;

  /// True after a reset until the user's cloud data has been restored.
  bool get restorePending => _restorePending;

  /// Latest progress of a running restore.
  RestoreProgress? get restoreProgress => _progress;

  /// Why the last attempt failed (null after a success).
  String? get error => _error;

  Future<void> _loadPending() async {
    try {
      final pending = await _service!.isRestorePending();
      if (pending != _restorePending) {
        _restorePending = pending;
        _notify();
      }
    } catch (e) {
      debugPrint('Could not read restore state: $e');
    }
  }

  /// Clears this device's data. Returns true only when it succeeded;
  /// otherwise [error] explains what happened (nothing was changed) and
  /// the reset can be retried. Calls made while busy are ignored (false).
  Future<bool> reset(ResetTargets targets) async {
    final service = _service;
    if (service == null || _busy) return false;
    _busy = true;
    _error = null;
    var succeeded = false;
    try {
      _setStage(ResetStage.preparing);
      await targets.sync.pause();
      try {
        _setStage(ResetStage.device);
        try {
          await service.clearDevice();
        } catch (e, stack) {
          debugPrint('Reset (device) failed: $e\n$stack');
          return _fail(
            'The data on this device could not be cleared. Nothing was '
            'changed. Please try again.',
          );
        }
        _restorePending = true;
        succeeded = true;

        _setStage(ResetStage.refreshing);
        await targets.household.clearDeviceCache();
        await targets.scope.setView(ViewScope.personal);
        await targets.categories.load();
        await targets.transactions.reloadAfterReset();
        await targets.budgets.refresh();
        return true;
      } finally {
        // Sync again with a clean status: uploads only, no downloads.
        await targets.sync.resume(afterReset: succeeded);
      }
    } finally {
      _busy = false;
      _setStage(ResetStage.idle);
    }
  }

  /// Downloads the signed-in user's cloud data into this device. Returns
  /// true only when everything was restored; otherwise [error] explains
  /// what happened and a retry is safe (nothing is duplicated).
  Future<bool> restore(ResetTargets targets) async {
    final service = _service;
    if (service == null || _busy) return false;
    final uid = targets.auth.isAuthenticated ? targets.auth.user?.uid : null;
    if (uid == null) {
      _error = 'Sign in to restore your cloud data.';
      return false;
    }
    _busy = true;
    _error = null;
    _progress = null;
    try {
      _setStage(ResetStage.preparing);
      await targets.sync.pause();
      try {
        _setStage(ResetStage.downloading);
        final SyncResult result;
        try {
          result = await service.restoreCloudData(
            uid,
            householdId: targets.household.householdId,
            onProgress: (p) {
              _progress = p;
              _notify();
            },
          );
        } catch (e, stack) {
          debugPrint('Restore failed: $e\n$stack');
          return _fail(_retryMessage);
        }

        _setStage(ResetStage.refreshing);
        for (final denied in result.report.householdsDenied) {
          // Not a member any more: its data was not downloaded.
          await targets.household.confirmAccess(denied);
        }
        await targets.categories.load();
        await targets.transactions.reloadAfterExternalChange();
        await targets.budgets.refresh();
        await _loadPending();

        switch (result.outcome) {
          case SyncOutcome.completed:
            return true;
          case SyncOutcome.offline:
            return _fail(
              'You are offline. Connect to the internet and try again. '
              'Your cloud data is safe.',
            );
          case SyncOutcome.accountMismatch:
            return _fail(
              'The data on this device belongs to another account, so it '
              'cannot be restored here.',
            );
          case SyncOutcome.failed:
            return _fail(_retryMessage);
        }
      } finally {
        await targets.sync.resume();
      }
    } finally {
      _busy = false;
      _progress = null;
      _setStage(ResetStage.idle);
    }
  }

  static const _retryMessage =
      'Your data could not be restored completely. Your cloud data is safe; '
      'tap Retry to try again (nothing is duplicated).';

  bool _fail(String message) {
    _error = message;
    return false;
  }

  void _setStage(ResetStage stage) {
    _stage = stage;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
