import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/category_model.dart';

/// Total amount spent (or earned) in one category.
class CategoryTotal {
  const CategoryTotal({required this.categoryId, required this.totalMinor});

  final String categoryId;
  final int totalMinor;
}

/// [CategoryTotal] resolved with its category and share of the total.
class CategoryShare {
  const CategoryShare({
    required this.category,
    required this.totalMinor,
    required this.percent,
  });

  final CategoryModel category;
  final int totalMinor;

  /// Share of the overall total, 0..100.
  final double percent;
}

/// Income and expense totals for a range of time.
class PeriodTotals {
  const PeriodTotals({
    required this.range,
    required this.incomeMinor,
    required this.expenseMinor,
  });

  final DateRange range;
  final int incomeMinor;
  final int expenseMinor;

  int get netMinor => incomeMinor - expenseMinor;

  /// Percentage of income saved; null when there was no income.
  double? get savingsRate =>
      incomeMinor == 0 ? null : netMinor / incomeMinor * 100;
}

/// Total for a single day (used in charts).
class DailyTotal {
  const DailyTotal({required this.day, required this.totalMinor});

  final DateTime day;
  final int totalMinor;
}
