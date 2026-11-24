import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../models/report_models.dart';

/// Rounds [maxValue] up to an axis maximum whose quarter is a "nice"
/// whole number (1, 2 or 5 × 10ⁿ), so the 4 grid lines get clean labels.
double niceAxisMax(double maxValue) {
  if (maxValue <= 0) return 100;
  final rawInterval = maxValue / 4;
  final magnitude = math
      .pow(10, (math.log(rawInterval) / math.ln10).floor())
      .toDouble();
  final normalized = rawInterval / magnitude;
  const steps = [1.0, 2.0, 2.5, 4.0, 5.0, 10.0];
  final nice = steps.firstWhere(
    // 2.5 would give fractional labels for single-digit intervals.
    (step) => normalized <= step && !(step == 2.5 && magnitude < 10),
  );
  // Keep labels whole numbers for small amounts.
  final interval = math.max(1.0, nice * magnitude);
  return interval * 4;
}

/// A single bar in [SimpleBarChart].
class BarItem {
  const BarItem({required this.label, required this.valueMinor, this.target});

  final String label;
  final int valueMinor;

  /// Optional target line value (minor units) drawn behind the bar.
  final int? target;
}

/// Vertical bar chart for amounts (minor units).
class SimpleBarChart extends StatelessWidget {
  const SimpleBarChart({
    super.key,
    required this.items,
    required this.formatter,
    this.color,
    this.highlightIndex,
    this.height = 180,
    this.showTargets = false,
  });

  final List<BarItem> items;
  final CurrencyFormatter formatter;
  final Color? color;
  final int? highlightIndex;
  final double height;
  final bool showTargets;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final barColor = color ?? theme.colorScheme.primary;
    final maxValue = items.fold<int>(
      0,
      (m, i) => math.max(
        m,
        math.max(i.valueMinor, showTargets ? (i.target ?? 0) : 0),
      ),
    );
    final maxY = niceAxisMax(Money.toMajor(maxValue));
    final barWidth = items.length > 20
        ? 6.0
        : items.length > 10
        ? 10.0
        : 18.0;

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          minY: 0,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: maxY / 4,
            getDrawingHorizontalLine: (_) => FlLine(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
              strokeWidth: 1,
              dashArray: [4, 4],
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: maxY / 4,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    CurrencyFormatter.axis(value),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= items.length) return const SizedBox();
                  // Thin out labels when there are many bars.
                  final step = (items.length / 8).ceil();
                  if (items.length > 10 && i % step != 0) {
                    return const SizedBox();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      items[i].label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontWeight: i == highlightIndex
                            ? FontWeight.w800
                            : FontWeight.w500,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => theme.colorScheme.inverseSurface,
              getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
                '${items[group.x].label}\n${formatter.format(items[group.x].valueMinor)}',
                TextStyle(
                  color: theme.colorScheme.onInverseSurface,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          extraLinesData: ExtraLinesData(
            horizontalLines: [
              if (showTargets &&
                  items.isNotEmpty &&
                  items.last.target != null &&
                  items.last.target! > 0)
                HorizontalLine(
                  y: Money.toMajor(items.last.target!),
                  color: context.finance.expense.withValues(alpha: 0.6),
                  strokeWidth: 1.5,
                  dashArray: [6, 4],
                ),
            ],
          ),
          barGroups: [
            for (var i = 0; i < items.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: Money.toMajor(items[i].valueMinor),
                    width: barWidth,
                    color: _barColor(context, i, barColor),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(barWidth / 2),
                    ),
                    backDrawRodData: BackgroundBarChartRodData(
                      show: true,
                      toY: maxY,
                      color: barColor.withValues(alpha: 0.06),
                    ),
                  ),
                ],
              ),
          ],
        ),
        duration: const Duration(milliseconds: 400),
      ),
    );
  }

  Color _barColor(BuildContext context, int i, Color base) {
    final item = items[i];
    if (showTargets && item.target != null && item.target! > 0) {
      return item.valueMinor >= item.target!
          ? context.finance.expense
          : context.finance.income;
    }
    if (highlightIndex == null) return base;
    return i == highlightIndex ? base : base.withValues(alpha: 0.45);
  }
}

/// Paired income / expense bars per period.
class IncomeExpenseChart extends StatelessWidget {
  const IncomeExpenseChart({
    super.key,
    required this.periods,
    required this.labels,
    required this.formatter,
    this.height = 200,
  });

  final List<PeriodTotals> periods;
  final List<String> labels;
  final CurrencyFormatter formatter;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final maxValue = periods.fold<int>(
      0,
      (m, p) => math.max(m, math.max(p.incomeMinor, p.expenseMinor)),
    );
    final maxY = niceAxisMax(Money.toMajor(maxValue));

    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          minY: 0,
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: maxY / 4,
            getDrawingHorizontalLine: (_) => FlLine(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
              strokeWidth: 1,
              dashArray: [4, 4],
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: maxY / 4,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    CurrencyFormatter.axis(value),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= labels.length) return const SizedBox();
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(labels[i], style: theme.textTheme.labelSmall),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => theme.colorScheme.inverseSurface,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final p = periods[group.x];
                final isIncome = rodIndex == 0;
                return BarTooltipItem(
                  '${isIncome ? 'Income' : 'Expense'}\n'
                  '${formatter.format(isIncome ? p.incomeMinor : p.expenseMinor)}',
                  TextStyle(
                    color: theme.colorScheme.onInverseSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < periods.length; i++)
              BarChartGroupData(
                x: i,
                barsSpace: 4,
                barRods: [
                  BarChartRodData(
                    toY: Money.toMajor(periods[i].incomeMinor),
                    width: 10,
                    color: finance.income,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                  ),
                  BarChartRodData(
                    toY: Money.toMajor(periods[i].expenseMinor),
                    width: 10,
                    color: finance.expense,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                  ),
                ],
              ),
          ],
        ),
        duration: const Duration(milliseconds: 400),
      ),
    );
  }
}

/// Smooth line chart of daily totals.
class DailyLineChart extends StatelessWidget {
  const DailyLineChart({
    super.key,
    required this.days,
    required this.formatter,
    required this.labelFor,
    this.color,
    this.height = 180,
  });

  final List<DailyTotal> days;
  final CurrencyFormatter formatter;
  final String Function(DateTime day) labelFor;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lineColor = color ?? context.finance.expense;
    final maxValue = days.fold<int>(0, (m, d) => math.max(m, d.totalMinor));
    final maxY = niceAxisMax(Money.toMajor(maxValue));
    final labelStep = math.max(1, (days.length / 6).ceil());

    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          minX: 0,
          maxX: math.max(0, days.length - 1).toDouble(),
          gridData: FlGridData(
            drawVerticalLine: false,
            horizontalInterval: maxY / 4,
            getDrawingHorizontalLine: (_) => FlLine(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
              strokeWidth: 1,
              dashArray: [4, 4],
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: maxY / 4,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  child: Text(
                    CurrencyFormatter.axis(value),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= days.length || i % labelStep != 0) {
                    return const SizedBox();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      labelFor(days[i].day),
                      style: theme.textTheme.labelSmall,
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => theme.colorScheme.inverseSurface,
              getTooltipItems: (spots) => spots
                  .map(
                    (s) => LineTooltipItem(
                      '${labelFor(days[s.x.toInt()].day)}\n'
                      '${formatter.format(days[s.x.toInt()].totalMinor)}',
                      TextStyle(
                        color: theme.colorScheme.onInverseSurface,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < days.length; i++)
                  FlSpot(i.toDouble(), Money.toMajor(days[i].totalMinor)),
              ],
              isCurved: true,
              preventCurveOverShooting: true,
              color: lineColor,
              barWidth: 2.5,
              dotData: FlDotData(show: days.length <= 14),
              belowBarData: BarAreaData(
                show: true,
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    lineColor.withValues(alpha: 0.25),
                    lineColor.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ],
        ),
        duration: const Duration(milliseconds: 400),
      ),
    );
  }
}

/// Donut chart with a legend for category shares.
class CategoryDonutChart extends StatefulWidget {
  const CategoryDonutChart({
    super.key,
    required this.shares,
    required this.formatter,
    this.maxLegendItems = 5,
    this.size = 150,
  });

  final List<CategoryShare> shares;
  final CurrencyFormatter formatter;
  final int maxLegendItems;
  final double size;

  @override
  State<CategoryDonutChart> createState() => _CategoryDonutChartState();
}

class _CategoryDonutChartState extends State<CategoryDonutChart> {
  int? _touched;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shares = widget.shares;
    final total = shares.fold<int>(0, (s, c) => s + c.totalMinor);
    final touched = _touched != null && _touched! < shares.length
        ? shares[_touched!]
        : null;

    final chart = SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: widget.size * 0.3,
              startDegreeOffset: -90,
              pieTouchData: PieTouchData(
                touchCallback: (event, response) {
                  setState(() {
                    if (!event.isInterestedForInteractions ||
                        response?.touchedSection == null) {
                      _touched = null;
                      return;
                    }
                    final index = response!.touchedSection!.touchedSectionIndex;
                    _touched = index < 0 ? null : index;
                  });
                },
              ),
              sections: [
                for (var i = 0; i < shares.length; i++)
                  PieChartSectionData(
                    value: shares[i].totalMinor.toDouble(),
                    color: shares[i].category.color,
                    radius: i == _touched
                        ? widget.size * 0.2
                        : widget.size * 0.16,
                    showTitle: false,
                  ),
              ],
            ),
            duration: const Duration(milliseconds: 300),
          ),
          Padding(
            padding: EdgeInsets.all(widget.size * 0.22),
            child: FittedBox(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    touched?.category.name ?? 'Total',
                    style: theme.textTheme.labelSmall,
                  ),
                  Text(
                    widget.formatter.compact(touched?.totalMinor ?? total),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    final legendItems = shares.take(widget.maxLegendItems).toList();
    final otherTotal = shares
        .skip(widget.maxLegendItems)
        .fold<int>(0, (s, c) => s + c.totalMinor);

    final legend = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in legendItems)
          _LegendRow(
            color: s.category.color,
            label: s.category.name,
            value: '${s.percent.toStringAsFixed(0)}%',
          ),
        if (otherTotal > 0)
          _LegendRow(
            color: theme.colorScheme.outline,
            label: 'Others',
            value: '${(otherTotal / total * 100).toStringAsFixed(0)}%',
          ),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 300) {
          return Column(
            children: [
              chart,
              const SizedBox(height: Spacing.lg),
              legend,
            ],
          );
        }
        return Row(
          children: [
            chart,
            const SizedBox(width: Spacing.xl),
            Expanded(child: legend),
          ],
        );
      },
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.value,
  });

  final Color color;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
