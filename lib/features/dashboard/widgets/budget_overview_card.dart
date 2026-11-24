import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/budget_progress_bar.dart';

/// Weekly and monthly budget progress on the dashboard, for the current
/// view: personal budgets, or the household's shared budgets.
class BudgetOverviewCard extends StatelessWidget {
  const BudgetOverviewCard({
    super.key,
    required this.formatter,
    required this.onOpenBudget,
  });

  final CurrencyFormatter formatter;
  final VoidCallback onOpenBudget;

  @override
  Widget build(BuildContext context) {
    final view = context.watch<TransactionScopeProvider>();
    final budgets = context.watch<BudgetProvider>();
    final household = view.householdId;
    final shared = household != null && view.view == ViewScope.shared;
    final scope = shared
        ? DataScope.household(household)
        : const DataScope.personal();
    final set = budgets.setFor(scope);

    return AppCard(
      onTap: onOpenBudget,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: shared ? 'Household budget progress' : 'Budget progress',
            actionLabel: 'Manage',
            onAction: onOpenBudget,
          ),
          const SizedBox(height: Spacing.sm),
          _BudgetRow(
            title: 'This week',
            subtitle: set == null
                ? null
                : PeriodUtils.weekLabel(set.weekly.range),
            status: set?.weekly,
            formatter: formatter,
          ),
          const SizedBox(height: Spacing.lg),
          _BudgetRow(
            title: 'This month',
            subtitle: set == null
                ? null
                : PeriodUtils.monthLabel(set.monthly.range),
            status: set?.monthly,
            formatter: formatter,
          ),
        ],
      ),
    );
  }
}

class _BudgetRow extends StatelessWidget {
  const _BudgetRow({
    required this.title,
    required this.subtitle,
    required this.status,
    required this.formatter,
  });

  final String title;
  final String? subtitle;
  final BudgetStatus? status;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = status;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (s == null || !s.hasTarget) {
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyLarge),
                Text(
                  s == null
                      ? 'Loading…'
                      : 'Spent ${formatter.format(s.spentMinor)} · no target set',
                  style: muted,
                ),
              ],
            ),
          ),
          Icon(
            Icons.add_circle_outline_rounded,
            color: theme.colorScheme.primary,
          ),
        ],
      );
    }

    final remaining = s.remainingMinor!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyLarge),
                  if (subtitle != null) Text(subtitle!, style: muted),
                ],
              ),
            ),
            BudgetLevelChip(status: s),
          ],
        ),
        const SizedBox(height: Spacing.sm),
        BudgetProgressBar(progress: s.progress, level: s.alertLevel),
        const SizedBox(height: Spacing.xs + 2),
        SpentOfTargetLine(
          spent:
              '${formatter.format(s.spentMinor)} of '
              '${formatter.format(s.targetMinor!)}',
          spentStyle: muted,
          remaining: remaining >= 0
              ? '${formatter.format(remaining)} left'
              : '${formatter.format(-remaining)} over',
          remainingColor: remaining >= 0
              ? context.finance.income
              : context.finance.expense,
        ),
      ],
    );
  }
}
