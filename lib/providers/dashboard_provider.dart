import 'package:flutter/foundation.dart';

import '../core/constants/app_constants.dart';
import '../core/services/transaction_calculator.dart';
import '../core/utils/date_range.dart';
import '../models/category_model.dart';
import '../models/report_models.dart';
import '../models/transaction_model.dart';
import '../repositories/transaction_repository.dart';
import 'category_provider.dart';
import 'savings_provider.dart';
import 'settings_provider.dart';
import 'transaction_provider.dart';

/// Immutable snapshot of everything shown on the dashboard.
class DashboardData {
  const DashboardData({
    required this.balanceMinor,
    required this.week,
    required this.month,
    required this.previousWeekExpenseMinor,
    required this.previousMonthExpenseMinor,
    required this.weekDailyExpenses,
    required this.recentTransactions,
    required this.monthCategoryShares,
    this.scope = const ScopeFilter.personal(),
    this.savedMinor = 0,
  });

  /// Which transactions these figures cover.
  final ScopeFilter scope;

  /// All-time income minus all-time expenses.
  final int balanceMinor;

  /// Money currently set aside in savings goals (personal view only; 0 for
  /// the household view). Savings are transfers, not expenses, so they are
  /// never part of [balanceMinor], [week] or [month].
  final int savedMinor;

  /// Money not set aside in savings: [balanceMinor] minus [savedMinor].
  /// Adding to a goal lowers it by the same amount the savings total
  /// rises; a withdrawal does the opposite.
  int get availableMinor => balanceMinor - savedMinor;
  final PeriodTotals week;
  final PeriodTotals month;
  final int previousWeekExpenseMinor;
  final int previousMonthExpenseMinor;
  final List<DailyTotal> weekDailyExpenses;
  final List<TransactionModel> recentTransactions;
  final List<CategoryShare> monthCategoryShares;

  DashboardData withSaved(int savedMinor) => DashboardData(
    balanceMinor: balanceMinor,
    week: week,
    month: month,
    previousWeekExpenseMinor: previousWeekExpenseMinor,
    previousMonthExpenseMinor: previousMonthExpenseMinor,
    weekDailyExpenses: weekDailyExpenses,
    recentTransactions: recentTransactions,
    monthCategoryShares: monthCategoryShares,
    scope: scope,
    savedMinor: savedMinor,
  );

  double? get weekChangePercent => TransactionCalculator.percentChange(
    week.expenseMinor,
    previousWeekExpenseMinor,
  );

  double? get monthChangePercent => TransactionCalculator.percentChange(
    month.expenseMinor,
    previousMonthExpenseMinor,
  );

  /// Average spending per elapsed day of the current month.
  int averageDailyExpense(DateTime today) {
    final elapsed =
        PeriodUtils.daysBetween(
          month.range.start,
          PeriodUtils.dateOnly(today),
        ) +
        1;
    return elapsed <= 0 ? 0 : month.expenseMinor ~/ elapsed;
  }
}

/// Aggregates dashboard figures for the current view scope: personal or
/// the selected household's shared transactions, never both. Refreshes
/// automatically when transactions, categories, the scope or the first day
/// of the week change.
class DashboardProvider extends ChangeNotifier {
  DashboardProvider(this._repository, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final TransactionRepository _repository;
  final DateTime Function() _clock;

  DashboardData? _data;
  bool _isLoading = false;
  String? _error;
  int _loadToken = 0;

  int _firstDayOfWeek = DateTime.monday;
  Map<String, CategoryModel> _categories = const {};
  ScopeFilter _scope = const ScopeFilter.personal();
  Object? _dependencyKey;
  int _savedMinor = 0;
  SavingsProvider? _savings;

  DashboardData? get data => _data;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isEmpty =>
      _data != null &&
      _data!.recentTransactions.isEmpty &&
      _data!.balanceMinor == 0;

  /// Wired through ChangeNotifierProxyProvider4 in money_mate_app.dart.
  ///
  /// A savings change only updates the available balance from
  /// [SavingsProvider.totalSavedMinor]; nothing is queried again.
  void updateDependencies(
    SettingsProvider settings,
    CategoryProvider categories,
    TransactionProvider transactions, [
    SavingsProvider? savings,
  ]) {
    _savings = savings;
    final saved = savings?.savedForScope(transactions.scopeFilter) ?? 0;
    if (saved != _savedMinor) {
      _savedMinor = saved;
      final data = _data;
      if (data != null && data.scope == transactions.scopeFilter) {
        _data = data.withSaved(saved);
        Future.microtask(notifyListeners);
      }
    }
    _firstDayOfWeek = settings.firstDayOfWeek;
    _categories = categories.byId;
    _scope = transactions.scopeFilter;
    final key = (
      transactions.dataVersion,
      categories.version,
      settings.firstDayOfWeek,
      _scope,
    );
    if (key == _dependencyKey) return;
    _dependencyKey = key;
    Future.microtask(refresh);
  }

  Future<void> refresh() async {
    final token = ++_loadToken;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final now = _clock();
      final week = PeriodUtils.weekRange(now, firstWeekday: _firstDayOfWeek);
      final prevWeek = PeriodUtils.weekRange(
        DateTime(week.start.year, week.start.month, week.start.day - 1),
        firstWeekday: _firstDayOfWeek,
      );
      final month = PeriodUtils.monthRange(now);
      final prevMonth = PeriodUtils.monthRange(
        DateTime(now.year, now.month - 1),
      );

      final scope = _scope;
      final results = await Future.wait([
        _repository.sumAmount(type: TransactionType.income, scope: scope),
        _repository.sumAmount(type: TransactionType.expense, scope: scope),
        _repository.totalsForRanges([
          week,
          prevWeek,
          month,
          prevMonth,
        ], scope: scope),
        _repository.dailyTotals(
          type: TransactionType.expense,
          range: week,
          scope: scope,
        ),
        _repository.getTransactions(
          filter: TransactionFilter(scope: scope),
          limit: AppConstants.recentTransactionsLimit,
        ),
        _repository.totalsByCategory(
          type: TransactionType.expense,
          range: month,
          scope: scope,
        ),
        // Older records removed from this device still count in the balance.
        _repository.archivedTotals(scope: scope),
      ]);
      if (token != _loadToken) return;

      final totals = results[2] as List<PeriodTotals>;
      final archived = results[6] as ({int income, int expense});
      _data = DashboardData(
        balanceMinor:
            (results[0] as int) +
            archived.income -
            (results[1] as int) -
            archived.expense,
        week: totals[0],
        month: totals[2],
        previousWeekExpenseMinor: totals[1].expenseMinor,
        previousMonthExpenseMinor: totals[3].expenseMinor,
        weekDailyExpenses: results[3] as List<DailyTotal>,
        recentTransactions: results[4] as List<TransactionModel>,
        monthCategoryShares: TransactionCalculator.toShares(
          results[5] as List<CategoryTotal>,
          _categories,
        ),
        scope: scope,
        // Personal goals reduce the personal balance, the household's goals
        // the household balance; shared goals neither.
        savedMinor: _savings?.savedForScope(scope) ?? 0,
      );
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Could not load the dashboard. Pull down to retry.';
      debugPrint('DashboardProvider.refresh failed: $e');
    } finally {
      if (token == _loadToken) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }
}
