import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/features/lending/lending_actions.dart';
import 'package:money_mate/features/lending/widgets/lending_widgets.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';
import 'package:money_mate/shared/widgets/state_views.dart';

enum _Action { edit, reschedule, reminders, pause, resume, delete }

/// Everything about one lending record: figures, schedule, history and
/// actions. Opened from lists and from repayment reminders
/// ([installmentId] is then highlighted).
class LoanDetailsScreen extends StatefulWidget {
  const LoanDetailsScreen({
    super.key,
    required this.loanId,
    this.installmentId,
  });

  final String loanId;
  final String? installmentId;

  @override
  State<LoanDetailsScreen> createState() => _LoanDetailsScreenState();
}

class _LoanDetailsScreenState extends State<LoanDetailsScreen> {
  bool _showAllInstallments = false;

  @override
  void initState() {
    super.initState();
    final loans = context.read<LoanProvider>();
    if (!loans.hasLoaded) loans.load();
  }

  Future<void> _onAction(_Action action, LoanSnapshot snapshot) async {
    final loans = context.read<LoanProvider>();
    final loan = snapshot.loan;
    switch (action) {
      case _Action.edit:
        await openLoanForm(context, snapshot: snapshot);
      case _Action.reschedule:
        await showRescheduleSheet(context, snapshot);
      case _Action.reminders:
        await openReminderSettings(context, loan.id);
      case _Action.pause:
      case _Action.resume:
        try {
          if (action == _Action.pause) {
            await loans.pauseReminders(loan);
          } else {
            await loans.resumeReminders(loan);
          }
          if (mounted) {
            showAppSnackBar(
              context,
              action == _Action.pause
                  ? 'Reminders paused'
                  : 'Reminders resumed',
            );
          }
        } on LoanException catch (e) {
          if (mounted) showAppSnackBar(context, e.message, isError: true);
        }
      case _Action.delete:
        final confirmed = await showConfirmDialog(
          context,
          title: 'Delete this lending record?',
          message: snapshot.isCompleted || snapshot.receivedMinor == 0
              ? 'The record and its schedule will be removed and its '
                    'reminders cancelled.'
              : '${loan.borrowerName} still owes '
                    '${context.read<SettingsProvider>().formatter.format(snapshot.outstandingMinor)}. '
                    'The record and its schedule will be removed, its '
                    'reminders cancelled, and the unpaid amount no longer '
                    'counts as lent. Repayment records stay in the cloud '
                    'history.',
          confirmLabel: 'Delete',
          destructive: true,
        );
        if (!confirmed || !mounted) return;
        try {
          await loans.deleteLoan(loan);
          if (!mounted) return;
          Navigator.of(context).pop();
          showAppSnackBar(context, 'Lending record deleted');
        } on LoanException catch (e) {
          if (mounted) showAppSnackBar(context, e.message, isError: true);
        }
    }
  }

  Future<void> _void(LoanRepayment repayment) async {
    final reason = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Void this repayment?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'It stays in the history, marked as voided, and no longer '
              'counts towards what was repaid.',
            ),
            const SizedBox(height: Spacing.md),
            TextField(
              key: const Key('voidReasonField'),
              controller: reason,
              maxLength: LoanLimits.voidReasonMaxLength,
              decoration: const InputDecoration(labelText: 'Reason (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirmVoidButton'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Void'),
          ),
        ],
      ),
    );
    final text = reason.text;
    reason.dispose();
    if (confirmed != true || !mounted) return;
    try {
      await context.read<LoanProvider>().voidRepayment(repayment, reason: text);
      if (mounted) showAppSnackBar(context, 'Repayment voided');
    } on LoanException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loans = context.watch<LoanProvider>();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final snapshot = loans.snapshotById(widget.loanId);
    if (snapshot == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Lending record')),
        body: loans.isLoading && !loans.hasLoaded
            ? const LoadingView()
            : const EmptyState(
                icon: Icons.search_off_rounded,
                title: 'This lending record no longer exists',
                message: 'It may have been deleted on another device.',
              ),
      );
    }
    final loan = snapshot.loan;
    final canManage = loans.canManage(loan);
    final reminders = loans.reminderSettingsOf(loan.id);
    final highlighted = widget.installmentId == null
        ? null
        : snapshot.installmentById(widget.installmentId!);

    return Scaffold(
      appBar: AppBar(
        title: Text(loan.borrowerName),
        actions: [
          if (canManage)
            PopupMenuButton<_Action>(
              key: const Key('loanActionsMenu'),
              onSelected: (a) => _onAction(a, snapshot),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: _Action.edit,
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Edit'),
                  ),
                ),
                if (!snapshot.isCompleted)
                  const PopupMenuItem(
                    value: _Action.reschedule,
                    child: ListTile(
                      leading: Icon(Icons.event_repeat_rounded),
                      title: Text('Reschedule repayments'),
                    ),
                  ),
                const PopupMenuItem(
                  value: _Action.reminders,
                  child: ListTile(
                    leading: Icon(Icons.notifications_outlined),
                    title: Text('Reminder settings'),
                  ),
                ),
                if (loans.canEditReminders(loan) && !snapshot.isCompleted)
                  reminders.paused || !reminders.enabled
                      ? const PopupMenuItem(
                          value: _Action.resume,
                          child: ListTile(
                            leading: Icon(Icons.notifications_active_outlined),
                            title: Text('Resume reminders'),
                          ),
                        )
                      : const PopupMenuItem(
                          value: _Action.pause,
                          child: ListTile(
                            leading: Icon(Icons.notifications_paused_outlined),
                            title: Text('Pause reminders'),
                          ),
                        ),
                if (loans.canDelete(loan))
                  const PopupMenuItem(
                    value: _Action.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline_rounded),
                      title: Text('Delete'),
                    ),
                  ),
              ],
            ),
        ],
      ),
      floatingActionButton: canManage && !snapshot.isCompleted
          ? FloatingActionButton.extended(
              key: const Key('recordRepaymentButton'),
              onPressed: () => showRepaymentSheet(
                context,
                snapshot,
                installment: highlighted,
              ),
              icon: const Icon(Icons.add_task_rounded),
              label: const Text('Record repayment'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: loans.load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            96,
          ),
          children: [
            if (highlighted != null && !highlighted.isPaid) ...[
              _ReminderBanner(
                snapshot: snapshot,
                installment: highlighted,
                formatter: formatter,
                canRecord: canManage,
              ),
              const SizedBox(height: Spacing.md),
            ],
            _SummaryCard(snapshot: snapshot, formatter: formatter),
            const SizedBox(height: Spacing.md),
            _DetailsCard(
              snapshot: snapshot,
              formatter: formatter,
              remindersLabel: !reminders.enabled
                  ? 'Off'
                  : reminders.paused
                  ? 'Paused'
                  : loans.remindsMe(loan)
                  ? 'On for you'
                  : 'On (not for you)',
            ),
            const SizedBox(height: Spacing.md),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SectionHeader(
                    title: loan.isMonthly
                        ? 'Repayment schedule'
                        : 'Expected repayment',
                    subtitle: loan.isMonthly
                        ? '${snapshot.installments.where((i) => i.isPaid).length} '
                              'of ${snapshot.installments.length} paid'
                        : null,
                  ),
                  const SizedBox(height: Spacing.sm),
                  ..._installments(snapshot, highlighted, formatter, canManage),
                ],
              ),
            ),
            if (_revisions(loans.repaymentsOf(loan.id)).isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              _EmiHistoryCard(
                loan: loan,
                revisions: _revisions(loans.repaymentsOf(loan.id)),
                formatter: formatter,
              ),
            ],
            const SizedBox(height: Spacing.md),
            AppCard(
              key: const Key('repaymentHistory'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(title: 'Payment history'),
                  const SizedBox(height: Spacing.sm),
                  if (loans.repaymentsOf(loan.id).isEmpty)
                    const EmptyState(
                      compact: true,
                      icon: Icons.history_rounded,
                      title: 'No repayments yet',
                    )
                  else
                    for (final r in loans.repaymentsOf(loan.id))
                      RepaymentTile(
                        repayment: r,
                        formatter: formatter,
                        recordedBy: loan.isHousehold
                            ? (r.userUid == loans.uid
                                  ? 'by you'
                                  : r.userName == null
                                  ? null
                                  : 'by ${r.userName}')
                            : null,
                        onVoid: canManage ? () => _void(r) : null,
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _installments(
    LoanSnapshot snapshot,
    InstallmentView? highlighted,
    CurrencyFormatter formatter,
    bool canManage,
  ) {
    final all = snapshot.installments;
    // Long schedules show the instalments around the next one first.
    final next = all.indexWhere((i) => !i.isPaid);
    final start = _showAllInstallments || all.length <= 8
        ? 0
        : (next < 0 ? all.length - 3 : (next - 2).clamp(0, all.length));
    final end = _showAllInstallments || all.length <= 8
        ? all.length
        : (start + 6).clamp(0, all.length);
    final visible = all.sublist(start, end);
    return [
      for (final i in visible)
        InstallmentTile(
          view: i,
          formatter: formatter,
          highlighted: i.id == highlighted?.id,
          onRecord: canManage
              ? () => showRepaymentSheet(context, snapshot, installment: i)
              : null,
        ),
      if (visible.length < all.length)
        Center(
          child: TextButton(
            key: const Key('showAllInstallments'),
            onPressed: () => setState(() => _showAllInstallments = true),
            child: Text('Show all ${all.length} instalments'),
          ),
        ),
    ];
  }
}

/// Repayments that paid extra capital and revised the EMI, oldest first
/// (voided ones excluded: their effect is undone).
List<LoanRepayment> _revisions(List<LoanRepayment> repayments) => [
  for (final r in repayments.reversed)
    if (r.counts && (r.allocation?.extraPrincipalMinor ?? 0) > 0) r,
];

/// The original agreement and every EMI revision since.
class _EmiHistoryCard extends StatelessWidget {
  const _EmiHistoryCard({
    required this.loan,
    required this.revisions,
    required this.formatter,
  });

  final Loan loan;
  final List<LoanRepayment> revisions;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AppCard(
      key: const Key('emiHistory'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'EMI changes',
            subtitle: 'Extra repayments reduced the capital',
          ),
          const SizedBox(height: Spacing.sm),
          if (loan.originalInstallmentMinor != null)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.handshake_outlined),
              title: Text(
                'Agreed: ${formatter.format(loan.originalInstallmentMinor!)}'
                '${loan.originalTermMonths == null ? '' : ' × ${loan.originalTermMonths} months'}',
              ),
              subtitle: Text(
                'Lent ${formatter.format(loan.principalMinor)} on '
                '${lendingDate.format(loan.lentDate)}',
                style: muted,
              ),
            ),
          for (final r in revisions)
            ListTile(
              key: Key('emiRevision-${r.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.trending_down_rounded),
              title: Text(
                r.allocation!.revisedEmiMinor == null
                    ? 'Settled early'
                    : '${r.allocation!.previousEmiMinor == null ? '' : '${formatter.format(r.allocation!.previousEmiMinor!)} → '}'
                          '${formatter.format(r.allocation!.revisedEmiMinor!)}'
                          '${r.allocation!.effectiveFrom == null ? '' : ' from ${lendingDate.format(r.allocation!.effectiveFrom!)}'}',
              ),
              subtitle: Text(
                '${formatter.format(r.allocation!.extraPrincipalMinor)} extra '
                'to capital on ${lendingDate.format(r.date)} · capital '
                '${formatter.format(r.allocation!.principalAfterMinor)} · '
                '${r.allocation!.remainingInstallments} month(s) left',
                style: muted,
              ),
            ),
        ],
      ),
    );
  }
}

class _ReminderBanner extends StatelessWidget {
  const _ReminderBanner({
    required this.snapshot,
    required this.installment,
    required this.formatter,
    required this.canRecord,
  });

  final LoanSnapshot snapshot;
  final InstallmentView installment;
  final CurrencyFormatter formatter;
  final bool canRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = installmentStatusColor(context, installment.status);
    return AppCard(
      key: const Key('reminderBanner'),
      color: color.withValues(alpha: 0.08),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${snapshot.loan.isMonthly ? 'EMI ${installment.number}' : 'Repayment'} '
            '· ${installment.status.label} · due '
            '${lendingDate.format(installment.dueDate)}',
            style: theme.textTheme.titleSmall?.copyWith(color: color),
          ),
          const SizedBox(height: Spacing.xs),
          Text(
            '${formatter.format(installment.remainingMinor)} of this '
            'instalment is unpaid; ${formatter.format(snapshot.outstandingMinor)} '
            'is outstanding in total. Nothing is recorded until you add a '
            'repayment.',
            style: theme.textTheme.bodySmall,
          ),
          if (canRecord) ...[
            const SizedBox(height: Spacing.md),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                FilledButton.tonal(
                  key: const Key('bannerRecordInstallment'),
                  onPressed: () => showRepaymentSheet(
                    context,
                    snapshot,
                    installment: installment,
                  ),
                  child: const Text('Record full or partial repayment'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.snapshot, required this.formatter});

  final LoanSnapshot snapshot;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loan = snapshot.loan;
    final color = loanStatusColor(context, snapshot.status);
    final next = snapshot.nextDue;
    return AppCard(
      key: const Key('loanSummaryCard'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Outstanding',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              StatusChip(label: snapshot.status.label, color: color),
            ],
          ),
          const SizedBox(height: Spacing.xs),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              formatter.format(snapshot.outstandingMinor),
              key: const Key('loanOutstandingText'),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: Spacing.md),
          RepaymentProgressBar(
            progress: snapshot.progress,
            color: color,
            height: 8,
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            '${formatter.format(snapshot.receivedMinor)} of '
            '${formatter.format(loan.totalOwedMinor)} repaid '
            '(${(snapshot.progress * 100).floor()}%)',
            key: const Key('loanReceivedText'),
            style: theme.textTheme.bodySmall,
          ),
          if (next != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              'Next: ${formatter.format(next.remainingMinor)} due '
              '${lendingDate.format(next.dueDate)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: installmentStatusColor(context, next.status),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (snapshot.overdueMinor > 0) ...[
            const SizedBox(height: Spacing.xs),
            Text(
              'Overdue: ${formatter.format(snapshot.overdueMinor)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.finance.expense,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({
    required this.snapshot,
    required this.formatter,
    required this.remindersLabel,
  });

  final LoanSnapshot snapshot;
  final CurrencyFormatter formatter;
  final String remindersLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loan = snapshot.loan;
    Widget row(String label, String value, {Key? key}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LabelAmountRow(
        label: Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        amount: Text(
          value,
          key: key,
          textAlign: TextAlign.end,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        maxAmountFraction: 0.6,
      ),
    );
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Details'),
          const SizedBox(height: Spacing.sm),
          row('Amount lent', formatter.format(loan.principalMinor)),
          row('Date lent', lendingDate.format(loan.lentDate)),
          row('Repayment', loan.repaymentType.label),
          if (loan.isMonthly && loan.installmentMinor != null)
            row(
              'Current EMI',
              '${formatter.format(loan.installmentMinor!)} on day '
                  '${loan.dueDay ?? loan.firstDueDate?.day}',
              key: const Key('currentEmiText'),
            ),
          if (loan.isMonthly &&
              loan.originalInstallmentMinor != null &&
              loan.originalInstallmentMinor != loan.installmentMinor)
            row(
              'Original EMI',
              '${formatter.format(loan.originalInstallmentMinor!)}'
                  '${loan.originalTermMonths == null ? '' : ' × ${loan.originalTermMonths} months'}',
              key: const Key('originalEmiText'),
            ),
          if (loan.isMonthly)
            row('Instalments left', '${snapshot.remainingInstallments}'),
          if (loan.isMonthly && loan.endDate != null)
            row('Expected to finish', lendingDate.format(loan.endDate!)),
          if (!loan.isMonthly && loan.dueDate != null)
            row('Expected repayment', lendingDate.format(loan.dueDate!)),
          if (loan.interestRateBp > 0) ...[
            row(
              'Interest',
              '${loan.interestRateLabel} a year '
                  '(${loan.isMonthly ? loan.interestMethod.label.toLowerCase() : 'simple'})',
            ),
            row('Total interest', formatter.format(loan.interestMinor)),
            row(
              'Principal repaid',
              formatter.format(snapshot.principalReceivedMinor),
              key: const Key('principalReceivedText'),
            ),
            row(
              'Interest received',
              formatter.format(snapshot.interestReceivedMinor),
              key: const Key('interestReceivedText'),
            ),
          ],
          row('Scope', loan.isHousehold ? 'Household' : 'Personal'),
          if (loan.isHousehold && loan.createdByName != null)
            row('Recorded by', loan.createdByName!),
          row('Reminders', remindersLabel),
          if (loan.borrowerPhone.isNotEmpty) row('Phone', loan.borrowerPhone),
          if (loan.borrowerEmail.isNotEmpty) row('Email', loan.borrowerEmail),
          if (loan.notes.isNotEmpty) ...[
            const SizedBox(height: Spacing.sm),
            Text(loan.notes, style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}
