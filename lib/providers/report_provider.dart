import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'package:money_mate/core/services/cloud_history_loader.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/core/services/historical_totals.dart';
import 'package:money_mate/core/services/transaction_calculator.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/report_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';

/// Quick date range choices for reports.
enum ReportRangePreset {
  thisWeek('This week'),
  thisMonth('This month'),
  lastMonth('Last month'),
  last3Months('Last 3 months'),
  last6Months('Last 6 months'),
  thisYear('This year'),
  custom('Custom');

  const ReportRangePreset(this.label);
  final String label;
}

/// Everything shown on the reports screen for the selected range.
class ReportData {
  const ReportData({
    required this.range,
    required this.totals,
    required this.dailyExpenses,
    required this.weeklyTotals,
    required this.monthlyTotals,
    required this.categoryShares,
    required this.currentMonth,
    required this.previousMonth,
  });

  final DateRange range;

  /// Income / expense totals for the selected range.
  final PeriodTotals totals;
  final List<DailyTotal> dailyExpenses;

  /// Last 8 weeks ending with the week containing the range end.
  final List<PeriodTotals> weeklyTotals;

  /// Last 6 months ending with the month containing the range end.
  final List<PeriodTotals> monthlyTotals;
  final List<CategoryShare> categoryShares;

  /// Month containing the end of the range, and the month before it.
  final PeriodTotals currentMonth;
  final PeriodTotals previousMonth;

  int get savingsMinor => totals.netMinor;
  List<CategoryShare> get topCategories => categoryShares.take(5).toList();

  double? get expenseChangePercent => TransactionCalculator.percentChange(
    currentMonth.expenseMinor,
    previousMonth.expenseMinor,
  );
  double? get incomeChangePercent => TransactionCalculator.percentChange(
    currentMonth.incomeMinor,
    previousMonth.incomeMinor,
  );

  int get averageDailyExpenseMinor {
    final days = range.dayCount;
    return days <= 0 ? 0 : totals.expenseMinor ~/ days;
  }

  bool get isEmpty => totals.incomeMinor == 0 && totals.expenseMinor == 0;
}

/// Analytics for the reports screen, for the current view scope.
///
/// Ranges that reach back beyond the local retention window include the
/// older transactions from the cloud (when online); [historyNote] explains
/// when they could not be loaded.
class ReportProvider extends ChangeNotifier {
  ReportProvider(
    this._repository, {
    DateTime Function()? clock,
    TransactionHistorySource? history,
  }) : _clock = clock ?? DateTime.now,
       _history = history {
    _range = _rangeForPreset(_preset);
  }

  static const int weeksShown = 8;
  static const int monthsShown = 6;

  final TransactionRepository _repository;
  final DateTime Function() _clock;
  final TransactionHistorySource? _history;
  ScopeFilter _scope = const ScopeFilter.personal();
  int _dataVersion = 0;
  String? _historyNote;

  ReportRangePreset _preset = ReportRangePreset.thisMonth;
  late DateRange _range;
  ReportData? _data;
  bool _isLoading = false;
  String? _error;
  int _loadToken = 0;
  Object? _dependencyKey;

  int _firstDayOfWeek = DateTime.monday;
  Map<String, CategoryModel> _categories = const {};

  ReportRangePreset get preset => _preset;
  DateRange get range => _range;
  ReportData? get data => _data;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Set when older cloud transactions could not be included.
  String? get historyNote => _historyNote;

  String get rangeLabel {
    final f = DateFormat('d MMM yyyy');
    return '${f.format(_range.start)} – ${f.format(_range.lastDay)}';
  }

  void updateDependencies(
    SettingsProvider settings,
    CategoryProvider categories,
    TransactionProvider transactions,
  ) {
    final firstDayChanged = settings.firstDayOfWeek != _firstDayOfWeek;
    _firstDayOfWeek = settings.firstDayOfWeek;
    _categories = categories.byId;
    _scope = transactions.scopeFilter;
    _dataVersion = transactions.dataVersion;
    if (firstDayChanged && _preset == ReportRangePreset.thisWeek) {
      _range = _rangeForPreset(_preset);
    }
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

  DateRange _rangeForPreset(ReportRangePreset preset) {
    final now = _clock();
    final today = PeriodUtils.dateOnly(now);
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    switch (preset) {
      case ReportRangePreset.thisWeek:
        return PeriodUtils.weekRange(now, firstWeekday: _firstDayOfWeek);
      case ReportRangePreset.thisMonth:
        return PeriodUtils.monthRange(now);
      case ReportRangePreset.lastMonth:
        return PeriodUtils.monthRange(DateTime(now.year, now.month - 1));
      case ReportRangePreset.last3Months:
        return DateRange(DateTime(now.year, now.month - 2), tomorrow);
      case ReportRangePreset.last6Months:
        return DateRange(DateTime(now.year, now.month - 5), tomorrow);
      case ReportRangePreset.thisYear:
        return PeriodUtils.yearRange(now);
      case ReportRangePreset.custom:
        return _range;
    }
  }

  Future<void> selectPreset(ReportRangePreset preset) async {
    if (preset == ReportRangePreset.custom) return;
    _preset = preset;
    _range = _rangeForPreset(preset);
    await refresh();
  }

  /// [start] and [end] are inclusive calendar days.
  Future<void> setCustomRange(DateTime start, DateTime end) async {
    final s = PeriodUtils.dateOnly(start.isBefore(end) ? start : end);
    final e = PeriodUtils.dateOnly(start.isBefore(end) ? end : start);
    _preset = ReportRangePreset.custom;
    _range = DateRange(s, DateTime(e.year, e.month, e.day + 1));
    await refresh();
  }

  Future<void> refresh() async {
    final token = ++_loadToken;
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      final range = _range;
      final anchor = range.lastDay;
      final weeks = PeriodUtils.lastWeeks(
        anchor,
        weeksShown,
        firstWeekday: _firstDayOfWeek,
      );
      final months = PeriodUtils.lastMonths(anchor, monthsShown);

      final scope = _scope;
      final results = await Future.wait([
        _repository.totalsForRanges([range], scope: scope),
        _repository.dailyTotals(
          type: TransactionType.expense,
          range: range,
          scope: scope,
        ),
        _repository.totalsForRanges(weeks, scope: scope),
        _repository.totalsForRanges(months, scope: scope),
        _repository.totalsByCategory(
          type: TransactionType.expense,
          range: range,
          scope: scope,
        ),
      ]);
      final earliest = [
        range.start,
        weeks.first.start,
        months.first.start,
      ].reduce((a, b) => a.isBefore(b) ? a : b);
      final older = await _olderTransactions(scope, earliest);
      if (token != _loadToken) return;

      final monthlyTotals = HistoricalTotals.addToPeriods(
        results[3] as List<PeriodTotals>,
        older,
      );
      _data = ReportData(
        range: range,
        totals: HistoricalTotals.addToPeriods(
          results[0] as List<PeriodTotals>,
          older,
        ).first,
        dailyExpenses: HistoricalTotals.addToDaily(
          results[1] as List<DailyTotal>,
          older,
          TransactionType.expense,
          range,
        ),
        weeklyTotals: HistoricalTotals.addToPeriods(
          results[2] as List<PeriodTotals>,
          older,
        ),
        monthlyTotals: monthlyTotals,
        categoryShares: TransactionCalculator.toShares(
          HistoricalTotals.addToCategories(
            results[4] as List<CategoryTotal>,
            older,
            TransactionType.expense,
            range,
          ),
          _categories,
        ),
        currentMonth: monthlyTotals[monthlyTotals.length - 1],
        previousMonth: monthlyTotals[monthlyTotals.length - 2],
      );
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Could not build reports. Please try again.';
      debugPrint('ReportProvider.refresh failed: $e');
    } finally {
      if (token == _loadToken) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  /// Cloud-only transactions from [start] up to the retention cutoff; empty
  /// (with [historyNote] set) when they cannot be loaded.
  Future<List<TransactionModel>> _olderTransactions(
    ScopeFilter scope,
    DateTime start,
  ) async {
    _historyNote = null;
    final history = _history;
    if (history == null || !history.isAvailable) return const [];
    try {
      final result = await history.olderTransactions(
        scope: scope,
        start: start,
        categoryNames: {for (final c in _categories.values) c.id: c.name},
        version: _dataVersion,
      );
      return result.items;
    } on CloudUnavailableException {
      _historyNote =
          'Offline: older transactions that are only stored in the cloud '
          'are not included.';
    } on CloudHistoryUnavailableException catch (e) {
      _historyNote = e.message;
    } catch (e) {
      debugPrint('Loading report history failed: $e');
      _historyNote = 'Older transactions could not be loaded.';
    }
    return const [];
  }
}
