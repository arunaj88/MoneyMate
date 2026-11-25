import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';

/// Records a full or partial repayment of a loan (optionally of one
/// [installment]). Nothing is ever recorded without the user saving it.
class RepaymentSheet extends StatefulWidget {
  const RepaymentSheet({super.key, required this.loanId, this.installmentId});

  final String loanId;
  final String? installmentId;

  @override
  State<RepaymentSheet> createState() => _RepaymentSheetState();
}

class _RepaymentSheetState extends State<RepaymentSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _note = TextEditingController();
  DateTime _date = PeriodUtils.dateOnly(DateTime.now());
  PaymentMethod _method = PaymentMethod.cash;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final snapshot = context.read<LoanProvider>().snapshotById(widget.loanId);
    // Repayments always go to the first unpaid instalment.
    final installment = snapshot?.nextDue ?? _installment(snapshot);
    final suggested = installment?.remainingMinor ?? snapshot?.outstandingMinor;
    if (suggested != null && suggested > 0) {
      _amount.text = Money.toInputString(suggested);
    }
    _amount.addListener(() => setState(() {}));
  }

  InstallmentView? _installment(LoanSnapshot? snapshot) {
    final id = widget.installmentId;
    return id == null ? null : snapshot?.installmentById(id);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate(LoanSnapshot snapshot) async {
    final today = PeriodUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: PeriodUtils.dateOnly(snapshot.loan.lentDate),
      lastDate: today,
      helpText: 'Payment date',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save(LoanSnapshot snapshot) async {
    if (!_formKey.currentState!.validate()) return;
    final loans = context.read<LoanProvider>();
    setState(() => _saving = true);
    try {
      final amount = Money.parseToMinor(_amount.text)!;
      await loans.recordRepayment(
        snapshot,
        amountMinor: amount,
        date: _date,
        method: _method,
        note: _note.text,
        installmentId: widget.installmentId ?? snapshot.nextDue?.id,
      );
      if (!mounted) return;
      final completed =
          amount >= context.read<LoanProvider>().maxRepaymentMinor(snapshot);
      Navigator.of(context).pop(true);
      showAppSnackBar(
        context,
        completed
            ? 'Repayment recorded. ${snapshot.loan.borrowerName} has repaid '
                  'everything.'
            : 'Repayment recorded',
      );
    } on LoanException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, isError: true);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Could not record the repayment: $e',
          isError: true,
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final snapshot = context.watch<LoanProvider>().snapshotById(widget.loanId);
    if (snapshot == null) {
      return const Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: Text('This lending record no longer exists.'),
      );
    }
    final loans = context.read<LoanProvider>();
    final outstanding = snapshot.outstandingMinor;
    final max = loans.maxRepaymentMinor(snapshot);
    final installment = snapshot.nextDue ?? _installment(snapshot);
    final entered = Money.parseToMinor(_amount.text) ?? 0;
    final showsExtra =
        snapshot.loan.isMonthly &&
        installment != null &&
        entered > installment.remainingMinor &&
        entered <= max;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.lg,
        0,
        Spacing.lg,
        Spacing.lg + bottom,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Repayment from ${snapshot.loan.borrowerName}',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: Spacing.xs),
              Text(
                'Outstanding: ${formatter.format(outstanding)}',
                key: const Key('repaymentOutstanding'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              TextFormField(
                key: const Key('repaymentAmountField'),
                controller: _amount,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: amountInputFormatters,
                style: theme.textTheme.headlineSmall,
                decoration: InputDecoration(
                  labelText: 'Amount received',
                  prefixText: '${formatter.currency.symbol.trim()} ',
                ),
                validator: (v) {
                  final base = validateAmount(v);
                  if (base != null) return base;
                  final minor = Money.parseToMinor(v ?? '')!;
                  if (minor > max) {
                    return 'No more than ${formatter.format(max)}';
                  }
                  return null;
                },
              ),
              const SizedBox(height: Spacing.sm),
              Wrap(
                spacing: Spacing.sm,
                children: [
                  if (installment != null && installment.remainingMinor < max)
                    ActionChip(
                      key: const Key('repaymentInstallmentChip'),
                      label: Text(
                        '${snapshot.loan.isMonthly ? 'This EMI' : 'Due'}: '
                        '${formatter.format(installment.remainingMinor)}',
                      ),
                      onPressed: () => _amount.text = Money.toInputString(
                        installment.remainingMinor,
                      ),
                    ),
                  ActionChip(
                    key: const Key('repaymentFullChip'),
                    label: Text(
                      max < outstanding
                          ? 'Settle the loan: ${formatter.format(max)}'
                          : 'Everything: ${formatter.format(max)}',
                    ),
                    onPressed: () => _amount.text = Money.toInputString(max),
                  ),
                ],
              ),
              if (showsExtra) ...[
                const SizedBox(height: Spacing.md),
                _ExtraPaymentPanel(
                  allocation: loans.previewRepayment(
                    snapshot,
                    amountMinor: entered,
                    date: _date,
                  ),
                  amountMinor: entered,
                  formatter: formatter,
                ),
              ],
              const SizedBox(height: Spacing.md),
              ListTile(
                key: const Key('repaymentDateField'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: const Text('Payment date'),
                subtitle: Text(DateFormat('EEEE, d MMMM yyyy').format(_date)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickDate(snapshot),
              ),
              DropdownButtonFormField<PaymentMethod>(
                key: const Key('repaymentMethodField'),
                initialValue: _method,
                decoration: const InputDecoration(
                  labelText: 'Payment method',
                  prefixIcon: Icon(Icons.payments_outlined),
                ),
                items: [
                  for (final m in PaymentMethod.values)
                    DropdownMenuItem(value: m, child: Text(m.label)),
                ],
                onChanged: (m) => setState(() => _method = m ?? _method),
              ),
              const SizedBox(height: Spacing.md),
              TextFormField(
                key: const Key('repaymentNoteField'),
                controller: _note,
                maxLength: LoanLimits.repaymentNoteMaxLength,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Note (optional)',
                  prefixIcon: Icon(Icons.notes_rounded),
                ),
              ),
              const SizedBox(height: Spacing.sm),
              FilledButton.icon(
                key: const Key('saveRepaymentButton'),
                onPressed: _saving ? null : () => _save(snapshot),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: const Text('Record repayment'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What happens to a repayment above the EMI: the extra reduces the
/// capital and the remaining EMIs are recalculated.
class _ExtraPaymentPanel extends StatelessWidget {
  const _ExtraPaymentPanel({
    required this.allocation,
    required this.amountMinor,
    required this.formatter,
  });

  final RepaymentAllocation allocation;
  final int amountMinor;
  final CurrencyFormatter formatter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = allocation;
    final color = theme.colorScheme.primary;
    final settled = a.remainingInstallments == 0;
    Widget row(String label, String value, {Key? key, bool strong = false}) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodySmall)),
              const SizedBox(width: Spacing.sm),
              Flexible(
                flex: 2,
                child: Text(
                  value,
                  key: key,
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
    final previous = a.previousEmiMinor;
    final revised = a.revisedEmiMinor;
    return Container(
      key: const Key('extraPaymentPanel'),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Spacing.radiusSm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            settled
                ? 'This settles the loan'
                : 'The extra reduces the capital and lowers the remaining '
                      'EMIs',
            style: theme.textTheme.titleSmall?.copyWith(color: color),
          ),
          const SizedBox(height: Spacing.sm),
          row(
            'Scheduled EMI'
            '${a.installmentNumber == null ? '' : ' (no. ${a.installmentNumber})'}',
            formatter.format(a.scheduledEmiMinor),
          ),
          row('Amount received', formatter.format(amountMinor)),
          row(
            'Extra applied to capital',
            formatter.format(a.extraPrincipalMinor),
            key: const Key('extraToCapitalText'),
            strong: true,
          ),
          row(
            'Capital before → after',
            '${formatter.format(a.principalBeforeMinor)} → '
                '${formatter.format(a.principalAfterMinor)}',
          ),
          if (previous != null || revised != null)
            row(
              'EMI before → revised',
              '${previous == null ? '–' : formatter.format(previous)} → '
                  '${revised == null ? '–' : formatter.format(revised)}',
              key: const Key('revisedEmiText'),
              strong: true,
            ),
          row(
            'Remaining period',
            '${a.remainingInstallments} month'
                '${a.remainingInstallments == 1 ? '' : 's'}',
          ),
          if (a.effectiveFrom != null)
            row(
              'New EMI from',
              DateFormat('d MMM yyyy').format(a.effectiveFrom!),
            ),
        ],
      ),
    );
  }
}

/// Changes the unpaid part of a loan's schedule.
class RescheduleSheet extends StatefulWidget {
  const RescheduleSheet({super.key, required this.loanId});

  final String loanId;

  @override
  State<RescheduleSheet> createState() => _RescheduleSheetState();
}

class _RescheduleSheetState extends State<RescheduleSheet> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _months = TextEditingController();
  late DateTime _date;
  late int _dueDay;
  bool _saving = false;

  /// Spread the rest over a number of months instead of a set amount.
  bool _byMonths = false;

  @override
  void initState() {
    super.initState();
    final snapshot = context.read<LoanProvider>().snapshotById(widget.loanId);
    final loan = snapshot?.loan;
    final today = PeriodUtils.dateOnly(DateTime.now());
    final next = snapshot?.nextDue?.dueDate;
    _date = next != null && next.isAfter(today)
        ? next
        : DateTime(today.year, today.month + 1, today.day);
    _dueDay = loan?.dueDay ?? _date.day;
    if (loan?.installmentMinor case final amount?) {
      _amount.text = Money.toInputString(amount);
    }
    _months.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    _months.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = PeriodUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(today) ? today : _date,
      firstDate: today,
      lastDate: DateTime(today.year + 50),
      helpText: 'Next repayment',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save(LoanSnapshot snapshot) async {
    if (!_formKey.currentState!.validate()) return;
    final loans = context.read<LoanProvider>();
    setState(() => _saving = true);
    try {
      if (snapshot.loan.isMonthly) {
        await loans.reschedule(
          snapshot,
          installmentMinor: _byMonths ? null : Money.parseToMinor(_amount.text),
          months: _byMonths ? int.tryParse(_months.text.trim()) : null,
          nextDueDate: _date,
          dueDay: _dueDay,
        );
      } else {
        await loans.reschedule(snapshot, dueDate: _date);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
      showAppSnackBar(context, 'Schedule updated');
    } on LoanException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// "AED 1,000.00 per month" for the months entered.
  String _monthsHelper(LoanSnapshot snapshot, CurrencyFormatter formatter) {
    final n = int.tryParse(_months.text.trim());
    if (n == null || n < 1) return 'The monthly amount is calculated for you';
    try {
      final amount = context.read<LoanProvider>().monthlyAmountForRest(
        snapshot,
        n,
      );
      return '${formatter.format(amount)} per month';
    } on LoanException catch (e) {
      return e.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final snapshot = context.watch<LoanProvider>().snapshotById(widget.loanId);
    if (snapshot == null) return const SizedBox.shrink();
    final monthly = snapshot.loan.isMonthly;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Spacing.lg,
        0,
        Spacing.lg,
        Spacing.lg + bottom,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Reschedule repayments', style: theme.textTheme.titleLarge),
              const SizedBox(height: Spacing.xs),
              Text(
                'Paid and partly paid instalments and the repayment history '
                'stay as they are. ${formatter.format(snapshot.outstandingMinor)} '
                'is still to be repaid.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              if (monthly) ...[
                SegmentedButton<bool>(
                  key: const Key('rescheduleModeSelector'),
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Monthly amount'),
                      icon: Icon(Icons.payments_outlined),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Number of months'),
                      icon: Icon(Icons.date_range_outlined),
                    ),
                  ],
                  selected: {_byMonths},
                  onSelectionChanged: (v) =>
                      setState(() => _byMonths = v.first),
                ),
                const SizedBox(height: Spacing.md),
                if (_byMonths)
                  TextFormField(
                    key: const Key('rescheduleMonthsField'),
                    controller: _months,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Repay the rest over',
                      suffixText: 'months',
                      helperText: _monthsHelper(snapshot, formatter),
                    ),
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      if (n == null || n < 1) {
                        return 'Enter the number of months';
                      }
                      try {
                        context.read<LoanProvider>().monthlyAmountForRest(
                          snapshot,
                          n,
                        );
                      } on LoanException catch (e) {
                        return e.message;
                      }
                      return null;
                    },
                  )
                else
                  TextFormField(
                    key: const Key('rescheduleAmountField'),
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: amountInputFormatters,
                    decoration: InputDecoration(
                      labelText: 'Monthly instalment',
                      prefixText: '${formatter.currency.symbol.trim()} ',
                    ),
                    validator: validateAmount,
                  ),
                const SizedBox(height: Spacing.md),
              ],
              ListTile(
                key: const Key('rescheduleDateField'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_outlined),
                title: Text(
                  monthly ? 'Next repayment' : 'Expected repayment date',
                ),
                subtitle: Text(DateFormat('EEEE, d MMMM yyyy').format(_date)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickDate,
              ),
              if (monthly)
                DropdownButtonFormField<int>(
                  key: const Key('rescheduleDueDayField'),
                  initialValue: _dueDay,
                  decoration: const InputDecoration(
                    labelText: 'Due every month on day',
                    helperText: 'Shorter months use their last day',
                    prefixIcon: Icon(Icons.calendar_month_outlined),
                  ),
                  items: [
                    for (var d = 1; d <= 31; d++)
                      DropdownMenuItem(value: d, child: Text('$d')),
                  ],
                  onChanged: (d) => setState(() => _dueDay = d ?? _dueDay),
                ),
              const SizedBox(height: Spacing.lg),
              FilledButton.icon(
                key: const Key('saveRescheduleButton'),
                onPressed: _saving ? null : () => _save(snapshot),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save schedule'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
