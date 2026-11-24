import 'package:money_mate/models/report_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/services/transaction_calculator.dart';

/// Adds cloud-only transactions (older than the local retention window) to
/// totals computed from the local database.
///
/// The cloud records passed in are never stored on this device (the
/// history loader excludes IDs that are), so nothing is counted twice.
class HistoricalTotals {
  HistoricalTotals._();

  static List<PeriodTotals> addToPeriods(
    List<PeriodTotals> local,
    List<TransactionModel> older,
  ) {
    if (older.isEmpty) return local;
    return [
      for (final p in local)
        PeriodTotals(
          range: p.range,
          incomeMinor:
              p.incomeMinor +
              TransactionCalculator.totalIncome(older, range: p.range),
          expenseMinor:
              p.expenseMinor +
              TransactionCalculator.totalExpense(older, range: p.range),
        ),
    ];
  }

  static List<DailyTotal> addToDaily(
    List<DailyTotal> local,
    List<TransactionModel> older,
    TransactionType type,
    DateRange range,
  ) {
    if (older.isEmpty) return local;
    final extra = TransactionCalculator.dailyTotals(older, type, range);
    return [
      for (var i = 0; i < local.length; i++)
        DailyTotal(
          day: local[i].day,
          totalMinor:
              local[i].totalMinor +
              (i < extra.length ? extra[i].totalMinor : 0),
        ),
    ];
  }

  static List<CategoryTotal> addToCategories(
    List<CategoryTotal> local,
    List<TransactionModel> older,
    TransactionType type,
    DateRange range,
  ) {
    if (older.isEmpty) return local;
    final sums = <String, int>{
      for (final c in local) c.categoryId: c.totalMinor,
    };
    for (final c in TransactionCalculator.totalsByCategory(
      older,
      type,
      range: range,
    )) {
      sums[c.categoryId] = (sums[c.categoryId] ?? 0) + c.totalMinor;
    }
    return [
      for (final e in sums.entries)
        CategoryTotal(categoryId: e.key, totalMinor: e.value),
    ]..sort((a, b) => b.totalMinor.compareTo(a.totalMinor));
  }
}
