import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/money.dart';
import '../../../providers/report_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/charts.dart';
import '../../../shared/widgets/state_views.dart';
import '../../household/widgets/household_widgets.dart';
import '../widgets/report_cards.dart';

/// Analytics: charts, category breakdown, savings and comparisons.
class ReportsScreen extends StatelessWidget {
  const ReportsScreen({super.key});

  Future<void> _pickCustomRange(BuildContext context) async {
    final provider = context.read<ReportProvider>();
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: DateTimeRange(
        start: provider.range.start,
        end: provider.range.lastDay,
      ),
      helpText: 'Report period',
    );
    if (picked != null) {
      await provider.setCustomRange(picked.start, picked.end);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = context.watch<ReportProvider>();
    final formatter = context.watch<SettingsProvider>().formatter;
    final data = report.data;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(
            tooltip: 'Custom date range',
            icon: const Icon(Icons.date_range_rounded),
            onPressed: () => _pickCustomRange(context),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: report.refresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            const ViewScopeSelector(
              padding: EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.xs,
                Spacing.lg,
                Spacing.md,
              ),
            ),
            if (report.historyNote != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  0,
                  Spacing.lg,
                  Spacing.md,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        report.historyNote!,
                        key: const Key('reportHistoryNote'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Row(
                children: [
                  for (final p in ReportRangePreset.values)
                    Padding(
                      padding: const EdgeInsets.only(right: Spacing.sm),
                      child: ChoiceChip(
                        label: Text(p.label),
                        selected: report.preset == p,
                        onSelected: (_) => p == ReportRangePreset.custom
                            ? _pickCustomRange(context)
                            : report.selectPreset(p),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.sm,
                Spacing.lg,
                Spacing.md,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.event_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: Spacing.xs),
                  Flexible(
                    child: Text(
                      report.rangeLabel,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (report.isLoading) ...[
                    const SizedBox(width: Spacing.sm),
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ],
                ],
              ),
            ),
            if (data == null && report.error != null)
              ErrorState(message: report.error!, onRetry: report.refresh)
            else if (data == null)
              const LoadingView()
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
                child: _ReportBody(data: data, formatter: formatter),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.data, required this.formatter});

  final ReportData data;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final finance = context.finance;
    final dayFormat = data.dailyExpenses.length > 31
        ? DateFormat('d/M')
        : DateFormat('d');
    final gap = const SizedBox(height: Spacing.lg);

    return Column(
      children: [
        SavingsSummaryCard(data: data, formatter: formatter),
        gap,
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                title: 'Daily expenses',
                subtitle: 'Spending per day in the selected period',
              ),
              const SizedBox(height: Spacing.lg),
              DailyLineChart(
                days: data.dailyExpenses,
                formatter: formatter,
                labelFor: dayFormat.format,
                color: finance.expense,
              ),
            ],
          ),
        ),
        gap,
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                title: 'Weekly expenses',
                subtitle: 'Last ${ReportProvider.weeksShown} weeks',
              ),
              const SizedBox(height: Spacing.lg),
              SimpleBarChart(
                items: [
                  for (final w in data.weeklyTotals)
                    BarItem(
                      label: DateFormat('d/M').format(w.range.start),
                      valueMinor: w.expenseMinor,
                    ),
                ],
                formatter: formatter,
                color: finance.expense,
                highlightIndex: data.weeklyTotals.length - 1,
              ),
            ],
          ),
        ),
        gap,
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                title: 'Monthly expenses',
                subtitle: 'Last ${ReportProvider.monthsShown} months',
              ),
              const SizedBox(height: Spacing.lg),
              SimpleBarChart(
                items: [
                  for (final m in data.monthlyTotals)
                    BarItem(
                      label: DateFormat('MMM').format(m.range.start),
                      valueMinor: m.expenseMinor,
                    ),
                ],
                formatter: formatter,
                color: AppColors.warning,
                highlightIndex: data.monthlyTotals.length - 1,
              ),
            ],
          ),
        ),
        gap,
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionHeader(
                title: 'Income vs expenses',
                subtitle: 'Last ${ReportProvider.monthsShown} months',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Dot(color: finance.income, label: 'Income'),
                    const SizedBox(width: Spacing.sm),
                    _Dot(color: finance.expense, label: 'Expense'),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
              IncomeExpenseChart(
                periods: data.monthlyTotals,
                labels: [
                  for (final m in data.monthlyTotals)
                    DateFormat('MMM').format(m.range.start),
                ],
                formatter: formatter,
              ),
            ],
          ),
        ),
        gap,
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                title: 'Expenses by category',
                subtitle: 'Selected period',
              ),
              const SizedBox(height: Spacing.lg),
              if (data.categoryShares.isEmpty)
                const EmptyState(
                  icon: Icons.pie_chart_outline_rounded,
                  title: 'No expenses in this period',
                  compact: true,
                )
              else
                CategoryDonutChart(
                  shares: data.categoryShares,
                  formatter: formatter,
                  maxLegendItems: 6,
                  size: 170,
                ),
            ],
          ),
        ),
        gap,
        TopCategoriesCard(data: data, formatter: formatter),
        gap,
        MonthComparisonCard(data: data, formatter: formatter),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 4),
      Text(label, style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}
