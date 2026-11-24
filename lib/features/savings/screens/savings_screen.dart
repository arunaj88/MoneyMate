import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/state_views.dart';
import 'package:money_mate/features/household/widgets/household_widgets.dart';
import 'package:money_mate/features/savings/savings_actions.dart';
import 'package:money_mate/features/savings/widgets/savings_widgets.dart';
import 'package:money_mate/features/savings/widgets/shared_goal_widgets.dart';

/// All savings goals, in three tabs: Personal, Household and Shared.
class SavingsScreen extends StatefulWidget {
  const SavingsScreen({
    super.key,
    this.initialOwnership = SavingsOwnership.personal,
  });

  final SavingsOwnership initialOwnership;

  @override
  State<SavingsScreen> createState() => _SavingsScreenState();
}

class _SavingsScreenState extends State<SavingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: SavingsOwnership.values.length,
    vsync: this,
    initialIndex: widget.initialOwnership.index,
  )..addListener(() => setState(() {}));

  SavingsOwnership get _current => SavingsOwnership.values[_tabs.index];

  @override
  void initState() {
    super.initState();
    final savings = context.read<SavingsProvider>();
    if (!savings.hasLoaded) savings.load();
    savings.refreshReceivedInvitations();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final savings = context.read<SavingsProvider>();
    final sync = context.read<SyncProvider>();
    if (sync.phase != SyncPhase.unavailable) await sync.syncNow();
    await savings.load();
    await savings.refreshReceivedInvitations();
  }

  bool _canCreate(SavingsProvider savings) => switch (_current) {
    SavingsOwnership.personal => true,
    SavingsOwnership.household => savings.hasHousehold && savings.uid != null,
    SavingsOwnership.shared => savings.canUseShared,
  };

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();

    Widget body;
    if (!savings.hasLoaded) {
      body = const LoadingView();
    } else if (savings.error != null && savings.goals.isEmpty) {
      body = Center(
        child: ErrorState(message: savings.error!, onRetry: savings.load),
      );
    } else {
      body = TabBarView(
        controller: _tabs,
        children: [
          for (final o in SavingsOwnership.values)
            RefreshIndicator(
              onRefresh: _refresh,
              child: _GoalsTab(ownership: o),
            ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Savings'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            for (final o in SavingsOwnership.values)
              Tab(
                key: Key('savingsTab-${o.name}'),
                icon: Icon(o.icon, size: 20),
                text: o.label,
              ),
          ],
        ),
      ),
      body: SafeArea(bottom: false, child: body),
      floatingActionButton: _canCreate(savings)
          ? FloatingActionButton.extended(
              key: const Key('newGoalFab'),
              onPressed: () => openGoalForm(context, ownership: _current),
              icon: const Icon(Icons.add_rounded),
              label: const Text('New goal'),
            )
          : null,
    );
  }
}

class _GoalsTab extends StatelessWidget {
  const _GoalsTab({required this.ownership});

  final SavingsOwnership ownership;

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final goals = savings.goalsOf(ownership);
    final theme = Theme.of(context);

    final Widget? blocker = switch (ownership) {
      SavingsOwnership.household when !savings.hasHousehold => EmptyState(
        icon: Icons.home_outlined,
        title: 'No household yet',
        message:
            'Household goals belong to your MoneyMate household. Every '
            'member can see them and contribute.',
        actionLabel: 'Set up a household',
        onAction: () => openHouseholdScreen(context),
      ),
      SavingsOwnership.shared when !savings.canUseShared => const EmptyState(
        icon: Icons.groups_outlined,
        title: 'Sign in to share goals',
        message:
            'Shared goals let you save together with friends who use '
            'MoneyMate, separately from your household.',
      ),
      _ => null,
    };

    final sections = <(String, List<SavingsGoal>)>[
      ('Active', goals.where((g) => g.isActive).toList()),
      ('Paused', goals.where((g) => g.isPaused).toList()),
      ('Completed', goals.where((g) => g.isCompleted).toList()),
    ];

    return ListView(
      key: PageStorageKey('savingsTab-${ownership.name}'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.md,
        Spacing.lg,
        100,
      ),
      children: [
        const _OverallCard(),
        const SizedBox(height: Spacing.md),
        if (blocker != null)
          blocker
        else ...[
          _TypeSummary(ownership: ownership),
          if (ownership == SavingsOwnership.shared) ...[
            const SizedBox(height: Spacing.md),
            const ReceivedInvitationsCard(),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('joinWithCodeButton'),
                onPressed: () => showJoinWithCode(context),
                icon: const Icon(Icons.key_rounded),
                label: const Text('Join with code'),
              ),
            ),
          ],
          if (goals.isEmpty)
            EmptyState(
              icon: ownership.icon,
              title: switch (ownership) {
                SavingsOwnership.personal => 'No personal goals yet',
                SavingsOwnership.household => 'No household goals yet',
                SavingsOwnership.shared => 'No shared goals yet',
              },
              message: switch (ownership) {
                SavingsOwnership.personal =>
                  'Set money aside for a trip, gold, an emergency fund or '
                      'anything else. It is never counted as spending.',
                SavingsOwnership.household =>
                  'Save together for a family trip, a renovation or a new '
                      'car. Every household member can contribute.',
                SavingsOwnership.shared =>
                  'Save with friends for a trip, a wedding or an event. '
                      'Invite them by email or with a code.',
              },
              actionLabel: 'Create a goal',
              onAction: () => openGoalForm(context, ownership: ownership),
            )
          else ...[
            const SizedBox(height: Spacing.md),
            _QuickActions(ownership: ownership),
            for (final (title, list) in sections)
              if (list.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.xs,
                    Spacing.xl,
                    Spacing.xs,
                    Spacing.sm,
                  ),
                  child: Text(
                    '$title (${list.length})',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final g in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: Spacing.sm),
                    child: GoalCard(
                      goal: g,
                      onTap: () => openGoalDetails(context, g),
                    ),
                  ),
              ],
          ],
        ],
      ],
    );
  }
}

/// Totals of every kind, kept apart (they are never one balance).
class _OverallCard extends StatelessWidget {
  const _OverallCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final savings = context.watch<SavingsProvider>();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final overall = savings.overallSummary;
    const onCard = Colors.white;

    Widget stat(String label, String value, Key key) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: onCard.withValues(alpha: 0.75),
          ),
        ),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            key: key,
            style: theme.textTheme.titleSmall?.copyWith(
              color: onCard,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: finance.balanceGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(Spacing.radius + 4),
      ),
      padding: const EdgeInsets.all(Spacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Total savings, all goals',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: onCard.withValues(alpha: 0.8),
                  ),
                ),
              ),
              Icon(
                Icons.savings_outlined,
                color: onCard.withValues(alpha: 0.8),
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatter.format(overall.totalSavedMinor),
              key: const Key('totalSavedText'),
              style: theme.textTheme.headlineMedium?.copyWith(
                color: onCard,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          SavingsProgressBar(
            progress: overall.overallProgress,
            color: onCard,
            height: 8,
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '${(overall.overallProgress * 100).floor()}% of '
            '${formatter.format(overall.totalTargetMinor)} · '
            '${formatter.format(overall.remainingActiveMinor)} to go · '
            '${overall.activeCount} active, ${overall.completedCount} '
            'completed',
            key: const Key('overallSummaryText'),
            style: theme.textTheme.labelSmall?.copyWith(
              color: onCard.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Row(
            children: [
              Expanded(
                child: stat(
                  'Personal',
                  formatter.format(savings.personalSavedMinor),
                  const Key('personalSavedText'),
                ),
              ),
              Expanded(
                child: stat(
                  'Household',
                  formatter.format(savings.householdSavedMinor),
                  const Key('householdSavedText'),
                ),
              ),
              Expanded(
                child: stat(
                  'Shared',
                  formatter.format(savings.sharedSavedMinor),
                  const Key('sharedSavedText'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Figures for one tab, with what they mean for the balance.
class _TypeSummary extends StatelessWidget {
  const _TypeSummary({required this.ownership});

  final SavingsOwnership ownership;

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final theme = Theme.of(context);
    final s = savings.summaryOf(ownership);
    final note = switch (ownership) {
      SavingsOwnership.personal =>
        'Taken out of your personal available balance.',
      SavingsOwnership.household =>
        'Taken out of the household available balance.',
      SavingsOwnership.shared =>
        'Amounts members record as contributed. They do not change anyone\'s '
            'MoneyMate balance. You: '
            '${formatter.format(savings.mySharedContributionMinor)}.',
    };
    Widget cell(String label, String value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    return AppCard(
      key: Key('typeSummary-${ownership.name}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              cell('Saved', formatter.format(s.totalSavedMinor)),
              cell('Target', formatter.format(s.totalTargetMinor)),
              cell('Remaining', formatter.format(s.remainingActiveMinor)),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          SavingsProgressBar(
            progress: s.overallProgress,
            color: theme.colorScheme.primary,
            height: 6,
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            '${s.activeCount} active · ${s.completedCount} completed. $note',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.ownership});

  final SavingsOwnership ownership;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: TextButton.icon(
              key: Key('savingsAddMoney-${ownership.name}'),
              onPressed: () => showMoneySheet(
                context,
                type: SavingsEntryType.deposit,
                ownership: ownership,
              ),
              icon: const Icon(Icons.add_circle_outline_rounded),
              label: const Text('Add money'),
            ),
          ),
          Container(
            width: 1,
            height: 28,
            color: Theme.of(context).dividerColor,
          ),
          Expanded(
            child: TextButton.icon(
              key: Key('savingsWithdraw-${ownership.name}'),
              onPressed: () => showMoneySheet(
                context,
                type: SavingsEntryType.withdrawal,
                ownership: ownership,
              ),
              icon: const Icon(Icons.remove_circle_outline_rounded),
              label: const Text('Withdraw'),
            ),
          ),
        ],
      ),
    );
  }
}
