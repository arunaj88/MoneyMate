import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/money.dart';
import '../../../models/budget_model.dart';
import '../../../models/scope_models.dart';
import '../../../providers/budget_provider.dart';
import '../../../providers/household_provider.dart';
import '../../../providers/category_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/budget_progress_bar.dart';
import '../../../shared/widgets/category_avatar.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/state_views.dart';
import '../widgets/budget_history_card.dart';
import '../widgets/budget_target_card.dart';
import '../widgets/category_budget_sheet.dart';

/// Weekly and monthly targets, history and category budgets.
class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});

  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  BudgetPeriod _period = BudgetPeriod.weekly;

  Future<void> _editTarget(BudgetStatus status) async {
    final settings = context.read<SettingsProvider>();
    final provider = context.read<BudgetProvider>();
    final shared = provider.selectedScope.isHousehold;
    final amount = await showAmountDialog(
      context,
      title:
          '${shared ? 'Shared ' : ''}${status.period.label.toLowerCase()} '
          'spending target',
      message:
          'Applies from this ${status.period.noun} onwards. '
          'Past ${status.period.noun}s keep their original target.'
          '${shared ? ' Every household member sees this target.' : ''}',
      initialMinor: status.targetMinor,
      currencySymbol: settings.currency.symbol,
    );
    if (amount == null || !mounted) return;
    try {
      await provider.setTarget(status.period, amount);
      if (mounted) {
        showAppSnackBar(
          context,
          '${status.period.label} target set to ${settings.formatter.format(amount)}',
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Could not save target', isError: true);
      }
    }
  }

  Future<void> _removeTarget(BudgetStatus status) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove ${status.period.label.toLowerCase()} target?',
      message:
          'Tracking stops from this ${status.period.noun}. '
          'History for past ${status.period.noun}s is kept.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await context.read<BudgetProvider>().removeTarget(status.period);
  }

  @override
  Widget build(BuildContext context) {
    final budget = context.watch<BudgetProvider>();
    final formatter = context.watch<SettingsProvider>().formatter;
    final status = budget.statusFor(_period);
    final householdName = context.select<HouseholdProvider, String?>(
      (h) => h.household?.name,
    );
    final householdId = budget.householdId;

    Widget content;
    if (!budget.hasLoaded && budget.error != null) {
      content = ErrorState(message: budget.error!, onRetry: budget.refresh);
    } else if (status == null) {
      content = const LoadingView();
    } else {
      content = Column(
        children: [
          BudgetTargetCard(
            status: status,
            formatter: formatter,
            onEdit: () => _editTarget(status),
            onRemove: () => _removeTarget(status),
          ),
          const SizedBox(height: Spacing.lg),
          _CategoryBudgetsCard(period: _period, formatter: formatter),
          const SizedBox(height: Spacing.lg),
          BudgetHistoryCard(
            period: _period,
            history: budget.historyFor(_period),
            formatter: formatter,
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Budget')),
      body: RefreshIndicator(
        onRefresh: budget.refresh,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.xs,
            Spacing.lg,
            100,
          ),
          children: [
            if (householdId != null) ...[
              SegmentedButton<DataScope>(
                key: const Key('budgetScopeSelector'),
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(
                    value: DataScope.personal(),
                    label: Text('Personal'),
                    icon: Icon(Icons.person_outline_rounded),
                  ),
                  ButtonSegment(
                    value: DataScope.household(householdId),
                    label: const Text('Shared'),
                    icon: const Icon(Icons.group_outlined),
                  ),
                ],
                selected: {budget.selectedScope},
                onSelectionChanged: (s) => budget.selectScope(s.first),
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                budget.selectedScope.isHousehold
                    ? 'Shared with everyone in ${householdName ?? 'your household'}. '
                          'Counts shared expenses only.'
                    : 'Private to you. Counts personal expenses only.',
                key: const Key('budgetScopeHint'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.md),
            ],
            SegmentedButton<BudgetPeriod>(
              key: const Key('budgetPeriodSelector'),
              segments: const [
                ButtonSegment(
                  value: BudgetPeriod.weekly,
                  label: Text('Weekly'),
                  icon: Icon(Icons.view_week_rounded),
                ),
                ButtonSegment(
                  value: BudgetPeriod.monthly,
                  label: Text('Monthly'),
                  icon: Icon(Icons.calendar_month_rounded),
                ),
              ],
              selected: {_period},
              onSelectionChanged: (s) => setState(() => _period = s.first),
            ),
            const SizedBox(height: Spacing.lg),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: KeyedSubtree(
                key: ValueKey((_period, budget.selectedScope)),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBudgetsCard extends StatelessWidget {
  const _CategoryBudgetsCard({required this.period, required this.formatter});

  final BudgetPeriod period;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statuses = context.watch<BudgetProvider>().categoryStatusesFor(
      period,
    );
    final categories = context.watch<CategoryProvider>().byId;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Category budgets',
            subtitle: '${period.label} limits per category',
            trailing: IconButton.filledTonal(
              key: Key('addCategoryBudget-${period.name}'),
              tooltip: 'Add category budget',
              icon: const Icon(Icons.add_rounded),
              onPressed: () => showCategoryBudgetSheet(context, period: period),
            ),
          ),
          if (statuses.isEmpty)
            const EmptyState(
              icon: Icons.donut_small_rounded,
              title: 'No category budgets',
              message: 'Set limits like Food AED 500 or Fuel AED 250.',
              compact: true,
            )
          else
            for (final s in statuses)
              InkWell(
                borderRadius: BorderRadius.circular(Spacing.radiusSm),
                onTap: () => showCategoryBudgetSheet(
                  context,
                  period: period,
                  existing: s.budget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                  child: Row(
                    children: [
                      CategoryAvatar(
                        category: categories[s.budget.categoryId],
                        size: 40,
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    categories[s.budget.categoryId]?.name ??
                                        'Unknown',
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                Text(
                                  '${s.status.usagePercent!.toStringAsFixed(0)}%',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: budgetLevelColor(
                                      context,
                                      s.status.alertLevel,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: Spacing.xs + 2),
                            BudgetProgressBar(
                              progress: s.status.progress,
                              level: s.status.alertLevel,
                              height: 8,
                            ),
                            const SizedBox(height: Spacing.xs + 2),
                            SpentOfTargetLine(
                              spent:
                                  '${formatter.format(s.status.spentMinor)} of '
                                  '${formatter.format(s.budget.amountMinor)}',
                              remaining: s.status.remainingMinor! >= 0
                                  ? '${formatter.format(s.status.remainingMinor!)} left'
                                  : '${formatter.format(-s.status.remainingMinor!)} over',
                              remainingColor: s.status.remainingMinor! >= 0
                                  ? context.finance.income
                                  : context.finance.expense,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
