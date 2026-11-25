import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/features/lending/lending_actions.dart';
import 'package:money_mate/features/lending/widgets/lending_widgets.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';
import 'package:money_mate/shared/widgets/stat_widgets.dart';
import 'package:money_mate/shared/widgets/state_views.dart';

/// Money lent: overview, borrowers and a lending summary.
class LendingScreen extends StatefulWidget {
  const LendingScreen({super.key, this.initialFilter = LoanFilter.all});

  final LoanFilter initialFilter;

  @override
  State<LendingScreen> createState() => _LendingScreenState();
}

class _LendingScreenState extends State<LendingScreen> {
  late LoanFilter _filter = widget.initialFilter;

  @override
  void initState() {
    super.initState();
    final loans = context.read<LoanProvider>();
    if (!loans.hasLoaded) loans.load();
  }

  Future<void> _refresh() async {
    final sync = context.read<SyncProvider>();
    final loans = context.read<LoanProvider>();
    if (sync.phase != SyncPhase.unavailable) await sync.syncNow();
    await loans.load();
  }

  @override
  Widget build(BuildContext context) {
    final loans = context.watch<LoanProvider>();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final filters = [
      LoanFilter.all,
      if (loans.hasHousehold || loans.loans.any((s) => s.loan.isHousehold)) ...[
        LoanFilter.personal,
        LoanFilter.household,
      ],
      LoanFilter.active,
      LoanFilter.overdue,
      LoanFilter.completed,
    ];
    final filterBar = SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        children: [
          for (final f in filters)
            Padding(
              padding: const EdgeInsets.only(right: Spacing.sm),
              child: ChoiceChip(
                key: Key('loanFilter-${f.name}'),
                label: Text(f.label),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Money lent'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Borrowers'),
              Tab(text: 'Summary'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const Key('lendMoneyButton'),
          onPressed: () =>
              openLoanForm(context, household: _filter == LoanFilter.household),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Lend money'),
        ),
        body: Builder(
          builder: (context) {
            if (!loans.hasLoaded && loans.isLoading) return const LoadingView();
            if (loans.error != null && loans.loans.isEmpty) {
              return ErrorState(message: loans.error!, onRetry: loans.load);
            }
            return TabBarView(
              children: [
                RefreshIndicator(
                  onRefresh: _refresh,
                  child: _OverviewTab(
                    filter: _filter,
                    filterBar: filterBar,
                    formatter: formatter,
                  ),
                ),
                RefreshIndicator(
                  onRefresh: _refresh,
                  child: _BorrowersTab(
                    filter: _filter,
                    filterBar: filterBar,
                    formatter: formatter,
                  ),
                ),
                _SummaryTab(formatter: formatter),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.filter,
    required this.filterBar,
    required this.formatter,
  });

  final LoanFilter filter;
  final Widget filterBar;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final loans = context.watch<LoanProvider>();
    final finance = context.finance;
    final theme = Theme.of(context);
    final list = loans.filtered(filter);
    if (loans.loans.isEmpty) {
      return ListView(
        children: [
          EmptyState(
            icon: Icons.handshake_outlined,
            title: 'No money lent yet',
            message:
                'Record money you lend to someone and track every repayment, '
                'with reminders when they are due.',
            actionLabel: 'Lend money',
            onAction: () => openLoanForm(context),
          ),
        ],
      );
    }
    final summary = LoanCalculator.summarize(list);
    final overdue = loans.overdue(filter);
    final upcoming = loans.upcoming(filter, limit: 8);
    final recent = loans.recentRepayments(filter, limit: 5);
    final active = [
      for (final s in list)
        if (!s.isCompleted) s,
    ];
    final completed = [
      for (final s in list)
        if (s.isCompleted) s,
    ];

    Widget pair(Widget a, Widget b) => Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: Spacing.md),
        Expanded(child: b),
      ],
    );

    return ListView(
      padding: const EdgeInsets.only(top: Spacing.sm, bottom: 96),
      children: [
        filterBar,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: Spacing.sm),
              pair(
                StatCard(
                  key: const Key('statTotalLent'),
                  icon: Icons.north_east_rounded,
                  label: 'Total lent',
                  value: formatter.format(summary.lentMinor),
                  color: theme.colorScheme.primary,
                ),
                StatCard(
                  key: const Key('statTotalReceived'),
                  icon: Icons.south_west_rounded,
                  label: 'Total received',
                  value: formatter.format(summary.receivedMinor),
                  color: finance.income,
                ),
              ),
              const SizedBox(height: Spacing.md),
              StatCard(
                key: const Key('statOutstanding'),
                icon: Icons.account_balance_wallet_outlined,
                label: 'Total outstanding',
                value: formatter.format(summary.outstandingMinor),
                color: AppColors.warning,
                footer: summary.interestReceivedMinor > 0
                    ? Text(
                        'Interest received: '
                        '${formatter.format(summary.interestReceivedMinor)}',
                        style: theme.textTheme.bodySmall,
                      )
                    : null,
              ),
              const SizedBox(height: Spacing.md),
              pair(
                StatCard(
                  key: const Key('statActive'),
                  icon: Icons.handshake_outlined,
                  label: 'Active records',
                  value: '${summary.activeCount}',
                  color: theme.colorScheme.primary,
                ),
                StatCard(
                  key: const Key('statOverdue'),
                  icon: Icons.warning_amber_rounded,
                  label: 'Overdue records',
                  value: '${summary.overdueCount}',
                  color: finance.expense,
                ),
              ),
              if (list.isEmpty)
                const EmptyState(
                  compact: true,
                  icon: Icons.filter_alt_off_outlined,
                  title: 'Nothing matches this filter',
                ),
              if (overdue.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                AppCard(
                  key: const Key('overdueSection'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        title: 'Overdue repayments',
                        subtitle: formatter.format(summary.overdueMinor),
                      ),
                      for (final d in overdue)
                        DueInstallmentTile(due: d, formatter: formatter),
                    ],
                  ),
                ),
              ],
              if (upcoming.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                AppCard(
                  key: const Key('upcomingSection'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'Upcoming repayments'),
                      for (final d in upcoming)
                        DueInstallmentTile(due: d, formatter: formatter),
                    ],
                  ),
                ),
              ],
              if (recent.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                AppCard(
                  key: const Key('recentSection'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'Recently received'),
                      for (final r in recent)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          onTap: () => openLoanDetails(context, r.snapshot.id),
                          leading: Icon(
                            Icons.south_west_rounded,
                            color: finance.income,
                          ),
                          title: Text(r.snapshot.loan.borrowerName),
                          subtitle: Text(
                            '${lendingDate.format(r.repayment.date)} · '
                            '${r.repayment.method.label}',
                          ),
                          trailing: Text(
                            formatter.format(r.repayment.amountMinor),
                            style: TextStyle(
                              color: finance.income,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (active.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                SectionHeader(
                  title: 'Active lending',
                  subtitle: '${active.length} record(s)',
                ),
                const SizedBox(height: Spacing.sm),
                for (final s in active) ...[
                  LoanTile(snapshot: s, formatter: formatter),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
              if (completed.isNotEmpty) ...[
                const SizedBox(height: Spacing.lg),
                SectionHeader(
                  title: 'Completed',
                  subtitle: '${completed.length} record(s)',
                ),
                const SizedBox(height: Spacing.sm),
                for (final s in completed) ...[
                  LoanTile(snapshot: s, formatter: formatter),
                  const SizedBox(height: Spacing.sm),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BorrowersTab extends StatelessWidget {
  const _BorrowersTab({
    required this.filter,
    required this.filterBar,
    required this.formatter,
  });

  final LoanFilter filter;
  final Widget filterBar;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borrowers = context.watch<LoanProvider>().borrowers(filter);
    return ListView(
      padding: const EdgeInsets.only(top: Spacing.sm, bottom: 96),
      children: [
        filterBar,
        if (borrowers.isEmpty)
          const EmptyState(
            icon: Icons.people_outline_rounded,
            title: 'No borrowers here yet',
          ),
        for (final b in borrowers)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.sm,
              Spacing.lg,
              0,
            ),
            child: AppCard(
              key: Key('borrower-${b.key}'),
              onTap: () => openBorrower(context, b.key),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LabelAmountRow(
                    label: Text(b.name, style: theme.textTheme.titleSmall),
                    amount: Text(
                      formatter.format(b.outstandingMinor),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    '${b.loans.length} record(s) · ${b.activeCount} active · '
                    '${b.completedCount} completed\n'
                    'Lent ${formatter.format(b.lentMinor)} · received '
                    '${formatter.format(b.receivedMinor)}'
                    '${b.overdueMinor > 0 ? ' · overdue ${formatter.format(b.overdueMinor)}' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

enum _SummaryStatus {
  all('Any status'),
  active('Active'),
  overdue('Overdue'),
  completed('Completed');

  const _SummaryStatus(this.label);

  final String label;
}

enum _SummaryScope {
  all('All'),
  personal('Personal'),
  household('Household');

  const _SummaryScope(this.label);

  final String label;
}

/// Lending figures with their own filters. Lending is not income or an
/// expense, so these figures never appear in the ordinary reports; only
/// the interest received is income.
class _SummaryTab extends StatefulWidget {
  const _SummaryTab({required this.formatter});

  final CurrencyFormatter formatter;

  @override
  State<_SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<_SummaryTab> {
  _SummaryScope _scope = _SummaryScope.all;
  _SummaryStatus _status = _SummaryStatus.all;
  String? _borrower;
  DateTimeRange? _range;

  Future<void> _pickRange() async {
    final today = PeriodUtils.dateOnly(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 50),
      lastDate: today,
      initialDateRange: _range,
      helpText: 'Money lent between',
    );
    if (picked != null) setState(() => _range = picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loans = context.watch<LoanProvider>();
    final f = widget.formatter;
    final all = loans.loans;
    final borrowers = LoanCalculator.byBorrower(all);
    final selected = [
      for (final s in all)
        if (switch (_scope) {
              _SummaryScope.all => true,
              _SummaryScope.personal => s.loan.isPersonal,
              _SummaryScope.household => s.loan.isHousehold,
            } &&
            switch (_status) {
              _SummaryStatus.all => true,
              _SummaryStatus.active => !s.isCompleted,
              _SummaryStatus.overdue => s.isOverdue,
              _SummaryStatus.completed => s.isCompleted,
            } &&
            (_borrower == null ||
                LoanCalculator.borrowerKey(s.loan.borrowerName) == _borrower) &&
            (_range == null ||
                (!s.loan.lentDate.isBefore(_range!.start) &&
                    !s.loan.lentDate.isAfter(_range!.end))))
          s,
    ];
    final summary = LoanCalculator.summarize(selected);
    Widget row(String label, int minor, {Key? key, Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LabelAmountRow(
        label: Text(label),
        amount: Text(
          f.format(minor),
          key: key,
          style: TextStyle(fontWeight: FontWeight.w700, color: color),
        ),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.md,
        Spacing.lg,
        96,
      ),
      children: [
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<_SummaryScope>(
              key: const Key('summaryScope'),
              value: _scope,
              items: [
                for (final s in _SummaryScope.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (s) => setState(() => _scope = s ?? _scope),
            ),
            DropdownButton<_SummaryStatus>(
              key: const Key('summaryStatus'),
              value: _status,
              items: [
                for (final s in _SummaryStatus.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (s) => setState(() => _status = s ?? _status),
            ),
            DropdownButton<String?>(
              key: const Key('summaryBorrower'),
              value: _borrower,
              items: [
                const DropdownMenuItem(value: null, child: Text('Everyone')),
                for (final b in borrowers)
                  DropdownMenuItem(value: b.key, child: Text(b.name)),
              ],
              onChanged: (b) => setState(() => _borrower = b),
            ),
            ActionChip(
              key: const Key('summaryRange'),
              avatar: const Icon(Icons.date_range_rounded, size: 18),
              label: Text(
                _range == null
                    ? 'Any date'
                    : '${lendingShortDate.format(_range!.start)} – '
                          '${lendingDate.format(_range!.end)}',
              ),
              onPressed: _pickRange,
            ),
            if (_range != null)
              IconButton(
                tooltip: 'Any date',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(() => _range = null),
              ),
          ],
        ),
        const SizedBox(height: Spacing.md),
        AppCard(
          key: const Key('lendingSummaryCard'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(title: 'Lending summary'),
              const SizedBox(height: Spacing.sm),
              row('Total lent', summary.lentMinor, key: const Key('sumLent')),
              row(
                'Principal received',
                summary.principalReceivedMinor,
                key: const Key('sumPrincipal'),
              ),
              row(
                'Interest received',
                summary.interestReceivedMinor,
                key: const Key('sumInterest'),
                color: context.finance.income,
              ),
              row(
                'Outstanding principal',
                summary.outstandingPrincipalMinor,
                key: const Key('sumOutstandingPrincipal'),
              ),
              row(
                'Overdue principal',
                summary.overduePrincipalMinor,
                key: const Key('sumOverduePrincipal'),
                color: summary.overduePrincipalMinor > 0
                    ? context.finance.expense
                    : null,
              ),
              const Divider(height: Spacing.xl),
              LabelAmountRow(
                label: const Text('Active records'),
                amount: Text('${summary.activeCount}'),
              ),
              const SizedBox(height: Spacing.sm),
              LabelAmountRow(
                label: const Text('Completed records'),
                amount: Text('${summary.completedCount}'),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.md),
        Text(
          'Lending is not counted as an expense, and repaid principal is not '
          'income, so your income, expense and budget reports are unchanged. '
          'Only interest received is income from lending.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
