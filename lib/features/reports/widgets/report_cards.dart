import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/providers/report_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/category_avatar.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';
import 'package:money_mate/shared/widgets/stat_widgets.dart';

/// Income, expenses and savings for the selected range.
class SavingsSummaryCard extends StatelessWidget {
  const SavingsSummaryCard({
    super.key,
    required this.data,
    required this.formatter,
  });

  final ReportData data;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final savings = data.savingsMinor;
    final rate = data.totals.savingsRate;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Total savings'),
          const SizedBox(height: Spacing.sm),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatter.formatSigned(savings),
              key: const Key('reportSavings'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: savings >= 0 ? finance.income : finance.expense,
              ),
            ),
          ),
          Text(
            rate == null
                ? 'No income in this period'
                : 'You saved ${rate.toStringAsFixed(1)}% of your income',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: _Figure(
                  label: 'Income',
                  value: formatter.format(data.totals.incomeMinor),
                  color: finance.income,
                ),
              ),
              Expanded(
                child: _Figure(
                  label: 'Expenses',
                  value: formatter.format(data.totals.expenseMinor),
                  color: finance.expense,
                ),
              ),
              Expanded(
                child: _Figure(
                  label: 'Avg / day',
                  value: formatter.format(data.averageDailyExpenseMinor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.color});

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
        const SizedBox(height: 2),
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

/// Current month against the previous month.
class MonthComparisonCard extends StatelessWidget {
  const MonthComparisonCard({
    super.key,
    required this.data,
    required this.formatter,
  });

  final ReportData data;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = data.currentMonth;
    final previous = data.previousMonth;
    final f = DateFormat('MMMM');

    Widget row(
      String label,
      int now,
      int before,
      double? change, {
      required bool increaseIsGood,
      Color? color,
    }) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
            Expanded(
              flex: 4,
              child: Text(
                formatter.format(before),
                textAlign: TextAlign.end,
                style: theme.textTheme.bodySmall,
              ),
            ),
            Expanded(
              flex: 4,
              child: Text(
                formatter.format(now),
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
            SizedBox(
              width: 64,
              child: Align(
                alignment: Alignment.centerRight,
                child: ChangeBadge(
                  percent: change,
                  increaseIsGood: increaseIsGood,
                  // Nothing last month: "New" if there is something now.
                  emptyLabel: now == 0 ? '–' : 'New',
                ),
              ),
            ),
          ],
        ),
      );
    }

    final header = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Previous month comparison'),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              const Expanded(flex: 3, child: SizedBox()),
              Expanded(
                flex: 4,
                child: Text(
                  f.format(previous.range.start),
                  textAlign: TextAlign.end,
                  style: header,
                ),
              ),
              Expanded(
                flex: 4,
                child: Text(
                  f.format(current.range.start),
                  textAlign: TextAlign.end,
                  style: header,
                ),
              ),
              const SizedBox(width: 64),
            ],
          ),
          row(
            'Income',
            current.incomeMinor,
            previous.incomeMinor,
            data.incomeChangePercent,
            increaseIsGood: true,
            color: context.finance.income,
          ),
          row(
            'Expenses',
            current.expenseMinor,
            previous.expenseMinor,
            data.expenseChangePercent,
            increaseIsGood: false,
            color: context.finance.expense,
          ),
          row(
            'Savings',
            current.netMinor,
            previous.netMinor,
            previous.netMinor == 0
                ? null
                : (current.netMinor - previous.netMinor) /
                      previous.netMinor.abs() *
                      100,
            increaseIsGood: true,
          ),
          if (previous.incomeMinor == 0 && previous.expenseMinor == 0) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              'No transactions in ${f.format(previous.range.start)}, so there '
              'is no % change yet. It will appear once both months have data.',
              style: header,
            ),
          ],
        ],
      ),
    );
  }
}

/// Ranked list of the categories with the highest spending.
class TopCategoriesCard extends StatelessWidget {
  const TopCategoriesCard({
    super.key,
    required this.data,
    required this.formatter,
  });

  final ReportData data;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = data.topCategories;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Highest spending categories'),
          const SizedBox(height: Spacing.sm),
          if (top.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
              child: Text(
                'No expenses in this period',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          for (var i = 0; i < top.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Text(
                      '${i + 1}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  CategoryAvatar(category: top[i].category, size: 36),
                  const SizedBox(width: Spacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LabelAmountRow(
                          label: Text(
                            top[i].category.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          amount: Text(
                            formatter.format(top[i].totalMinor),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: top[i].percent / 100,
                            minHeight: 6,
                            color: top[i].category.color,
                            backgroundColor: top[i].category.color.withValues(
                              alpha: 0.12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${top[i].percent.toStringAsFixed(1)}% of expenses',
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
