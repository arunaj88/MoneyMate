import '../utils/date_range.dart';
import '../../models/category_model.dart';
import '../../models/report_models.dart';
import '../../models/transaction_model.dart';

/// Pure functions for aggregating transactions. Free of I/O so they can be
/// unit tested and reused by repositories and providers.
class TransactionCalculator {
  TransactionCalculator._();

  static int totalOf(
    Iterable<TransactionModel> transactions,
    TransactionType type, {
    DateRange? range,
  }) {
    var total = 0;
    for (final t in transactions) {
      if (t.type != type) continue;
      if (range != null && !range.contains(t.date)) continue;
      total += t.amountMinor;
    }
    return total;
  }

  static int totalIncome(
    Iterable<TransactionModel> transactions, {
    DateRange? range,
  }) => totalOf(transactions, TransactionType.income, range: range);

  static int totalExpense(
    Iterable<TransactionModel> transactions, {
    DateRange? range,
  }) => totalOf(transactions, TransactionType.expense, range: range);

  /// Income minus expenses.
  static int balance(
    Iterable<TransactionModel> transactions, {
    DateRange? range,
  }) =>
      totalIncome(transactions, range: range) -
      totalExpense(transactions, range: range);

  /// Percentage change from [previous] to [current]; null if [previous] is 0.
  static double? percentChange(int current, int previous) {
    if (previous == 0) return null;
    return (current - previous) / previous * 100;
  }

  /// Groups transactions by calendar day, preserving input order inside each
  /// group. Groups are returned newest day first.
  static List<MapEntry<DateTime, List<TransactionModel>>> groupByDay(
    Iterable<TransactionModel> transactions,
  ) {
    final groups = <DateTime, List<TransactionModel>>{};
    for (final t in transactions) {
      final day = PeriodUtils.dateOnly(t.date);
      groups.putIfAbsent(day, () => []).add(t);
    }
    final entries = groups.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return entries;
  }

  /// Totals per category for [type], largest first.
  static List<CategoryTotal> totalsByCategory(
    Iterable<TransactionModel> transactions,
    TransactionType type, {
    DateRange? range,
  }) {
    final totals = <String, int>{};
    for (final t in transactions) {
      if (t.type != type) continue;
      if (range != null && !range.contains(t.date)) continue;
      totals[t.categoryId] = (totals[t.categoryId] ?? 0) + t.amountMinor;
    }
    final list =
        totals.entries
            .map((e) => CategoryTotal(categoryId: e.key, totalMinor: e.value))
            .toList()
          ..sort((a, b) => b.totalMinor.compareTo(a.totalMinor));
    return list;
  }

  /// Resolves category totals into shares of the overall total. Totals whose
  /// category is unknown are grouped under a synthetic "Unknown" category.
  static List<CategoryShare> toShares(
    List<CategoryTotal> totals,
    Map<String, CategoryModel> categories,
  ) {
    final sum = totals.fold<int>(0, (s, t) => s + t.totalMinor);
    if (sum == 0) return const [];
    return totals.where((t) => t.totalMinor > 0).map((t) {
      final category =
          categories[t.categoryId] ??
          CategoryModel(
            id: t.categoryId,
            name: 'Unknown',
            type: TransactionType.expense,
            iconKey: 'other',
            colorValue: 0xFF9E9E9E,
          );
      return CategoryShare(
        category: category,
        totalMinor: t.totalMinor,
        percent: t.totalMinor / sum * 100,
      );
    }).toList();
  }

  /// Builds a total for every day in [range] (zero when nothing was spent).
  static List<DailyTotal> dailyTotalsFromEntries(
    Iterable<({DateTime date, int amountMinor})> entries,
    DateRange range,
  ) {
    final byDay = <DateTime, int>{};
    for (final e in entries) {
      if (!range.contains(e.date)) continue;
      final day = PeriodUtils.dateOnly(e.date);
      byDay[day] = (byDay[day] ?? 0) + e.amountMinor;
    }
    return PeriodUtils.daysIn(
      range,
    ).map((d) => DailyTotal(day: d, totalMinor: byDay[d] ?? 0)).toList();
  }

  static List<DailyTotal> dailyTotals(
    Iterable<TransactionModel> transactions,
    TransactionType type,
    DateRange range,
  ) => dailyTotalsFromEntries(
    transactions
        .where((t) => t.type == type)
        .map((t) => (date: t.date, amountMinor: t.amountMinor)),
    range,
  );
}
