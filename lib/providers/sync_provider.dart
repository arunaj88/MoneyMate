import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:money_mate/core/services/connectivity_monitor.dart';
import 'package:money_mate/core/services/household_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';

enum SyncPhase {
  /// Cloud sync is not configured in this build (e.g. tests).
  unavailable,
  signedOut,
  idle,
  syncing,
  offline,
  accountMismatch,
  error,
}

/// The five states shown to the user.
enum SyncStatusLabel {
  synced('Synced'),
  syncing('Syncing'),
  offline('Offline'),
  pending('Pending'),
  failed('Failed');

  const SyncStatusLabel(this.label);
  final String label;
}

/// Runs cloud sync automatically and exposes its state to the UI.
///
/// A sync cycle starts when the user signs in, when connectivity returns,
/// shortly after local transaction or budget changes, when the user joins
/// a household, when the app is resumed and periodically while it is open.
/// Only one cycle runs at a time; a request during a cycle runs one more
/// afterwards. SQLite stays the source of truth for the UI; sync results
/// are applied there and the transaction list reloaded.
///
/// When the household refuses access, the membership is confirmed with the
/// server; once confirmed, the household's cached data is released from this
/// device (personal data is never touched).
class SyncProvider extends ChangeNotifier with WidgetsBindingObserver {
  SyncProvider({
    TransactionSyncService? service,
    ConnectivityMonitor? connectivity,
    this.changeDebounce = const Duration(seconds: 3),
    this.periodicInterval = const Duration(minutes: 15),
  }) : _service = service,
       _connectivity = connectivity {
    if (_service == null) {
      _phase = SyncPhase.unavailable;
      return;
    }
    WidgetsBinding.instance.addObserver(this);
    _connectivitySub = _connectivity?.onlineChanges.listen(_onOnlineChanged);
    unawaited(_initOnline());
  }

  final TransactionSyncService? _service;
  final ConnectivityMonitor? _connectivity;
  final Duration changeDebounce;
  final Duration periodicInterval;

  StreamSubscription<bool>? _connectivitySub;
  Timer? _debounce;
  Timer? _periodic;
  bool _disposed = false;
  bool _online = true;
  bool _syncAgain = false;
  Future<void>? _inFlight;
  bool _paused = false;

  String? _uid;
  String? _householdId;
  TransactionProvider? _transactions;
  CategoryProvider? _categories;
  HouseholdProvider? _household;
  int? _seenDataVersion;
  int? _seenBudgetVersion;
  int? _seenSavingsVersion;
  int? _seenSavingsRequest;
  int? _seenReleaseToken;
  HouseholdReleaseResult? _lastRelease;

  SyncPhase _phase = SyncPhase.signedOut;
  DateTime? _lastSyncedAt;
  int _pendingCount = 0;
  int _failedCount = 0;
  int _retentionDays = 0;
  String? _message;
  SyncReport? _lastReport;

  SyncPhase get phase => _phase;

  /// True while sync is held (e.g. during a data reset).
  bool get isPaused => _paused;
  bool get isSyncing => _phase == SyncPhase.syncing;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// Local changes (including deletions) not yet confirmed in the cloud.
  int get pendingCount => _pendingCount;
  int get failedCount => _failedCount;

  /// Days of transactions kept on this device (0 until loaded).
  int get retentionDays => _retentionDays;
  String? get message => _message;
  SyncReport? get lastReport => _lastReport;

  /// What happened when household access last ended on this device.
  HouseholdReleaseResult? get lastRelease => _lastRelease;

  /// Synced / Syncing / Offline / Pending / Failed.
  SyncStatusLabel get statusLabel {
    switch (_phase) {
      case SyncPhase.syncing:
        return SyncStatusLabel.syncing;
      case SyncPhase.offline:
      case SyncPhase.signedOut:
      case SyncPhase.unavailable:
        return SyncStatusLabel.offline;
      case SyncPhase.error:
      case SyncPhase.accountMismatch:
        return SyncStatusLabel.failed;
      case SyncPhase.idle:
        if (_failedCount > 0) return SyncStatusLabel.failed;
        if (_pendingCount > 0) return SyncStatusLabel.pending;
        return SyncStatusLabel.synced;
    }
  }

  void updateDependencies(
    AuthProvider auth,
    CategoryProvider categories,
    TransactionProvider transactions, {
    HouseholdProvider? household,
    BudgetProvider? budgets,
    SavingsProvider? savings,
  }) {
    _categories = categories;
    _transactions = transactions;
    _household = household;
    if (_service == null) return;

    final uid = auth.isAuthenticated ? auth.user?.uid : null;

    // Household access ended (confirmed by the server, or the user left):
    // release the cached shared data before anything else.
    if (household != null && household.releaseToken != _seenReleaseToken) {
      final first = _seenReleaseToken == null;
      _seenReleaseToken = household.releaseToken;
      final released = household.releasedHouseholdId;
      final releasingUid = uid ?? _uid;
      if (!first && released != null && releasingUid != null) {
        Future.microtask(() => _release(released, releasingUid));
      }
    }

    final householdId = household?.householdId;
    if (householdId != _householdId) {
      _householdId = householdId;
      // A new or restored membership: fetch the shared data now.
      if (householdId != null && uid != null && uid == _uid) {
        Future.microtask(syncNow);
      }
    }

    final budgetVersion = budgets?.localChangeVersion;
    if (budgetVersion != _seenBudgetVersion) {
      final first = _seenBudgetVersion == null;
      _seenBudgetVersion = budgetVersion;
      if (!first && _uid != null && uid == _uid) {
        _debounce?.cancel();
        _debounce = Timer(changeDebounce, syncNow);
      }
    }

    final savingsRequest = savings?.syncRequestVersion;
    if (savingsRequest != _seenSavingsRequest) {
      final first = _seenSavingsRequest == null;
      _seenSavingsRequest = savingsRequest;
      // E.g. just joined a shared goal: download it now.
      if (!first && _uid != null && uid == _uid) Future.microtask(syncNow);
    }

    final savingsVersion = savings?.localChangeVersion;
    if (savingsVersion != _seenSavingsVersion) {
      final first = _seenSavingsVersion == null;
      _seenSavingsVersion = savingsVersion;
      if (!first && _uid != null && uid == _uid) {
        _debounce?.cancel();
        _debounce = Timer(changeDebounce, syncNow);
      }
    }

    if (uid != _uid) {
      _uid = uid;
      _seenDataVersion = transactions.dataVersion;
      if (uid == null) {
        _debounce?.cancel();
        _periodic?.cancel();
        _setPhase(SyncPhase.signedOut);
      } else {
        _periodic?.cancel();
        _periodic = Timer.periodic(periodicInterval, (_) => syncNow());
        // Deferred: this runs while the provider tree is building.
        Future.microtask(syncNow);
      }
      return;
    }

    if (transactions.dataVersion != _seenDataVersion) {
      _seenDataVersion = transactions.dataVersion;
      if (_uid != null) {
        _debounce?.cancel();
        _debounce = Timer(changeDebounce, syncNow);
      }
    }
  }

  Future<void> _initOnline() async {
    try {
      _online = await _connectivity?.isOnline() ?? true;
    } catch (_) {
      _online = true;
    }
    await _refreshCounts();
    _notify();
  }

  void _onOnlineChanged(bool online) {
    _online = online;
    if (online) {
      unawaited(syncNow());
    } else if (_uid != null && !isSyncing) {
      _setPhase(SyncPhase.offline);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncNow());
  }

  /// Stops automatic and manual sync until [resume], after the cycle in
  /// progress (if any) has finished. Used while personal data is reset, so
  /// nothing is uploaded or downloaded half-way.
  Future<void> pause() async {
    _paused = true;
    _syncAgain = false;
    _debounce?.cancel();
    final running = _inFlight;
    if (running != null) await running;
  }

  /// Allows sync again. With [afterReset], the stale status of the old data
  /// (last sync time, counts, messages) is cleared first. Then a cycle runs
  /// straight away.
  Future<void> resume({bool afterReset = false}) async {
    _paused = false;
    if (afterReset) {
      _lastSyncedAt = null;
      _lastReport = null;
      _message = null;
      final transactions = _transactions;
      if (transactions != null) _seenDataVersion = transactions.dataVersion;
      await _refreshCounts();
      if (_phase != SyncPhase.unavailable &&
          _phase != SyncPhase.signedOut &&
          _phase != SyncPhase.accountMismatch) {
        _phase = SyncPhase.idle;
      }
      _notify();
    }
    await syncNow();
  }

  /// Runs a sync cycle now (or once more after the current one finishes).
  Future<void> syncNow() {
    if (_disposed || _paused || _service == null || _uid == null) {
      return Future.value();
    }
    _debounce?.cancel();
    if (_inFlight != null) {
      _syncAgain = true;
      return _inFlight!;
    }
    return _inFlight = _loop().whenComplete(() => _inFlight = null);
  }

  Future<void> _loop() async {
    do {
      _syncAgain = false;
      await _syncOnce();
    } while (_syncAgain && !_disposed && !_paused && _uid != null);
  }

  Future<void> _syncOnce() async {
    final service = _service!;
    final uid = _uid!;
    if (!_online) {
      await _refreshCounts();
      _setPhase(SyncPhase.offline);
      return;
    }
    _message = null;
    _setPhase(SyncPhase.syncing);

    final result = await service.synchronize(uid, householdId: _householdId);
    if (_disposed) return;
    _lastReport = result.report;
    for (final denied in result.report.householdsDenied) {
      // Only released once the server confirms the membership ended.
      unawaited(_household?.confirmAccess(denied));
    }
    if (result.report.localDataChanged) {
      final transactions = _transactions;
      if (transactions != null) {
        await _categories?.load();
        final reload = transactions.reloadAfterExternalChange();
        // Our own reload must not trigger another sync.
        _seenDataVersion = transactions.dataVersion;
        await reload;
      }
    }
    await _refreshCounts();

    switch (result.outcome) {
      case SyncOutcome.completed:
        _setPhase(SyncPhase.idle);
      case SyncOutcome.offline:
        _message =
            'Waiting for a connection. Changes are saved on this device.';
        _setPhase(SyncPhase.offline);
      case SyncOutcome.accountMismatch:
        _message =
            'The data on this device belongs to another account, so it is '
            'not synced with this one.';
        _setPhase(SyncPhase.accountMismatch);
      case SyncOutcome.failed:
        _message = 'Sync failed. Unsynced changes are kept and retried.';
        _setPhase(SyncPhase.error);
    }
  }

  /// Uploads pending shared changes of [householdId] before the user's
  /// access ends (leaving the household). Throws a [HouseholdException]
  /// explaining why when some could not be uploaded.
  Future<void> flushHousehold(String householdId) async {
    await syncNow();
    final unsynced = await unsyncedIn(DataScope.household(householdId));
    final count = unsynced.pending + unsynced.failed;
    if (count == 0) return;
    throw HouseholdException(
      '$count shared change(s) have not reached the household yet. '
      'Connect to the internet and try again.',
    );
  }

  /// Unsynced changes in [scope] (e.g. before leaving a household).
  Future<({int pending, int failed})> unsyncedIn(DataScope scope) async {
    final service = _service;
    if (service == null) return (pending: 0, failed: 0);
    return service.countUnsynced(scope: scope);
  }

  Future<void> _release(String householdId, String uid) async {
    final service = _service;
    if (service == null || _disposed) return;
    try {
      _lastRelease = await service.releaseHousehold(householdId, uid: uid);
      await _categories?.load();
      final transactions = _transactions;
      if (transactions != null) {
        final reload = transactions.reloadAfterExternalChange();
        _seenDataVersion = transactions.dataVersion;
        await reload;
      }
      await _refreshCounts();
      _notify();
    } catch (e, stack) {
      debugPrint('Releasing household data failed: $e\n$stack');
    }
  }

  Future<void> _refreshCounts() async {
    final service = _service;
    if (service == null || _disposed) return;
    try {
      final counts = await service.countUnsynced();
      _pendingCount = counts.pending;
      _failedCount = counts.failed;
      _lastSyncedAt = await service.lastSyncedAt();
      _retentionDays = (await service.retentionPolicy()).days;
    } catch (e) {
      debugPrint('Could not read sync status: $e');
    }
  }

  void _setPhase(SyncPhase phase) {
    _phase = phase;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _periodic?.cancel();
    _connectivitySub?.cancel();
    if (_service != null) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
