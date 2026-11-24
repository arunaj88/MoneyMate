import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/core/utils/date_range.dart';

/// Pure savings arithmetic, free of I/O so it can be unit tested.
class SavingsCalculator {
  SavingsCalculator._();

  /// Projections further away than this are not shown.
  static const int maxProjectionDays = 365 * 50;

  /// Totals across [goals].
  static SavingsSummary summarize(Iterable<SavingsGoal> goals) {
    var saved = 0;
    var target = 0;
    var remaining = 0;
    var active = 0;
    var paused = 0;
    var completed = 0;
    for (final g in goals) {
      saved += g.savedMinor;
      target += g.targetMinor;
      switch (g.status) {
        case SavingsGoalStatus.active:
          active++;
          remaining += g.remainingMinor;
        case SavingsGoalStatus.paused:
          paused++;
        case SavingsGoalStatus.completed:
          completed++;
      }
    }
    return SavingsSummary(
      totalSavedMinor: saved,
      totalTargetMinor: target,
      remainingActiveMinor: remaining,
      activeCount: active,
      pausedCount: paused,
      completedCount: completed,
    );
  }

  /// Balance of a goal after its [entries].
  static int balanceOf(Iterable<SavingsEntry> entries) =>
      entries.fold(0, (sum, e) => sum + e.signedMinor);

  /// When an active goal will reach its target if the user keeps saving at
  /// the average pace since its first entry. Null when the goal is not
  /// active, already reached, has no savings yet, or the pace is too slow
  /// for a meaningful date.
  static DateTime? expectedCompletion(SavingsGoal goal, DateTime now) {
    if (!goal.isActive || goal.targetReached) return null;
    final first = goal.firstEntryDate;
    if (first == null || goal.savedMinor <= 0) return null;
    final today = PeriodUtils.dateOnly(now);
    final elapsed = PeriodUtils.daysBetween(PeriodUtils.dateOnly(first), today);
    // At least a week of history, so one deposit today does not predict
    // the target being reached tomorrow.
    final days = elapsed < 7 ? 7 : elapsed;
    final perDay = goal.savedMinor / days;
    final needed = (goal.remainingMinor / perDay).ceil();
    if (needed > maxProjectionDays) return null;
    return DateTime(today.year, today.month, today.day + needed);
  }

  /// Amount to save per month from [now] to reach the target by its
  /// target date; null without a future target date or when reached.
  static int? monthlyNeeded(SavingsGoal goal, DateTime now) {
    final target = goal.targetDate;
    if (target == null || goal.targetReached || goal.isCompleted) return null;
    final today = PeriodUtils.dateOnly(now);
    final days = PeriodUtils.daysBetween(today, PeriodUtils.dateOnly(target));
    if (days <= 0) return null;
    final months = days / 30.44;
    return (goal.remainingMinor / (months < 1 ? 1 : months)).ceil();
  }
}
