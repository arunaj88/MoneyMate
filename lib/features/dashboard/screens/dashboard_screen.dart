import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/dashboard_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/reset_provider.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/charts.dart';
import 'package:money_mate/shared/widgets/state_views.dart';
import 'package:money_mate/shared/widgets/stat_widgets.dart';
import 'package:money_mate/shared/widgets/transaction_tile.dart';
import 'package:money_mate/shared/widgets/user_avatar.dart';
import 'package:money_mate/features/household/widgets/household_widgets.dart';
import 'package:money_mate/features/savings/savings_actions.dart';
import 'package:money_mate/features/savings/widgets/savings_widgets.dart';
import 'package:money_mate/features/settings/reset_app.dart';
import 'package:money_mate/features/transactions/transaction_actions.dart';
import 'package:money_mate/features/dashboard/widgets/balance_card.dart';
import 'package:money_mate/features/dashboard/widgets/budget_overview_card.dart';

/// Home screen with balance, summaries, budgets and recent activity.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key, required this.onNavigate});

  /// Switches the bottom navigation tab (1 = transactions, 2 = budget,
  /// 3 = reports, 4 = settings).
  final ValueChanged<int> onNavigate;

  String _greeting(DateTime now) {
    if (now.hour < 12) return 'Good morning';
    if (now.hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  Future<void> _refresh(BuildContext context) async {
    final dashboard = context.read<DashboardProvider>();
    final sync = context.read<SyncProvider>();
    if (sync.phase != SyncPhase.unavailable) await sync.syncNow();
    await dashboard.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = context.watch<DashboardProvider>();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final user = context.select<AuthProvider, AppUser?>((a) => a.user);
    final data = dashboard.data;
    final now = DateTime.now();
    final theme = Theme.of(context);

    Widget body;
    if (data == null && dashboard.error != null) {
      body = Center(
        child: ErrorState(
          message: dashboard.error!,
          onRetry: dashboard.refresh,
        ),
      );
    } else if (data == null) {
      body = const LoadingView();
    } else {
      body = _DashboardContent(
        data: data,
        formatter: formatter,
        onNavigate: onNavigate,
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          // Pull to refresh is the manual sync: the spinner stays while the
          // sync runs, then the figures reload. Sync status itself lives in
          // Settings, not on the dashboard.
          onRefresh: () => _refresh(context),
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  Spacing.lg,
                  Spacing.lg,
                  Spacing.md,
                ),
                sliver: SliverToBoxAdapter(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                user == null
                                    ? '${_greeting(now)} 👋'
                                    : '${_greeting(now)}, ${user.firstName} 👋',
                                key: const Key('dashboardGreeting'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              Text(
                                AppConstants.appName,
                                style: theme.textTheme.headlineMedium,
                              ),
                            ],
                          ),
                        ),
                        // Natural size normally; only with a large font on a
                        // narrow phone does it shrink (to at most 40% of the
                        // row) instead of pushing the avatar off screen.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.4,
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(
                                alpha: 0.1,
                              ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                DateFormat('EEE, d MMM').format(now),
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: Spacing.md),
                        Tooltip(
                          message: 'Account',
                          child: InkResponse(
                            key: const Key('dashboardAvatar'),
                            radius: 24,
                            onTap: () => onNavigate(4),
                            child: UserAvatar(user: user, radius: 20),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(
                child: ViewScopeSelector(
                  padding: EdgeInsets.fromLTRB(
                    Spacing.lg,
                    0,
                    Spacing.lg,
                    Spacing.md,
                  ),
                ),
              ),
              SliverToBoxAdapter(child: body),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({
    required this.data,
    required this.formatter,
    required this.onNavigate,
  });

  final DashboardData data;
  final CurrencyFormatter formatter;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final finance = context.finance;
    final now = DateTime.now();
    final todayIndex = data.weekDailyExpenses.indexWhere(
      (d) => PeriodUtils.isSameDay(d.day, now),
    );

    final shared = !data.scope.includePersonal;
    final savingsAvailable = context.select<SavingsProvider, bool>(
      (s) => s.isAvailable,
    );
    // Personal goals belong to the personal view, the household's goals to
    // the household view; each reduces only its own balance.
    final ownership = shared
        ? SavingsOwnership.household
        : SavingsOwnership.personal;
    final hasGoals = context.select<SavingsProvider, bool>(
      (s) => s.summaryOf(ownership).goalCount > 0,
    );
    final showSavings = savingsAvailable;
    final sections = <Widget>[
      if (context.watch<ResetProvider>().restorePending)
        const RestorePendingBanner(),
      BalanceCard(
        title: switch ((shared, showSavings && hasGoals)) {
          (true, true) => 'Household available balance',
          (true, false) => 'Household balance',
          (false, true) => 'Available balance',
          (false, false) => 'Total balance',
        },
        // Money in savings goals is not available to spend.
        balanceMinor: showSavings ? data.availableMinor : data.balanceMinor,
        savedMinor: showSavings && hasGoals ? data.savedMinor : null,
        onSavingsTap: () => openSavingsScreen(context, ownership: ownership),
        monthIncomeMinor: data.month.incomeMinor,
        monthExpenseMinor: data.month.expenseMinor,
        formatter: formatter,
      ),
      Row(
        children: [
          Expanded(
            child: StatCard(
              icon: Icons.view_week_rounded,
              label: 'Spent this week',
              value: formatter.format(data.week.expenseMinor),
              color: finance.expense,
              footer: ChangeBadge(
                percent: data.weekChangePercent,
                suffix: ' vs last week',
                emptyLabel: 'No spending last week',
              ),
              onTap: () => onNavigate(3),
            ),
          ),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: StatCard(
              icon: Icons.calendar_month_rounded,
              label: 'Spent this month',
              value: formatter.format(data.month.expenseMinor),
              color: AppColors.warning,
              footer: ChangeBadge(
                percent: data.monthChangePercent,
                suffix: ' vs last month',
                emptyLabel: 'No spending last month',
              ),
              onTap: () => onNavigate(3),
            ),
          ),
        ],
      ),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: 'Weekly spending',
              subtitle:
                  '${PeriodUtils.weekLabel(data.week.range)} · '
                  'month avg ${formatter.format(data.averageDailyExpense(now))}/day',
            ),
            const SizedBox(height: Spacing.lg),
            SimpleBarChart(
              items: [
                for (final d in data.weekDailyExpenses)
                  BarItem(
                    label: DateFormat('E').format(d.day).substring(0, 2),
                    valueMinor: d.totalMinor,
                  ),
              ],
              formatter: formatter,
              color: finance.expense,
              highlightIndex: todayIndex >= 0 ? todayIndex : null,
              height: 160,
            ),
          ],
        ),
      ),
      BudgetOverviewCard(
        formatter: formatter,
        onOpenBudget: () => onNavigate(2),
      ),
      if (showSavings)
        SavingsOverviewCard(formatter: formatter, ownership: ownership),
      AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: shared
                  ? 'Where household money goes'
                  : 'Where your money goes',
              subtitle:
                  'Expenses by category · ${DateFormat('MMMM').format(now)}',
              actionLabel: 'Reports',
              onAction: () => onNavigate(3),
            ),
            const SizedBox(height: Spacing.lg),
            if (data.monthCategoryShares.isEmpty)
              const EmptyState(
                icon: Icons.pie_chart_outline_rounded,
                title: 'No expenses this month',
                compact: true,
              )
            else
              CategoryDonutChart(
                shares: data.monthCategoryShares,
                formatter: formatter,
              ),
          ],
        ),
      ),
      _RecentTransactionsCard(
        data: data,
        formatter: formatter,
        onSeeAll: () => onNavigate(1),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, 100),
      child: Column(
        children: [
          for (var i = 0; i < sections.length; i++) ...[
            _FadeSlideIn(index: i, child: sections[i]),
            const SizedBox(height: Spacing.lg),
          ],
        ],
      ),
    );
  }
}

class _RecentTransactionsCard extends StatelessWidget {
  const _RecentTransactionsCard({
    required this.data,
    required this.formatter,
    required this.onSeeAll,
  });

  final DashboardData data;
  final CurrencyFormatter formatter;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<CategoryProvider>().byId;
    final household = context.watch<HouseholdProvider>();
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.lg,
        Spacing.sm,
        Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: SectionHeader(
              title: data.scope.includePersonal
                  ? 'Recent transactions'
                  : 'Recent household transactions',
              actionLabel: 'See all',
              onAction: onSeeAll,
            ),
          ),
          if (data.recentTransactions.isEmpty && isViewLoading(context))
            const LoadingView(padding: EdgeInsets.all(Spacing.lg))
          else if (data.recentTransactions.isEmpty)
            EmptyState(
              icon: Icons.receipt_long_rounded,
              title: 'No transactions yet',
              message: 'Tap + to record your first income or expense.',
              compact: true,
              actionLabel: 'Add transaction',
              onAction: () => openTransactionForm(context),
            )
          else
            for (final t in data.recentTransactions)
              TransactionTile(
                transaction: t,
                category: categories[t.categoryId],
                formatter: formatter,
                showDate: true,
                sharedLabel: sharedLabelFor(household, t),
                onTap: () => openTransactionForm(context, transaction: t),
              ),
        ],
      ),
    );
  }
}

/// Staggered entrance animation for dashboard cards.
class _FadeSlideIn extends StatelessWidget {
  const _FadeSlideIn({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 350 + index * 70),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 16),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
