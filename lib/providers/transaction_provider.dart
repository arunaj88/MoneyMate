import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/services/cloud_history_loader.dart';
import '../core/services/cloud_transaction_store.dart';
import '../core/services/transaction_calculator.dart';
import '../models/category_model.dart';
import '../models/scope_models.dart';
import '../models/transaction_model.dart';
import '../repositories/transaction_repository.dart';
import 'category_provider.dart';
import 'transaction_scope_provider.dart';

/// State of loading transactions older than the local retention window.
enum CloudHistoryStatus { idle, loading, loaded, exhausted, offline, error }

/// Holds the filtered transaction list and performs transaction CRUD.
///
/// The list combines local transactions with older ones loaded on request
/// from the cloud ([loadCloudHistory]). Cloud records are only shown if no
/// local record has the same ID, so nothing appears twice.
///
/// [dataVersion] increases after every change to stored transactions so
/// that dependent providers (dashboard, budget, reports) know to refresh.
///
/// The list follows the app-wide view scope (personal or household)
/// from [TransactionScopeProvider]; [scopeFilter] exposes it to the
/// dashboard and reports so they show the same set of transactions.
class TransactionProvider extends ChangeNotifier {
  TransactionProvider(
    this._repository, {
    Uuid? uuid,
    TransactionHistorySource? history,
  }) : _uuid = uuid ?? const Uuid(),
       _history = history;

  final TransactionRepository _repository;
  final Uuid _uuid;
  final TransactionHistorySource? _history;

  List<TransactionModel> _local = const [];
  List<TransactionModel> _cloud = const [];
  Set<String> _cloudIds = const {};
  Object? _historyCursor;
  CloudHistoryStatus _historyStatus = CloudHistoryStatus.idle;
  String? _historyMessage;
  int _historyToken = 0;
  CategoryProvider? _categories;

  List<TransactionModel> _transactions = const [];
  List<MapEntry<DateTime, List<TransactionModel>>> _grouped = const [];
  TransactionFilter _filter = const TransactionFilter();
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;
  int _dataVersion = 0;
  int _categoryVersion = -1;
  int _loadToken = 0;
  String? _householdId;

  List<TransactionModel> get transactions => _transactions;

  /// Filtered transactions grouped by day, newest first.
  List<MapEntry<DateTime, List<TransactionModel>>> get groupedByDay => _grouped;
  TransactionFilter get filter => _filter;

  /// Personal or household records currently shown.
  ScopeFilter get scopeFilter => _filter.scope;

  /// The household the user belongs to (whatever the current view).
  String? get householdId => _householdId;
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  String? get error => _error;
  int get dataVersion => _dataVersion;

  /// Whether older transactions can be requested from the cloud.
  bool get canLoadCloudHistory => _history?.isAvailable ?? false;
  CloudHistoryStatus get historyStatus => _historyStatus;

  /// Explanation for the offline / error history states.
  String? get historyMessage => _historyMessage;

  /// True for a transaction shown from the cloud that is not on this device.
  bool isCloudOnly(String id) => _cloudIds.contains(id);

  int get filteredIncomeMinor =>
      TransactionCalculator.totalIncome(_transactions);
  int get filteredExpenseMinor =>
      TransactionCalculator.totalExpense(_transactions);

  /// Called by the ProxyProvider when categories change. Category edits and
  /// deletions can reassign transactions, so treat them as a data change.
  void onCategoriesChanged(CategoryProvider categories) {
    _categories = categories;
    if (categories.version == _categoryVersion) return;
    final isFirst = _categoryVersion == -1;
    _categoryVersion = categories.version;
    if (!isFirst && _hasLoaded) {
      _dataVersion++;
      // Defer: this runs during the provider tree's build phase.
      Future.microtask(load);
    }
  }

  /// Called by the ProxyProvider when the view scope or household changes.
  void onScopeChanged(TransactionScopeProvider scope) {
    _householdId = scope.householdId;
    final next = scope.filter;
    if (next == _filter.scope) return;
    _filter = _filter.copyWith(scope: next);
    _resetCloudHistory();
    if (_hasLoaded || _isLoading) {
      _dataVersion++;
      // Defer: this runs during the provider tree's build phase.
      Future.microtask(load);
    }
  }

  Future<void> load() async {
    final token = ++_loadToken;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final result = await _repository.getTransactions(filter: _filter);
      if (token != _loadToken) return; // A newer load superseded this one.
      _local = result;
      _merge();
      _hasLoaded = true;
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Could not load transactions. Please try again.';
      debugPrint('TransactionProvider.load failed: $e');
    } finally {
      if (token == _loadToken) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Local records first; cloud records whose ID is not stored locally.
  void _merge() {
    final localIds = {for (final t in _local) t.id};
    _cloud = [
      for (final t in _cloud)
        if (!localIds.contains(t.id)) t,
    ];
    _cloudIds = {for (final t in _cloud) t.id};
    final merged = [..._local, ..._cloud];
    if (_cloud.isNotEmpty) {
      merged.sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : b.createdAt.compareTo(a.createdAt);
      });
    }
    _transactions = List.unmodifiable(merged);
    _grouped = TransactionCalculator.groupByDay(merged);
  }

  Future<void> setFilter(TransactionFilter filter) async {
    // The scope is app-wide; screens only change the other criteria.
    _filter = filter.copyWith(scope: _filter.scope);
    await _reloadForNewFilter();
  }

  Future<void> setQuery(String query) async {
    if (query == _filter.query) return;
    _filter = _filter.copyWith(query: query);
    await _reloadForNewFilter();
  }

  Future<void> clearFilters() async {
    _filter = TransactionFilter(query: _filter.query, scope: _filter.scope);
    await _reloadForNewFilter();
  }

  /// Cloud results were loaded for the old filter, so they are discarded.
  /// When the new date filter reaches beyond the local window, the first
  /// page of cloud history is loaded automatically.
  Future<void> _reloadForNewFilter() async {
    _resetCloudHistory();
    await load();
    final start = _filter.start;
    if (start != null && canLoadCloudHistory) {
      try {
        if (start.isBefore(await _history!.localCutoff())) {
          await loadCloudHistory();
        }
      } catch (e) {
        debugPrint('Could not check the retention window: $e');
      }
    }
  }

  void _resetCloudHistory() {
    _historyToken++;
    _cloud = const [];
    _cloudIds = const {};
    _historyCursor = null;
    _historyStatus = CloudHistoryStatus.idle;
    _historyMessage = null;
  }

  /// Loads the next page of transactions older than the local retention
  /// window from the cloud, using the current filter.
  Future<void> loadCloudHistory() async {
    final history = _history;
    if (history == null || !history.isAvailable) return;
    if (_historyStatus == CloudHistoryStatus.loading ||
        _historyStatus == CloudHistoryStatus.exhausted) {
      return;
    }
    final token = ++_historyToken;
    _historyStatus = CloudHistoryStatus.loading;
    _historyMessage = null;
    notifyListeners();
    try {
      final result = await history.loadOlder(
        filter: _filter,
        categoryNames: {
          for (final c in _categories?.byId.values ?? const <CategoryModel>[])
            c.id: c.name,
        },
        cursor: _historyCursor,
      );
      if (token != _historyToken) return;
      _historyCursor = result.cursor;
      final known = {..._cloudIds, for (final t in _local) t.id};
      _cloud = [
        ..._cloud,
        for (final t in result.transactions)
          if (known.add(t.id)) t,
      ];
      _merge();
      _historyStatus = result.hasMore
          ? CloudHistoryStatus.loaded
          : CloudHistoryStatus.exhausted;
      if (result.categoriesAdded) unawaited(_categories?.load());
    } on CloudUnavailableException {
      if (token != _historyToken) return;
      _historyStatus = CloudHistoryStatus.offline;
      _historyMessage =
          'You are offline. Connect to the internet to see older '
          'transactions.';
    } on CloudHistoryUnavailableException catch (e) {
      if (token != _historyToken) return;
      _historyStatus = CloudHistoryStatus.error;
      _historyMessage = e.message;
    } catch (e) {
      if (token != _historyToken) return;
      debugPrint('Loading cloud history failed: $e');
      _historyStatus = CloudHistoryStatus.error;
      _historyMessage = 'Could not load older transactions. Please try again.';
    } finally {
      if (token == _historyToken) notifyListeners();
    }
  }

  /// Validates and stores a new transaction.
  ///
  /// A shared transaction needs the user's household ([householdId]) and
  /// records its creator ([createdBy], [createdByName]).
  Future<TransactionModel> addTransaction({
    required TransactionType type,
    required int amountMinor,
    required String categoryId,
    required DateTime date,
    String note = '',
    PaymentMethod paymentMethod = PaymentMethod.cash,
    TransactionScope scope = TransactionScope.personal,
    String? householdId,
    String? createdBy,
    String? createdByName,
  }) async {
    _validate(amountMinor, categoryId);
    _validateScope(scope, householdId, createdBy);
    final now = DateTime.now();
    final transaction = TransactionModel(
      id: _uuid.v4(),
      type: type,
      amountMinor: amountMinor,
      categoryId: categoryId,
      date: date,
      note: note.trim(),
      paymentMethod: paymentMethod,
      createdAt: now,
      updatedAt: now,
      scope: scope,
      householdId: scope == TransactionScope.shared ? householdId : null,
      createdBy: createdBy,
      createdByName: createdByName,
      updatedBy: createdBy,
    );
    await _repository.insert(transaction);
    await _afterChange();
    return transaction;
  }

  /// Saves an edit. Editing a cloud-only (archived) transaction stores the
  /// new version on this device so it can be uploaded. [transaction] may
  /// have a different scope than before (an explicit move between personal
  /// and shared, see [TransactionModel.withScope]).
  Future<void> updateTransaction(
    TransactionModel transaction, {
    String? updatedBy,
  }) async {
    _validate(transaction.amountMinor, transaction.categoryId);
    _validateScope(
      transaction.scope,
      transaction.householdId,
      transaction.createdBy ?? updatedBy,
    );
    final edited = transaction.copyWith(
      note: transaction.note.trim(),
      updatedAt: DateTime.now(),
      updatedBy: updatedBy,
    );
    if (isCloudOnly(transaction.id)) {
      final previous = _cloud.firstWhere((t) => t.id == transaction.id);
      if (previous.isShared != edited.isShared ||
          previous.householdId != edited.householdId) {
        // Moved: mark it deleted in its old collection.
        await _repository.delete(transaction.id, scope: _scopeOf(previous));
      }
      await _repository.insert(edited);
      _removeFromCloud(transaction.id);
    } else {
      await _repository.update(edited);
    }
    await _afterChange();
  }

  Future<void> deleteTransaction(String id) async {
    TransactionModel? known;
    for (final t in _transactions) {
      if (t.id == id) known = t;
    }
    await _repository.delete(id, scope: known == null ? null : _scopeOf(known));
    _removeFromCloud(id);
    await _afterChange();
  }

  static DataScope _scopeOf(TransactionModel t) => t.isShared
      ? DataScope.household(t.householdId!)
      : const DataScope.personal();

  /// Re-inserts a transaction removed with [deleteTransaction] (undo).
  /// `updatedAt` is bumped so the restore wins over the synced deletion.
  Future<void> restoreTransaction(TransactionModel transaction) async {
    await _repository.insert(transaction.copyWith(updatedAt: DateTime.now()));
    await _afterChange();
  }

  void _removeFromCloud(String id) {
    if (!_cloudIds.contains(id)) return;
    _cloud = [
      for (final t in _cloud)
        if (t.id != id) t,
    ];
    _cloudIds = {for (final t in _cloud) t.id};
  }

  /// Signals that stored data changed outside this provider (e.g. restore).
  Future<void> reloadAfterExternalChange() => _afterChange();

  /// After Reset App: forgets cloud history loaded into memory (hidden
  /// until the user restores their cloud data) and reloads from the device.
  Future<void> reloadAfterReset() {
    _resetCloudHistory();
    return _afterChange();
  }

  Future<void> _afterChange() async {
    _dataVersion++;
    await load();
  }

  void _validateScope(
    TransactionScope scope,
    String? householdId,
    String? createdBy,
  ) {
    if (scope != TransactionScope.shared) return;
    if (householdId == null || householdId.isEmpty) {
      throw ArgumentError(
        'Join or create a household to add shared transactions',
      );
    }
    if (createdBy == null || createdBy.isEmpty) {
      throw ArgumentError('Sign in to add shared transactions');
    }
  }

  void _validate(int amountMinor, String categoryId) {
    if (amountMinor <= 0) {
      throw ArgumentError('Amount must be greater than zero');
    }
    if (categoryId.isEmpty) {
      throw ArgumentError('Please choose a category');
    }
  }
}
