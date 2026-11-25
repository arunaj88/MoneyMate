import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/features/lending/lending_actions.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';

final DateFormat lendingDate = DateFormat('d MMM yyyy');
final DateFormat lendingShortDate = DateFormat('d MMM');

Color installmentStatusColor(BuildContext context, InstallmentStatus status) {
  final finance = context.finance;
  final scheme = Theme.of(context).colorScheme;
  return switch (status) {
    InstallmentStatus.paid => finance.income,
    InstallmentStatus.overdue => finance.expense,
    InstallmentStatus.partiallyPaid => finance.caution,
    InstallmentStatus.due => finance.warning,
    InstallmentStatus.upcoming => scheme.onSurfaceVariant,
  };
}

Color loanStatusColor(BuildContext context, LoanStatus status) =>
    switch (status) {
      LoanStatus.completed => context.finance.income,
      LoanStatus.overdue => context.finance.expense,
      LoanStatus.active => Theme.of(context).colorScheme.primary,
    };

/// A small coloured label (status, scope).
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BorrowerAvatar extends StatelessWidget {
  const _BorrowerAvatar({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return CircleAvatar(
      radius: 22,
      backgroundColor: color.withValues(alpha: 0.14),
      child: Text(
        initial,
        style: TextStyle(color: color, fontWeight: FontWeight.w800),
      ),
    );
  }
}

/// Progress of what was repaid out of what is owed.
class RepaymentProgressBar extends StatelessWidget {
  const RepaymentProgressBar({
    super.key,
    required this.progress,
    required this.color,
    this.height = 6,
  });

  final double progress;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(height),
    child: LinearProgressIndicator(
      value: progress,
      minHeight: height,
      color: color,
      backgroundColor: color.withValues(alpha: 0.14),
    ),
  );
}

/// One lending record in a list.
class LoanTile extends StatelessWidget {
  const LoanTile({
    super.key,
    required this.snapshot,
    required this.formatter,
    this.onTap,
  });

  final LoanSnapshot snapshot;
  final CurrencyFormatter formatter;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loan = snapshot.loan;
    final color = loanStatusColor(context, snapshot.status);
    final next = snapshot.nextDue;
    final subtitle = snapshot.isCompleted
        ? 'Repaid in full · lent ${lendingDate.format(loan.lentDate)}'
        : next == null
        ? 'Lent ${lendingDate.format(loan.lentDate)}'
        : 'Next ${formatter.format(next.remainingMinor)} · '
              '${lendingDate.format(next.dueDate)}';
    return AppCard(
      key: Key('loanTile-${loan.id}'),
      onTap: onTap ?? () => openLoanDetails(context, loan.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _BorrowerAvatar(name: loan.borrowerName, color: color),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      loan.borrowerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatter.format(snapshot.outstandingMinor),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  StatusChip(label: snapshot.status.label, color: color),
                ],
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          RepaymentProgressBar(progress: snapshot.progress, color: color),
          const SizedBox(height: Spacing.xs),
          Row(
            children: [
              Icon(
                loan.isHousehold
                    ? Icons.home_outlined
                    : Icons.person_outline_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '${loan.isHousehold ? 'Household' : 'Personal'} · '
                  '${loan.repaymentType.label} · '
                  '${formatter.format(snapshot.receivedMinor)} of '
                  '${formatter.format(loan.totalOwedMinor)} repaid',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (loan.pendingRepayments > 0)
                Tooltip(
                  message: 'Waiting to sync',
                  child: Icon(
                    Icons.cloud_upload_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// An unpaid instalment in the upcoming / overdue lists, with a shortcut to
/// record its repayment.
class DueInstallmentTile extends StatelessWidget {
  const DueInstallmentTile({
    super.key,
    required this.due,
    required this.formatter,
  });

  final DueInstallment due;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loan = due.loan;
    final i = due.installment;
    final color = installmentStatusColor(context, i.status);
    final label = loan.isMonthly
        ? 'EMI ${i.number} of ${loan.schedule.length}'
        : 'Repayment';
    final canRecord = context.read<LoanProvider>().canManage(loan);
    return ListTile(
      key: Key('due-${i.id}'),
      contentPadding: EdgeInsets.zero,
      onTap: () => openLoanDetails(context, loan.id, installmentId: i.id),
      leading: _BorrowerAvatar(name: loan.borrowerName, color: color),
      title: Text(
        loan.borrowerName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '$label · ${i.status.label.toLowerCase()} '
        '${lendingShortDate.format(i.dueDate)}'
        '${i.receivedMinor > 0 ? ' · ${formatter.format(i.receivedMinor)} paid' : ''}',
        style: theme.textTheme.bodySmall?.copyWith(color: color),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            formatter.format(i.remainingMinor),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (canRecord)
            IconButton(
              key: Key('recordDue-${i.id}'),
              tooltip: 'Record repayment',
              icon: const Icon(Icons.add_task_rounded),
              onPressed: () {
                final snapshot = context.read<LoanProvider>().snapshotById(
                  loan.id,
                );
                if (snapshot != null) {
                  showRepaymentSheet(context, snapshot, installment: i);
                }
              },
            ),
        ],
      ),
    );
  }
}

/// One instalment in a loan's schedule.
class InstallmentTile extends StatelessWidget {
  const InstallmentTile({
    super.key,
    required this.view,
    required this.formatter,
    this.highlighted = false,
    this.onRecord,
  });

  final InstallmentView view;
  final CurrencyFormatter formatter;
  final bool highlighted;
  final VoidCallback? onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = installmentStatusColor(context, view.status);
    final detail = switch (view.status) {
      InstallmentStatus.paid => 'Paid ${formatter.format(view.receivedMinor)}',
      _ when view.receivedMinor > 0 =>
        '${formatter.format(view.receivedMinor)} paid · '
            '${formatter.format(view.remainingMinor)} left',
      _ => '${formatter.format(view.remainingMinor)} expected',
    };
    return Container(
      key: Key('installment-${view.id}'),
      decoration: highlighted
          ? BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(Spacing.radiusSm),
            )
          : null,
      child: ListTile(
        dense: true,
        leading: CircleAvatar(
          radius: 16,
          backgroundColor: color.withValues(alpha: 0.14),
          child: view.isPaid
              ? Icon(Icons.check_rounded, size: 18, color: color)
              : Text(
                  '${view.number}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
        title: LabelAmountRow(
          label: Text(lendingDate.format(view.dueDate)),
          amount: Text(
            formatter.format(view.expectedMinor),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Wrap(
            spacing: Spacing.sm,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusChip(label: view.status.label, color: color),
              Text(detail),
            ],
          ),
        ),
        trailing: onRecord == null || view.isPaid
            ? null
            : IconButton(
                key: Key('recordInstallment-${view.id}'),
                tooltip: 'Record repayment',
                icon: const Icon(Icons.add_task_rounded),
                onPressed: onRecord,
              ),
      ),
    );
  }
}

/// One repayment in the history.
class RepaymentTile extends StatelessWidget {
  const RepaymentTile({
    super.key,
    required this.repayment,
    required this.formatter,
    this.recordedBy,
    this.onVoid,
  });

  final LoanRepayment repayment;
  final CurrencyFormatter formatter;

  /// Who recorded it (household loans).
  final String? recordedBy;
  final VoidCallback? onVoid;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final muted = !repayment.counts;
    final parts = [
      DateFormat('d MMM yyyy').format(repayment.date),
      repayment.method.label,
      ?recordedBy,
      if (repayment.note.isNotEmpty) repayment.note,
    ];
    final String? status;
    if (repayment.voided) {
      status =
          'Voided${repayment.voidReason.isEmpty ? '' : ': ${repayment.voidReason}'}';
    } else if (repayment.isRejected) {
      status = 'Not recorded: the loan was already repaid by then';
    } else if (repayment.isPending) {
      status = 'Waiting to sync';
    } else {
      status = null;
    }
    return ListTile(
      key: Key('repayment-${repayment.id}'),
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: (muted ? theme.colorScheme.outline : finance.income)
            .withValues(alpha: 0.14),
        child: Icon(
          muted ? Icons.block_rounded : Icons.south_west_rounded,
          color: muted ? theme.colorScheme.outline : finance.income,
          size: 20,
        ),
      ),
      title: Text(
        formatter.format(repayment.amountMinor),
        style: TextStyle(
          fontWeight: FontWeight.w700,
          decoration: muted ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text(
        [parts.join(' · '), ?status].join('\n'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      isThreeLine: status != null,
      trailing: onVoid == null || muted
          ? null
          : PopupMenuButton<String>(
              key: Key('repaymentMenu-${repayment.id}'),
              tooltip: 'More',
              onSelected: (_) => onVoid!(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'void', child: Text('Void repayment')),
              ],
            ),
    );
  }
}

/// Dashboard card: money lent from the current view's balance.
class LendingOverviewCard extends StatelessWidget {
  const LendingOverviewCard({
    super.key,
    required this.formatter,
    required this.scope,
  });

  final CurrencyFormatter formatter;
  final ScopeFilter scope;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loans = context.watch<LoanProvider>();
    final filter = scope.includePersonal
        ? LoanFilter.personal
        : LoanFilter.household;
    final summary = loans.summaryOf(filter);
    final next = loans.upcoming(filter, limit: 1);
    final overdue = loans.overdue(filter);
    return AppCard(
      key: const Key('lendingOverviewCard'),
      onTap: () => openLendingScreen(context, filter: filter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Money lent',
            subtitle:
                '${summary.activeCount} active · '
                '${formatter.format(summary.receivedMinor)} received',
            trailing: const Icon(Icons.chevron_right_rounded),
          ),
          const SizedBox(height: Spacing.md),
          LabelAmountRow(
            label: const Text('Outstanding'),
            amount: Text(
              formatter.format(summary.outstandingMinor),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (overdue.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: context.finance.expense,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${overdue.length} overdue · '
                    '${formatter.format(summary.overdueMinor)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: context.finance.expense,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (next.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'Next: ${next.first.loan.borrowerName} · '
              '${formatter.format(next.first.installment.remainingMinor)} '
              'on ${lendingShortDate.format(next.first.installment.dueDate)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
