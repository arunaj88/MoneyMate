import '../constants/app_constants.dart';
import '../utils/date_range.dart';
import '../../models/budget_model.dart';

/// Pure budget arithmetic.
///
/// * Remaining Budget = Target Amount − Total Expenses
/// * Budget Usage % = (Total Expenses / Target Amount) × 100
class BudgetCalculator {
  BudgetCalculator._();

  static int remaining(int targetMinor, int spentMinor) =>
      targetMinor - spentMinor;

  /// Returns null when there is no positive target.
  static double? usagePercent(int targetMinor, int spentMinor) {
    if (targetMinor <= 0) return null;
    return spentMinor / targetMinor * 100;
  }

  static BudgetAlertLevel alertLevelFor(double? usagePercent) {
    if (usagePercent == null) return BudgetAlertLevel.none;
    if (usagePercent >= AppConstants.exceededThreshold) {
      return BudgetAlertLevel.exceeded;
    }
    if (usagePercent >= AppConstants.warningThreshold) {
      return BudgetAlertLevel.warning;
    }
    if (usagePercent >= AppConstants.alertThreshold) {
      return BudgetAlertLevel.approaching;
    }
    return BudgetAlertLevel.none;
  }

  static BudgetStatus status({
    required BudgetPeriod period,
    required DateRange range,
    required int? targetMinor,
    required int spentMinor,
  }) {
    final hasTarget = targetMinor != null && targetMinor > 0;
    final usage = hasTarget ? usagePercent(targetMinor, spentMinor) : null;
    return BudgetStatus(
      period: period,
      range: range,
      targetMinor: hasTarget ? targetMinor : null,
      spentMinor: spentMinor,
      remainingMinor: hasTarget ? remaining(targetMinor, spentMinor) : null,
      usagePercent: usage,
      alertLevel: alertLevelFor(usage),
    );
  }

  /// Finds the target in effect for a period starting at [periodStart].
  ///
  /// [versions] may be in any order. Returns null when no version was
  /// effective yet, or when the effective version removed the target.
  static int? targetFor(List<BudgetTarget> versions, DateTime periodStart) {
    BudgetTarget? best;
    for (final v in versions) {
      if (v.effectiveFrom.isAfter(periodStart)) continue;
      if (best == null || v.effectiveFrom.isAfter(best.effectiveFrom)) {
        best = v;
      }
    }
    if (best == null || !best.isActive) return null;
    return best.amountMinor;
  }

  /// Daily amount that can still be spent to stay on budget, including today.
  static int? dailyAllowance(BudgetStatus status, DateTime today) {
    if (!status.hasTarget || status.remainingMinor == null) return null;
    if (status.remainingMinor! <= 0) return 0;
    final daysLeft = PeriodUtils.daysBetween(
      PeriodUtils.dateOnly(today),
      status.range.end,
    );
    if (daysLeft <= 0) return 0;
    return status.remainingMinor! ~/ daysLeft;
  }

  static String alertTitle(BudgetAlertLevel level) {
    switch (level) {
      case BudgetAlertLevel.approaching:
        return 'Budget alert';
      case BudgetAlertLevel.warning:
        return 'Budget warning';
      case BudgetAlertLevel.exceeded:
        return 'Budget exceeded';
      case BudgetAlertLevel.none:
        return '';
    }
  }
}
