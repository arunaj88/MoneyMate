import 'package:flutter/material.dart';

import '../../../core/services/budget_calculator.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/date_range.dart';
import '../../../core/utils/money.dart';
import '../../../models/budget_model.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/budget_progress_bar.dart';

/// Shows the current period's target, spending and remaining budget.
class BudgetTargetCard extends StatelessWidget {
  const BudgetTargetCard({
    super.key,
    required this.status,
    required this.formatter,
    required this.onEdit,
    required this.onRemove,
  });

  final BudgetStatus status;
  final CurrencyFormatter formatter;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final periodLabel = s.period == BudgetPeriod.weekly
        ? PeriodUtils.weekLabel(s.range)
        : PeriodUtils.monthLabel(s.range);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (!s.hasTarget) {
      return AppCard(
        child: Column(
          children: [
            const SizedBox(height: Spacing.sm),
            Icon(
              Icons.flag_outlined,
              size: 40,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: Spacing.md),
            Text(
              'No ${s.period.label.toLowerCase()} target yet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'You have spent ${formatter.format(s.spentMinor)} $periodLabel. '
              'Set a limit to track progress and get alerts at 80%, 90% and 100%.',
              textAlign: TextAlign.center,
              style: muted,
            ),
            const SizedBox(height: Spacing.lg),
            FilledButton.icon(
              key: Key('setTarget-${s.period.name}'),
              onPressed: onEdit,
              icon: const Icon(Icons.flag_rounded),
              label: Text('Set ${s.period.label.toLowerCase()} target'),
            ),
          ],
        ),
      );
    }

    final color = budgetLevelColor(context, s.alertLevel);
    final remaining = s.remainingMinor!;
    final allowance = BudgetCalculator.dailyAllowance(s, DateTime.now());

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${s.period.label} target',
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(periodLabel, style: muted),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Target options',
                onSelected: (v) => v == 'edit' ? onEdit() : onRemove(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Change target')),
                  PopupMenuItem(value: 'remove', child: Text('Remove target')),
                ],
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatter.format(s.spentMinor),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                '${s.usagePercent!.toStringAsFixed(1)}%',
                key: Key('usagePercent-${s.period.name}'),
                style: theme.textTheme.titleLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          Text('spent of ${formatter.format(s.targetMinor!)}', style: muted),
          const SizedBox(height: Spacing.md),
          BudgetProgressBar(
            progress: s.progress,
            level: s.alertLevel,
            height: 14,
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  label: remaining >= 0 ? 'Remaining' : 'Over budget',
                  value: formatter.format(remaining.abs()),
                  color: remaining >= 0
                      ? context.finance.income
                      : context.finance.expense,
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'Safe to spend / day',
                  value: allowance == null ? '—' : formatter.format(allowance),
                ),
              ),
              BudgetLevelChip(status: s),
            ],
          ),
          if (s.alertLevel != BudgetAlertLevel.none) ...[
            const SizedBox(height: Spacing.md),
            _AlertBanner(status: s),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _AlertBanner extends StatelessWidget {
  const _AlertBanner({required this.status});

  final BudgetStatus status;

  @override
  Widget build(BuildContext context) {
    final color = budgetLevelColor(context, status.alertLevel);
    final text = switch (status.alertLevel) {
      BudgetAlertLevel.exceeded =>
        'You have reached or exceeded this ${status.period.noun}\'s target.',
      BudgetAlertLevel.warning =>
        'Warning: over 90% of this ${status.period.noun}\'s target is used.',
      BudgetAlertLevel.approaching =>
        'Heads up: 80% of this ${status.period.noun}\'s target is used.',
      BudgetAlertLevel.none => '',
    };
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Spacing.radiusSm),
      ),
      child: Row(
        children: [
          Icon(
            status.isExceeded
                ? Icons.error_outline_rounded
                : Icons.warning_amber_rounded,
            color: color,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
