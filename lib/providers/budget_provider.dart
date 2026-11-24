import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../core/services/budget_calculator.dart';
import '../core/services/cloud_history_loader.dart';
import '../core/services/historical_totals.dart';
import '../core/services/notification_cloud.dart';
import '../core/services/notification_events.dart';
import '../core/utils/date_range.dart';
import '../core/utils/money.dart';
import '../models/budget_model.dart';
import '../models/category_model.dart';
import '../models/report_models.dart';
import '../models/scope_models.dart';
import '../models/transaction_model.dart';
import '../repositories/app_settings_repository.dart';
import '../repositories/budget_repository.dart';
import '../repositories/transaction_repository.dart';
import 'category_provider.dart';
import 'household_provider.dart';
import 'settings_provider.dart';
import 'transaction_provider.dart';

/// Budgets of one data scope: personal, or a household's shared budgets.
class BudgetSet {
  const BudgetSet({
    required this.scope,
    required this.weeklyHistory,
    required this.monthlyHistory,
    required this.categoryStatuses,
  });

  final DataScope scope;

  /// Most recent period first.
  final List<BudgetStatus> weeklyHistory;
  final List<BudgetStatus> monthlyHistory;
  final List<CategoryBudgetStatus> categoryStatuses;

  BudgetStatus get weekly => weeklyHistory.first;
  BudgetStatus get monthly => monthlyHistory.first;
}

/// Weekly / monthly targets, category budgets, history and alerts.
///
/// Weekly and monthly targets are independent; every expense counts toward
/// both the week and the month containing its date. Income never counts.
///
/// Personal budgets only count personal expenses and stay private; shared
/// household budgets count the household's shared expenses and are synced
/// to every member. Both are computed; [selectedScope] picks the one the
/// budget screen shows and edits.
class BudgetProvider extends ChangeNotifier {
  BudgetProvider({
    required BudgetRepository budgetRepository,
    required TransactionRepository transactionRepository,
    required AppSettingsRepository appSettingsRepository,
    TransactionHistorySource? history,
    BudgetAlertSink? alertSink,
    DateTime Function()? clock,
    Uuid? uuid,
  }) : _budgets = budgetRepository,
       _alertSink = alertSink,
       _transactions = transactionRepository,
       _appSettings = appSettingsRepository,
       _history = history,
       _clock = clock ?? DateTime.now,
       _uuid = uuid ?? const Uuid();

  static const String _alertKeyPrefix = 'alert.';

  final BudgetRepository _budgets;
  final TransactionRepository _transactions;
  final AppSettingsRepository _appSettings;
  final TransactionHistorySource? _history;

  /// System notifications and household pushes for new alerts.
  final BudgetAlertSink? _alertSink;
  final DateTime Function() _clock;
  final Uuid _uuid;

  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;
  int _loadToken = 0;
  Object? _dependencyKey;
  int _dataVersion = 0;
  int _localChangeVersion = 0;

  int _firstDayOfWeek = DateTime.monday;
  bool _budgetAlertsEnabled = true;
  bool _categoryAlertsEnabled = true;
  Map<String, CategoryModel> _categories = const {};
  CurrencyFormatter _formatter = CurrencyFormatter('AED');
  String? _householdId;
  String? _uid;

  DataScope _selected = const DataScope.personal();
  Map<DataScope, BudgetSet> _sets = const {};
  final List<BudgetAlert> _pendingAlerts = [];

  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  String? get error => _error;

  /// Increases on every budget change made on this device (sync trigger).
  int get localChangeVersion => _localChangeVersion;

  /// The household whose shared budgets are available, if any.
  String? get householdId => _householdId;

  /// Scope shown and edited on the budget screen.
  DataScope get selectedScope => _selected;

  void selectScope(DataScope scope) {
    if (scope.isHousehold && scope.householdId != _householdId) return;
    if (scope == _selected) return;
    _selected = scope;
    notifyListeners();
  }

  /// Budgets of [scope], once loaded.
  BudgetSet? setFor(DataScope scope) => _sets[scope];

  BudgetSet? get _current => _sets[_selected];

  BudgetStatus? get weekly => _current?.weekly;
  BudgetStatus? get monthly => _current?.monthly;

  /// Most recent period first.
  List<BudgetStatus> get weeklyHistory => _current?.weeklyHistory ?? const [];
  List<BudgetStatus> get monthlyHistory => _current?.monthlyHistory ?? const [];
  List<CategoryBudgetStatus> get categoryStatuses =>
      _current?.categoryStatuses ?? const [];

  BudgetStatus? statusFor(BudgetPeriod period) =>
      period == BudgetPeriod.weekly ? weekly : monthly;

  List<BudgetStatus> historyFor(BudgetPeriod period) =>
      period == BudgetPeriod.weekly ? weeklyHistory : monthlyHistory;

  List<CategoryBudgetStatus> categoryStatusesFor(BudgetPeriod period) =>
      categoryStatuses.where((s) => s.budget.period == period).toList();

  bool get hasPendingAlerts => _pendingAlerts.isNotEmpty;

  /// Returns and clears alerts waiting to be shown to the user.
  List<BudgetAlert> takePendingAlerts() {
    final alerts = List<BudgetAlert>.of(_pendingAlerts);
    _pendingAlerts.clear();
    return alerts;
  }

  void updateDependencies(
    SettingsProvider settings,
    CategoryProvider categories,
    TransactionProvider transactions, [
    HouseholdProvider? household,
  ]) {
    _firstDayOfWeek = settings.firstDayOfWeek;
    _budgetAlertsEnabled = settings.budgetAlertsEnabled;
    _categoryAlertsEnabled = settings.categoryAlertsEnabled;
    _categories = categories.byId;
    _formatter = settings.formatter;
    _dataVersion = transactions.dataVersion;
    _uid = household?.uid;
    _householdId = household?.householdId ?? transactions.householdId;
    if (_selected.isHousehold && _selected.householdId != _householdId) {
      _selected = const DataScope.personal();
    }
    final key = (
      transactions.dataVersion,
      categories.version,
      settings.firstDayOfWeek,
      _householdId,
    );
    if (key == _dependencyKey) return;
    _dependencyKey = key;
    Future.microtask(refresh);
  }

  DateRange _currentRange(BudgetPeriod period, DateTime now) =>
      period == BudgetPeriod.weekly
      ? PeriodUtils.weekRange(now, firstWeekday: _firstDayOfWeek)
      : PeriodUtils.monthRange(now);

  Future<void> refresh() async {
    final token = ++_loadToken;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final household = _householdId;
      final scopes = [
        const DataScope.personal(),
        if (household != null) DataScope.household(household),
      ];
      final sets = <DataScope, BudgetSet>{};
      for (final scope in scopes) {
        sets[scope] = await _compute(scope);
      }
      if (token != _loadToken) return;
      _sets = Map.unmodifiable(sets);
      _hasLoaded = true;
      await _evaluateAlerts();
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Could not load budgets. Please try again.';
      debugPrint('BudgetProvider.refresh failed: $e');
    } finally {
      if (token == _loadToken) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  static ScopeFilter _spendingOf(DataScope scope) => scope.isPersonal
      ? const ScopeFilter.personal()
      : ScopeFilter.shared(scope.householdId!);

  Future<BudgetSet> _compute(DataScope scope) async {
    final now = _clock();
    final spending = _spendingOf(scope);
    final weeks = PeriodUtils.lastWeeks(
      now,
      AppConstants.weeklyHistoryCount,
      firstWeekday: _firstDayOfWeek,
    );
    final months = PeriodUtils.lastMonths(
      now,
      AppConstants.monthlyHistoryCount,
    );

    final results = await Future.wait([
      _budgets.getTargetVersions(BudgetPeriod.weekly, scope: scope),
      _budgets.getTargetVersions(BudgetPeriod.monthly, scope: scope),
      _transactions.totalsForRanges(weeks, scope: spending),
      _transactions.totalsForRanges(months, scope: spending),
      _budgets.getCategoryBudgets(scope: scope),
    ]);
    // Historical periods older than the local window include the cloud
    // copies of transactions removed from this device.
    final older = await _olderTransactions(
      spending,
      weeks.first.start.isBefore(months.first.start)
          ? weeks.first.start
          : months.first.start,
    );
    final weeklyVersions = results[0] as List<BudgetTarget>;
    final monthlyVersions = results[1] as List<BudgetTarget>;
    final weekTotals = HistoricalTotals.addToPeriods(
      results[2] as List<PeriodTotals>,
      older,
    );
    final monthTotals = HistoricalTotals.addToPeriods(
      results[3] as List<PeriodTotals>,
      older,
    );
    final categoryBudgets = (results[4] as List<CategoryBudget>)
        .where(
          (b) => _categories.isEmpty || _categories.containsKey(b.categoryId),
        )
        .toList();

    final categoryStatuses = <CategoryBudgetStatus>[];
    for (final budget in categoryBudgets) {
      final range = _currentRange(budget.period, now);
      final spent = await _transactions.sumAmount(
        type: TransactionType.expense,
        range: range,
        categoryId: budget.categoryId,
        scope: spending,
      );
      categoryStatuses.add(
        CategoryBudgetStatus(
          budget: budget,
          status: BudgetCalculator.status(
            period: budget.period,
            range: range,
            targetMinor: budget.amountMinor,
            spentMinor: spent,
          ),
        ),
      );
    }
    categoryStatuses.sort(
      (a, b) =>
          (b.status.usagePercent ?? 0).compareTo(a.status.usagePercent ?? 0),
    );

    return BudgetSet(
      scope: scope,
      weeklyHistory: _buildHistory(
        BudgetPeriod.weekly,
        weekTotals,
        weeklyVersions,
      ),
      monthlyHistory: _buildHistory(
        BudgetPeriod.monthly,
        monthTotals,
        monthlyVersions,
      ),
      categoryStatuses: List.unmodifiable(categoryStatuses),
    );
  }

  Future<List<TransactionModel>> _olderTransactions(
    ScopeFilter scope,
    DateTime start,
  ) async {
    final history = _history;
    if (history == null || !history.isAvailable) return const [];
    try {
      return (await history.olderTransactions(
        scope: scope,
        start: start,
        categoryNames: {for (final c in _categories.values) c.id: c.name},
        version: _dataVersion,
      )).items;
    } catch (e) {
      // Offline: history shows locally stored spending only.
      debugPrint('Budget history without cloud records: $e');
      return const [];
    }
  }

  /// Builds statuses newest first from chronologically ordered [totals].
  List<BudgetStatus> _buildHistory(
    BudgetPeriod period,
    List<PeriodTotals> totals,
    List<BudgetTarget> versions,
  ) {
    return totals.reversed
        .map(
          (t) => BudgetCalculator.status(
            period: period,
            range: t.range,
            targetMinor: BudgetCalculator.targetFor(versions, t.range.start),
            spentMinor: t.expenseMinor,
          ),
        )
        .toList(growable: false);
  }

  void _changed() => _localChangeVersion++;

  // ---------------------------------------------------------------- targets

  /// Sets the target of the selected scope (personal or shared).
  Future<void> setTarget(BudgetPeriod period, int amountMinor) async {
    if (amountMinor <= 0) {
      throw ArgumentError('Target must be greater than zero');
    }
    await _budgets.setTarget(
      period: period,
      amountMinor: amountMinor,
      effectiveFrom: _currentRange(period, _clock()).start,
      scope: _selected,
      updatedBy: _uid,
    );
    _changed();
    await refresh();
  }

  /// Removes the target from the current period onwards. Past periods keep
  /// the target that applied to them.
  Future<void> removeTarget(BudgetPeriod period) async {
    await _budgets.setTarget(
      period: period,
      amountMinor: 0,
      effectiveFrom: _currentRange(period, _clock()).start,
      scope: _selected,
      updatedBy: _uid,
    );
    _changed();
    await refresh();
  }

  // ------------------------------------------------------- category budgets

  /// Creates or updates the budget for [categoryId] and [period] in the
  /// selected scope.
  Future<void> saveCategoryBudget({
    String? id,
    required String categoryId,
    required BudgetPeriod period,
    required int amountMinor,
  }) async {
    if (amountMinor <= 0) {
      throw ArgumentError('Budget must be greater than zero');
    }
    final now = _clock();
    CategoryBudget? existing;
    for (final s in categoryStatuses) {
      if (s.budget.id == id ||
          (s.budget.categoryId == categoryId && s.budget.period == period)) {
        existing = s.budget;
        break;
      }
    }
    final budget = CategoryBudget(
      id: existing?.id ?? id ?? _uuid.v4(),
      categoryId: categoryId,
      period: period,
      amountMinor: amountMinor,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      householdId: _selected.householdId,
      updatedBy: _uid,
    );
    // If the user changed category/period of an existing budget, remove the
    // old row so it is not duplicated.
    if (id != null && existing != null && existing.id != id) {
      await _budgets.deleteCategoryBudget(id);
    }
    await _budgets.upsertCategoryBudget(budget);
    _changed();
    await refresh();
  }

  Future<void> deleteCategoryBudget(String id) async {
    await _budgets.deleteCategoryBudget(id);
    _changed();
    await refresh();
  }

  /// Categories that do not yet have a budget for [period] in the selected
  /// scope.
  List<CategoryModel> availableCategoriesFor(
    BudgetPeriod period, {
    String? includeCategoryId,
  }) {
    final used =
        categoryStatuses
            .where((s) => s.budget.period == period)
            .map((s) => s.budget.categoryId)
            .toSet()
          ..remove(includeCategoryId);
    return _categories.values
        .where((c) => c.type == TransactionType.expense && !used.contains(c.id))
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  // ----------------------------------------------------------------- alerts

  Future<void> _evaluateAlerts() async {
    final stored = await _appSettings.getByPrefix(_alertKeyPrefix);

    Future<void> check(
      String scope,
      String name,
      BudgetStatus? status,
      bool enabled, {
      String? householdId,
      String? cloudScope,
    }) async {
      if (status == null) return;
      final period = DateFormat('yyyyMMdd').format(status.range.start);
      final key = '$_alertKeyPrefix$scope.$period';
      final previous = BudgetAlertLevel
          .values[int.tryParse(stored[key] ?? '')?.clamp(0, 3) ?? 0];
      final current = status.alertLevel;
      if (current == previous) return;
      // Persist the new level first so the alert never fires twice for the
      // same threshold in the same period, even across app restarts.
      await _appSettings.set(key, current.index.toString());
      if (!(current > previous)) return;
      final local = enabled ? _buildAlert(key, name, status) : null;
      if (local != null) _pendingAlerts.add(local);
      // The other members are told whatever this user's own settings are.
      final household = householdId == null
          ? null
          : HouseholdBudgetAlert(
              householdId: householdId,
              key: '$cloudScope.$period',
              level: current.name,
              title: BudgetCalculator.alertTitle(current),
              message: _householdMessage(name, status),
              periodEnd: status.range.end,
            );
      if (local != null || household != null) {
        unawaited(
          _alertSink?.budgetAlertRaised(
            BudgetAlertEvent(local: local, household: household),
          ),
        );
      }
    }

    for (final set in _sets.values) {
      // Personal keys are unchanged from earlier versions.
      final prefix = set.scope.isPersonal ? '' : 'h.${set.scope.householdId}.';
      final label = set.scope.isPersonal ? '' : 'shared ';
      final householdId = set.scope.householdId;
      await check(
        '${prefix}weekly',
        '${label}weekly budget',
        set.weekly,
        _budgetAlertsEnabled,
        householdId: householdId,
        cloudScope: 'weekly',
      );
      await check(
        '${prefix}monthly',
        '${label}monthly budget',
        set.monthly,
        _budgetAlertsEnabled,
        householdId: householdId,
        cloudScope: 'monthly',
      );
      for (final s in set.categoryStatuses) {
        final category = _categories[s.budget.categoryId];
        await check(
          '${prefix}cat.${s.budget.id}',
          '$label${category?.name ?? 'category'} ${s.budget.period.noun}ly '
              'budget',
          s.status,
          _categoryAlertsEnabled,
          householdId: householdId,
          cloudScope: 'cat.${s.budget.id}',
        );
      }
    }
  }

  /// The alert as the other household members read it.
  String _householdMessage(String name, BudgetStatus status) {
    final percent = status.usagePercent?.toStringAsFixed(0) ?? '0';
    final remaining = status.remainingMinor ?? 0;
    final used = '$percent% of the $name used.';
    return switch (status.alertLevel) {
      BudgetAlertLevel.exceeded =>
        '$used Over by ${_formatter.format(-remaining)}.',
      BudgetAlertLevel.warning =>
        '$used Only ${_formatter.format(remaining)} left.',
      BudgetAlertLevel.approaching =>
        '$used ${_formatter.format(remaining)} remaining.',
      BudgetAlertLevel.none => used,
    };
  }

  BudgetAlert _buildAlert(String key, String name, BudgetStatus status) {
    final percent = status.usagePercent?.toStringAsFixed(0) ?? '0';
    final String message;
    switch (status.alertLevel) {
      case BudgetAlertLevel.exceeded:
        message =
            'You have spent $percent% of your $name. '
            'Over by ${_formatter.format(-(status.remainingMinor ?? 0))}.';
      case BudgetAlertLevel.warning:
        message =
            'You have used $percent% of your $name. '
            'Only ${_formatter.format(status.remainingMinor ?? 0)} left.';
      case BudgetAlertLevel.approaching:
        message =
            'You have used $percent% of your $name. '
            '${_formatter.format(status.remainingMinor ?? 0)} remaining.';
      case BudgetAlertLevel.none:
        message = '';
    }
    return BudgetAlert(
      key: key,
      title: BudgetCalculator.alertTitle(status.alertLevel),
      message: message,
      level: status.alertLevel,
    );
  }
}
