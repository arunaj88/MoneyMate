import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../models/budget_model.dart';

/// Colour representing how close spending is to its target.
Color budgetLevelColor(BuildContext context, BudgetAlertLevel level) {
  final finance = context.finance;
  switch (level) {
    case BudgetAlertLevel.none:
      return finance.income;
    case BudgetAlertLevel.approaching:
      return finance.caution;
    case BudgetAlertLevel.warning:
      return finance.warning;
    case BudgetAlertLevel.exceeded:
      return finance.expense;
  }
}

/// Animated rounded progress bar coloured by alert level.
class BudgetProgressBar extends StatelessWidget {
  const BudgetProgressBar({
    super.key,
    required this.progress,
    required this.level,
    this.height = 10,
  });

  /// 0..1
  final double progress;
  final BudgetAlertLevel level;
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = budgetLevelColor(context, level);
    return Semantics(
      label: 'Budget used',
      value: '${(progress * 100).round()} percent',
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: LinearProgressIndicator(
            value: value,
            minHeight: height,
            color: color,
            backgroundColor: color.withValues(alpha: 0.15),
          ),
        ),
      ),
    );
  }
}

/// Small pill describing the alert level, e.g. "90% used".
class BudgetLevelChip extends StatelessWidget {
  const BudgetLevelChip({super.key, required this.status});

  final BudgetStatus status;

  @override
  Widget build(BuildContext context) {
    final color = budgetLevelColor(context, status.alertLevel);
    final percent = status.usagePercent ?? 0;
    final String label;
    switch (status.alertLevel) {
      case BudgetAlertLevel.exceeded:
        label = 'Exceeded';
      case BudgetAlertLevel.warning:
        label = 'Warning';
      case BudgetAlertLevel.approaching:
        label = 'Alert';
      case BudgetAlertLevel.none:
        label = 'On track';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label · ${percent.toStringAsFixed(0)}%',
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// "AED 120.00 of AED 500.00 ... AED 380.00 left" under a progress bar.
///
/// Both amounts stay whole: when they do not fit side by side (narrow phone,
/// large amounts or a large font) the second one moves to its own line
/// instead of overflowing.
class SpentOfTargetLine extends StatelessWidget {
  const SpentOfTargetLine({
    super.key,
    required this.spent,
    required this.remaining,
    required this.remainingColor,
    this.spentStyle,
  });

  /// e.g. "AED 120.00 of AED 500.00".
  final String spent;

  /// e.g. "AED 380.00 left".
  final String remaining;
  final Color remainingColor;
  final TextStyle? spentStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: Spacing.md,
      runSpacing: 2,
      children: [
        Text(spent, style: spentStyle ?? theme.textTheme.bodySmall),
        Text(
          remaining,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: remainingColor,
          ),
        ),
      ],
    );
  }
}
