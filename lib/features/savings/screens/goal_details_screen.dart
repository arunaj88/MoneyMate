import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/savings_calculator.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';
import 'package:money_mate/shared/widgets/state_views.dart';
import 'package:money_mate/features/savings/savings_actions.dart';
import 'package:money_mate/features/savings/widgets/savings_widgets.dart';
import 'package:money_mate/features/savings/widgets/shared_goal_widgets.dart';

enum _GoalMenu { pause, resume, complete, reopen, delete }

/// One goal: progress, actions and its contribution / withdrawal history.
class GoalDetailsScreen extends StatefulWidget {
  const GoalDetailsScreen({super.key, required this.goalId});

  final String goalId;

  @override
  State<GoalDetailsScreen> createState() => _GoalDetailsScreenState();
}

class _GoalDetailsScreenState extends State<GoalDetailsScreen> {
  String? _historyError;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _historyError = null);
    final savings = context.read<SavingsProvider>();
    try {
      await savings.loadEntries(widget.goalId);
      final goal = savings.goalById(widget.goalId);
      // Latest members and invitations of a shared goal (cached offline).
      if (goal != null && goal.isShared) await savings.refreshShared(goal);
    } catch (e) {
      if (mounted) {
        setState(() => _historyError = 'Could not load the history.');
      }
    }
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) showAppSnackBar(context, done);
    } on SavingsException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, isError: true);
    } catch (e) {
      if (mounted) showAppSnackBar(context, 'Something went wrong: $e');
    }
  }

  Future<void> _onMenu(_GoalMenu item, SavingsGoal goal) async {
    final savings = context.read<SavingsProvider>();
    final formatter = context.read<SettingsProvider>().formatter;
    switch (item) {
      case _GoalMenu.pause:
        await _run(() => savings.pauseGoal(goal), 'Goal paused');
      case _GoalMenu.resume:
        await _run(() => savings.resumeGoal(goal), 'Goal resumed');
      case _GoalMenu.reopen:
        await _run(() => savings.resumeGoal(goal), 'Goal reopened');
      case _GoalMenu.complete:
        final confirmed = await showConfirmDialog(
          context,
          title: 'Mark as completed?',
          message: goal.targetReached
              ? 'Congratulations on reaching your target! The money stays '
                    'in this goal until you withdraw it.'
              : 'You have saved ${formatter.format(goal.savedMinor)} of '
                    '${formatter.format(goal.targetMinor)}. The money stays '
                    'in this goal until you withdraw it.',
          confirmLabel: 'Complete',
        );
        if (confirmed) {
          await _run(() => savings.completeGoal(goal), 'Goal completed');
        }
      case _GoalMenu.delete:
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete "${goal.name}"?',
          message: switch (goal.ownership) {
            SavingsOwnership.personal when goal.savedMinor > 0 =>
              'The goal and its history will be deleted on all your '
                  'devices. ${formatter.format(goal.savedMinor)} saved in '
                  'it goes back to your available balance. This cannot be '
                  'undone.',
            SavingsOwnership.household =>
              'The goal is deleted for everyone in your household. '
                  '${formatter.format(goal.savedMinor)} saved in it goes '
                  'back to the household balance. This cannot be undone.',
            SavingsOwnership.shared =>
              'The goal is deleted for every member and nobody can see it '
                  'any more. This cannot be undone.',
            _ =>
              'The goal and its history will be deleted on all your '
                  'devices. This cannot be undone.',
          },
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (!confirmed || !mounted) return;
        final navigator = Navigator.of(context);
        try {
          await savings.deleteGoal(goal);
          if (!mounted) return;
          showAppSnackBar(context, 'Goal deleted');
          navigator.pop();
        } on SavingsException catch (e) {
          if (mounted) showAppSnackBar(context, e.message, isError: true);
        } catch (e) {
          if (mounted) {
            showAppSnackBar(context, 'Could not delete: $e', isError: true);
          }
        }
    }
  }

  Future<void> _deleteEntry(SavingsEntry entry) async {
    final formatter = context.read<SettingsProvider>().formatter;
    final confirmed = await showConfirmDialog(
      context,
      title: entry.isDeposit ? 'Delete contribution?' : 'Delete withdrawal?',
      message: entry.isDeposit
          ? '${formatter.format(entry.amountMinor)} goes back to your '
                'available balance.'
          : '${formatter.format(entry.amountMinor)} goes back into this goal.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await _run(
      () => context.read<SavingsProvider>().deleteEntry(entry),
      'Entry deleted',
    );
  }

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final goal = savings.goalById(widget.goalId);
    if (goal == null) {
      return Scaffold(
        appBar: AppBar(),
        body: savings.hasLoaded
            ? const Center(
                child: EmptyState(
                  icon: Icons.flag_outlined,
                  title: 'This goal no longer exists',
                  message: 'It may have been deleted on another device.',
                ),
              )
            : const LoadingView(),
      );
    }
    final entries = savings.entriesFor(goal.id);
    final canManage = savings.canManage(goal);

    return Scaffold(
      appBar: AppBar(
        title: Text(goal.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (canManage) ...[
            IconButton(
              key: const Key('editGoalButton'),
              tooltip: 'Edit goal',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => openGoalForm(context, goal: goal),
            ),
            PopupMenuButton<_GoalMenu>(
              key: const Key('goalMenu'),
              tooltip: 'More',
              onSelected: (item) => _onMenu(item, goal),
              itemBuilder: (_) => [
                if (goal.isActive)
                  const PopupMenuItem(
                    value: _GoalMenu.pause,
                    child: ListTile(
                      leading: Icon(Icons.pause_circle_outline_rounded),
                      title: Text('Pause goal'),
                    ),
                  ),
                if (goal.isPaused)
                  const PopupMenuItem(
                    value: _GoalMenu.resume,
                    child: ListTile(
                      leading: Icon(Icons.play_circle_outline_rounded),
                      title: Text('Resume goal'),
                    ),
                  ),
                if (!goal.isCompleted)
                  const PopupMenuItem(
                    value: _GoalMenu.complete,
                    child: ListTile(
                      leading: Icon(Icons.check_circle_outline_rounded),
                      title: Text('Mark as completed'),
                    ),
                  ),
                if (goal.isCompleted)
                  const PopupMenuItem(
                    value: _GoalMenu.reopen,
                    child: ListTile(
                      leading: Icon(Icons.replay_rounded),
                      title: Text('Reopen goal'),
                    ),
                  ),
                const PopupMenuItem(
                  value: _GoalMenu.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline_rounded),
                    title: Text('Delete goal'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _loadHistory,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.sm,
              Spacing.lg,
              Spacing.xxl,
            ),
            children: [
              _ProgressCard(goal: goal),
              const SizedBox(height: Spacing.md),
              _Actions(goal: goal),
              if (goal.notes.isNotEmpty) ...[
                const SizedBox(height: Spacing.md),
                AppCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.notes_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: Spacing.md),
                      Expanded(child: Text(goal.notes)),
                    ],
                  ),
                ),
              ],
              if (goal.isCollaborative) ...[
                const SizedBox(height: Spacing.md),
                MemberContributionsCard(goal: goal),
              ],
              if (goal.isShared) ...[
                const SizedBox(height: Spacing.md),
                SharedMembersCard(goal: goal),
              ],
              const SizedBox(height: Spacing.md),
              _History(
                entries: entries,
                error: _historyError,
                onRetry: _loadHistory,
                // Household and shared history is permanent.
                onDelete: goal.isPersonal ? _deleteEntry : null,
                currentUid: savings.uid,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.goal});

  final SavingsGoal goal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final now = DateTime.now();
    final color = goalColor(context, goal);
    final dateFormat = DateFormat('d MMM yyyy');
    final expected = SavingsCalculator.expectedCompletion(goal, now);
    final monthly = SavingsCalculator.monthlyNeeded(goal, now);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PurposeAvatar(purpose: goal.purpose, size: 48),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal.name,
                      style: theme.textTheme.titleMedium,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${goal.purposeLabel} · ${goal.ownership.label}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              GoalStatusChip(goal: goal),
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
                    formatter.format(goal.savedMinor),
                    key: const Key('goalSavedText'),
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                ),
              ),
              Text(
                '${goal.percent}%',
                key: const Key('goalPercentText'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.sm),
          SavingsProgressBar(progress: goal.progress, color: color, height: 12),
          const SizedBox(height: Spacing.lg),
          _DetailRow(
            label: 'Target',
            value: formatter.format(goal.targetMinor),
          ),
          _DetailRow(label: 'Saved', value: formatter.format(goal.savedMinor)),
          _DetailRow(
            label: 'Remaining',
            value: formatter.format(goal.remainingMinor),
            valueKey: const Key('goalRemainingText'),
          ),
          _DetailRow(
            label: 'Target date',
            value: goal.targetDate == null
                ? 'Not set'
                : dateFormat.format(goal.targetDate!),
          ),
          if (expected != null)
            _DetailRow(
              label: 'Expected at current pace',
              value: dateFormat.format(expected),
            ),
          if (monthly != null && goal.isActive)
            _DetailRow(
              label: 'Needed per month',
              value: formatter.format(monthly),
            ),
          _DetailRow(
            label: 'Created',
            value: dateFormat.format(goal.createdAt),
          ),
          if (goal.completedAt != null && goal.isCompleted)
            _DetailRow(
              label: 'Completed',
              value: dateFormat.format(goal.completedAt!),
            ),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.goal});

  final SavingsGoal goal;

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final canManage = savings.canManage(goal);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('goalAddMoney'),
                onPressed: goal.isActive && savings.canContribute(goal)
                    ? () => showMoneySheet(
                        context,
                        type: SavingsEntryType.deposit,
                        goal: goal,
                      )
                    : null,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add money'),
              ),
            ),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('goalWithdraw'),
                onPressed: goal.savedMinor > 0 && savings.canWithdraw(goal)
                    ? () => showMoneySheet(
                        context,
                        type: SavingsEntryType.withdrawal,
                        goal: goal,
                      )
                    : null,
                icon: const Icon(Icons.remove_rounded),
                label: const Text('Withdraw'),
              ),
            ),
          ],
        ),
        if (goal.isPaused && canManage)
          TextButton.icon(
            key: const Key('resumeGoalButton'),
            onPressed: () => savings.resumeGoal(goal),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Paused – resume to add money'),
          ),
        if (goal.isActive && goal.targetReached && canManage)
          TextButton.icon(
            key: const Key('completeGoalButton'),
            onPressed: () => savings.completeGoal(goal),
            icon: const Icon(Icons.emoji_events_outlined),
            label: const Text('Target reached – mark as completed'),
          ),
      ],
    );
  }
}

class _History extends StatelessWidget {
  const _History({
    required this.entries,
    required this.error,
    required this.onRetry,
    required this.onDelete,
    required this.currentUid,
  });

  final List<SavingsEntry>? entries;
  final String? error;
  final VoidCallback onRetry;

  /// Null when entries cannot be deleted (household and shared goals).
  final ValueChanged<SavingsEntry>? onDelete;
  final String? currentUid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final list = entries;
    final dateFormat = DateFormat('EEE, d MMM yyyy');

    Widget content;
    if (error != null) {
      content = ErrorState(message: error!, onRetry: onRetry);
    } else if (list == null) {
      content = const LoadingView(padding: EdgeInsets.all(Spacing.xl));
    } else if (list.isEmpty) {
      content = const EmptyState(
        icon: Icons.history_rounded,
        title: 'No contributions yet',
        message: 'Money you add or withdraw appears here.',
        compact: true,
      );
    } else {
      content = Column(
        children: [
          for (final e in list)
            ListTile(
              key: Key('savingsEntry-${e.id}'),
              contentPadding: const EdgeInsets.only(left: Spacing.sm),
              leading: CircleAvatar(
                backgroundColor:
                    (e.isDeposit ? finance.income : finance.warning).withValues(
                      alpha: 0.15,
                    ),
                child: Icon(
                  e.isDeposit
                      ? Icons.south_east_rounded
                      : Icons.north_west_rounded,
                  color: e.isDeposit ? finance.income : finance.warning,
                  size: 20,
                ),
              ),
              title: Text(
                e.note.isNotEmpty ? e.note : e.type.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  dateFormat.format(e.date),
                  if (onDelete == null && e.userUid != null)
                    e.userUid == currentUid ? 'You' : (e.userName ?? 'Member'),
                  if (e.isPending) 'Waiting to sync',
                ].join(' · '),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${e.isDeposit ? '+' : '-'}'
                    '${formatter.format(e.amountMinor)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: e.isDeposit ? finance.income : finance.warning,
                    ),
                  ),
                  if (onDelete != null)
                    IconButton(
                      tooltip: 'Delete entry',
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: () => onDelete!(e),
                    )
                  else
                    const SizedBox(width: Spacing.md),
                ],
              ),
            ),
        ],
      );
    }

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
              title: 'History',
              subtitle: list == null || list.isEmpty
                  ? null
                  : '${list.length} '
                        '${list.length == 1 ? 'entry' : 'entries'}',
            ),
          ),
          const SizedBox(height: Spacing.sm),
          content,
        ],
      ),
    );
  }
}

/// "Label ........ value" row in the progress card.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.valueKey});

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: LabelAmountRow(
        label: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        amount: Text(
          value,
          key: valueKey,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
