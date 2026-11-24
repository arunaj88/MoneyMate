import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/budget_progress_bar.dart';
import 'package:money_mate/shared/widgets/charts.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';

/// Spending history for past weeks or months against their targets.
class BudgetHistoryCard extends StatelessWidget {
  const BudgetHistoryCard({
    super.key,
    required this.period,
    required this.history,
    required this.formatter,
  });

  final BudgetPeriod period;

  /// Newest first.
  final List<BudgetStatus> history;
  final CurrencyFormatter formatter;

  String _shortLabel(BudgetStatus s) => period == BudgetPeriod.weekly
      ? DateFormat('d/M').format(s.range.start)
      : DateFormat('MMM').format(s.range.start);

  String _longLabel(BudgetStatus s, int index) {
    if (index == 0) {
      return period == BudgetPeriod.weekly ? 'This week' : 'This month';
    }
    return period == BudgetPeriod.weekly
        ? PeriodUtils.weekLabel(s.range)
        : PeriodUtils.monthLabel(s.range);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chronological = history.reversed.toList();
    final hasAnyTarget = history.any((h) => h.hasTarget);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: '${period.label} spending history',
            subtitle:
                'Last ${history.length} ${period.noun}s'
                '${hasAnyTarget ? ' · green = within target' : ''}',
          ),
          const SizedBox(height: Spacing.lg),
          SimpleBarChart(
            items: [
              for (final s in chronological)
                BarItem(
                  label: _shortLabel(s),
                  valueMinor: s.spentMinor,
                  target: s.targetMinor,
                ),
            ],
            formatter: formatter,
            showTargets: hasAnyTarget,
            color: theme.colorScheme.primary,
            highlightIndex: chronological.length - 1,
          ),
          const SizedBox(height: Spacing.md),
          for (var i = 0; i < history.length; i++)
            _HistoryRow(
              label: _longLabel(history[i], i),
              status: history[i],
              formatter: formatter,
            ),
        ],
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({
    required this.label,
    required this.status,
    required this.formatter,
  });

  final String label;
  final BudgetStatus status;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LabelAmountRow(
            label: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
            amount: Text(
              s.hasTarget
                  ? '${formatter.format(s.spentMinor)} / ${formatter.format(s.targetMinor!)}'
                  : formatter.format(s.spentMinor),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: Spacing.xs),
          if (s.hasTarget)
            Row(
              children: [
                Expanded(
                  child: BudgetProgressBar(
                    progress: s.progress,
                    level: s.alertLevel,
                    height: 6,
                  ),
                ),
                const SizedBox(width: Spacing.sm),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${s.usagePercent!.toStringAsFixed(0)}%',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: budgetLevelColor(context, s.alertLevel),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            )
          else
            Text(
              'No target',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
