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
import 'package:money_mate/features/savings/savings_actions.dart';

/// Rounded square with a goal purpose's icon in its colour.
class PurposeAvatar extends StatelessWidget {
  const PurposeAvatar({super.key, required this.purpose, this.size = 44});

  final SavingsPurpose purpose;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = purposeColor(context, purpose);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(purpose.icon, color: color, size: size * 0.52),
    );
  }
}

/// [purpose]'s colour, lightened in the dark theme for contrast.
Color purposeColor(BuildContext context, SavingsPurpose purpose) =>
    Theme.of(context).brightness == Brightness.dark
    ? Color.lerp(purpose.color, Colors.white, 0.3)!
    : purpose.color;

/// Colour of a goal's progress: purpose colour while active, income green
/// once completed and grey while paused.
Color goalColor(BuildContext context, SavingsGoal goal) {
  if (goal.isCompleted || goal.targetReached) return context.finance.income;
  if (goal.isPaused) return Theme.of(context).colorScheme.outline;
  return purposeColor(context, goal.purpose);
}

/// Animated rounded progress bar.
class SavingsProgressBar extends StatelessWidget {
  const SavingsProgressBar({
    super.key,
    required this.progress,
    required this.color,
    this.height = 10,
  });

  /// 0..1
  final double progress;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Savings progress',
      value: '${(progress * 100).floor()} percent',
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: LinearProgressIndicator(
            value: value,
            minHeight: height,
            color: color,
            backgroundColor: color.withValues(alpha: 0.15),
          ),
        ),
      ),
    );
  }
}

/// Small pill with a goal's status.
class GoalStatusChip extends StatelessWidget {
  const GoalStatusChip({super.key, required this.goal});

  final SavingsGoal goal;

  @override
  Widget build(BuildContext context) {
    final finance = context.finance;
    final scheme = Theme.of(context).colorScheme;
    final (label, color, icon) = switch (goal.status) {
      SavingsGoalStatus.completed => (
        'Completed',
        finance.income,
        Icons.check_circle_rounded,
      ),
      SavingsGoalStatus.paused => (
        'Paused',
        scheme.outline,
        Icons.pause_circle_rounded,
      ),
      SavingsGoalStatus.active when goal.targetReached => (
        'Target reached',
        finance.income,
        Icons.emoji_events_rounded,
      ),
      SavingsGoalStatus.active => (
        '${goal.percent}%',
        purposeColor(context, goal.purpose),
        Icons.trending_up_rounded,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// A goal in the Savings list: purpose, progress and amounts.
class GoalCard extends StatelessWidget {
  const GoalCard({super.key, required this.goal, required this.onTap});

  final SavingsGoal goal;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final color = goalColor(context, goal);
    final expected = SavingsCalculator.expectedCompletion(goal, DateTime.now());
    final dateFormat = DateFormat('d MMM yyyy');
    final footer = goal.isCompleted
        ? 'Completed${goal.completedAt != null ? ' ${dateFormat.format(goal.completedAt!)}' : ''}'
        : goal.isPaused
        ? 'Paused'
        : goal.targetReached
        ? 'Target reached – mark it as completed'
        : [
            if (goal.targetDate != null)
              'Target ${dateFormat.format(goal.targetDate!)}',
            if (expected != null) 'On pace for ${dateFormat.format(expected)}',
          ].join(' · ');

    return AppCard(
      key: Key('savingsGoal-${goal.id}'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PurposeAvatar(purpose: goal.purpose),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      goal.name,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      [
                        goal.purposeLabel,
                        goal.ownership.label,
                        if (goal.isShared)
                          '${goal.memberCount} '
                              '${goal.memberCount == 1 ? 'member' : 'members'}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
          const SizedBox(height: Spacing.md),
          SavingsProgressBar(progress: goal.progress, color: color),
          const SizedBox(height: Spacing.sm),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: Spacing.md,
            runSpacing: 2,
            children: [
              Text(
                '${formatter.format(goal.savedMinor)} of '
                '${formatter.format(goal.targetMinor)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!goal.isCompleted && goal.remainingMinor > 0)
                Text(
                  '${formatter.format(goal.remainingMinor)} to go',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
            ],
          ),
          if (footer.isNotEmpty || goal.pendingEntries > 0) ...[
            const SizedBox(height: 2),
            Text(
              [
                if (footer.isNotEmpty) footer,
                if (goal.pendingEntries > 0) 'Waiting to sync',
              ].join(' · '),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small pill naming who a goal belongs to.
class OwnershipChip extends StatelessWidget {
  const OwnershipChip({super.key, required this.ownership});

  final SavingsOwnership ownership;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ownership.icon, size: 14, color: scheme.primary),
          const SizedBox(width: 4),
          Text(
            ownership.label,
            style: TextStyle(
              color: scheme.primary,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Dashboard card: the goals of the dashboard's view (personal or
/// household) and the closest ones to their targets.
class SavingsOverviewCard extends StatelessWidget {
  const SavingsOverviewCard({
    super.key,
    required this.formatter,
    this.ownership = SavingsOwnership.personal,
  });

  final CurrencyFormatter formatter;
  final SavingsOwnership ownership;

  static const _maxGoals = 3;

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final theme = Theme.of(context);
    final summary = savings.summaryOf(ownership);
    final active = savings.goalsOf(ownership).where((g) => g.isActive).toList()
      ..sort((a, b) => b.progress.compareTo(a.progress));
    final title = ownership == SavingsOwnership.household
        ? 'Household savings goals'
        : 'Savings goals';

    return AppCard(
      key: const Key('savingsOverviewCard'),
      onTap: () => openSavingsScreen(context, ownership: ownership),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: title,
            subtitle: summary.goalCount == 0
                ? 'Set money aside for what matters'
                : '${formatter.format(summary.totalSavedMinor)} saved · '
                      '${summary.activeCount} active',
            actionLabel: summary.goalCount == 0 ? 'Create' : 'View all',
            onAction: () => summary.goalCount == 0
                ? openGoalForm(context, ownership: ownership)
                : openSavingsScreen(context, ownership: ownership),
          ),
          if (active.isNotEmpty) ...[
            const SizedBox(height: Spacing.md),
            for (final g in active.take(_maxGoals))
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: Row(
                  children: [
                    PurposeAvatar(purpose: g.purpose, size: 36),
                    const SizedBox(width: Spacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  g.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Text(
                                '${g.percent}%',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: goalColor(context, g),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          SavingsProgressBar(
                            progress: g.progress,
                            color: goalColor(context, g),
                            height: 6,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ] else if (summary.goalCount > 0) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'No active goals right now.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
