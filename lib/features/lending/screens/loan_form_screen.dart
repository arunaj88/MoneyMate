import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';

/// Records money lent, or edits a lending record ([snapshot]).
class LoanFormScreen extends StatefulWidget {
  const LoanFormScreen({
    super.key,
    this.snapshot,
    this.initialHousehold = false,
  });

  final LoanSnapshot? snapshot;
  final bool initialHousehold;

  @override
  State<LoanFormScreen> createState() => _LoanFormScreenState();
}

class _LoanFormScreenState extends State<LoanFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _amount = TextEditingController();
  final _installment = TextEditingController();
  final _months = TextEditingController();
  final _rate = TextEditingController();
  final _notes = TextEditingController();

  late DateTime _lentDate;
  LoanRepaymentType _type = LoanRepaymentType.monthly;
  DateTime? _firstDue;
  int? _dueDay;
  DateTime? _endDate;
  DateTime? _dueDate;
  bool _household = false;
  bool _saving = false;

  /// Monthly loans: the user gives the number of months and the monthly
  /// amount is calculated, instead of giving the monthly amount.
  bool _byMonths = false;

  /// How interest is worked out (asked only when there is interest).
  InterestMethod _method = InterestMethod.flat;

  bool get _isEditing => widget.snapshot != null;

  static final _dateFormat = DateFormat('EEE, d MMM yyyy');

  @override
  void initState() {
    super.initState();
    final today = PeriodUtils.dateOnly(DateTime.now());
    final loan = widget.snapshot?.loan;
    if (loan == null) {
      _lentDate = today;
      _household =
          widget.initialHousehold && context.read<LoanProvider>().hasHousehold;
      _firstDue = DateTime(today.year, today.month + 1, today.day);
      _dueDay = _firstDue!.day;
      _dueDate = DateTime(today.year, today.month + 1, today.day);
    } else {
      _name.text = loan.borrowerName;
      _phone.text = loan.borrowerPhone;
      _email.text = loan.borrowerEmail;
      _amount.text = Money.toInputString(loan.principalMinor);
      _rate.text = loan.interestRateBp == 0
          ? ''
          : loan.interestRateLabel.replaceAll('%', '');
      _notes.text = loan.notes;
      _lentDate = loan.lentDate;
      _type = loan.repaymentType;
      _method = loan.interestMethod;
      _household = loan.isHousehold;
      if (loan.installmentMinor case final amount?) {
        _installment.text = Money.toInputString(amount);
      }
      if (loan.isMonthly && loan.schedule.isNotEmpty) {
        _months.text = '${loan.schedule.length}';
      }
      _firstDue =
          loan.firstDueDate ?? DateTime(today.year, today.month + 1, today.day);
      _dueDay = loan.dueDay ?? _firstDue!.day;
      _endDate = loan.endDate;
      _dueDate =
          loan.dueDate ?? DateTime(today.year, today.month + 1, today.day);
    }
    for (final c in [_amount, _installment, _months, _rate]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _phone,
      _email,
      _amount,
      _installment,
      _months,
      _rate,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<DateTime?> _pick(
    DateTime initial, {
    required DateTime first,
    required DateTime last,
    required String help,
  }) => showDatePicker(
    context: context,
    initialDate: initial.isBefore(first)
        ? first
        : (initial.isAfter(last) ? last : initial),
    firstDate: first,
    lastDate: last,
    helpText: help,
  );

  DateTime get _farFuture => DateTime(DateTime.now().year + 50);

  /// What the borrower will owe and how the schedule turns out, or why the
  /// terms do not work.
  ({String text, bool error})? _preview(CurrencyFormatter formatter) {
    final principal = Money.parseToMinor(_amount.text);
    final rate = parseRateBp(_rate.text);
    if (principal == null || principal <= 0 || rate == null) return null;
    final monthly = _type == LoanRepaymentType.monthly;
    if (monthly && _byMonths) return _monthsPreview(principal, rate, formatter);
    final installment = Money.parseToMinor(_installment.text);
    if (monthly && (installment == null || installment <= 0)) {
      return null;
    }
    try {
      final quote = LoanCalculator.quote(
        principalMinor: principal,
        interestRateBp: rate,
        method: _method,
        type: _type,
        lentDate: _lentDate,
        installmentMinor: installment,
        dueDate: _dueDate,
      );
      final total = principal + quote.interestMinor;
      final interest = quote.interestMinor > 0
          ? ' (${formatter.format(quote.interestMinor)} interest)'
          : '';
      if (_type == LoanRepaymentType.oneTime) {
        return (
          text: 'Total to repay: ${formatter.format(total)}$interest',
          error: false,
        );
      }
      final first = _firstDue;
      if (first == null) return null;
      final last = LoanCalculator.monthlyDueDate(
        first,
        _dueDay ?? first.day,
        quote.installmentCount - 1,
      );
      final lastAmount = total - installment! * (quote.installmentCount - 1);
      final finalNote = lastAmount != installment
          ? ', the last one ${formatter.format(lastAmount)}'
          : '';
      return (
        text:
            '${quote.installmentCount} monthly instalment'
            '${quote.installmentCount == 1 ? '' : 's'}$finalNote. Last due '
            '${_dateFormat.format(last)}. Total to repay '
            '${formatter.format(total)}$interest.',
        error: false,
      );
    } on LoanException catch (e) {
      return (text: e.message, error: true);
    }
  }

  /// The monthly amount for the number of months entered.
  ({String text, bool error})? _monthsPreview(
    int principal,
    int rate,
    CurrencyFormatter formatter,
  ) {
    final months = int.tryParse(_months.text.trim());
    final first = _firstDue;
    if (months == null || months <= 0 || first == null) return null;
    try {
      final q = LoanCalculator.quoteForMonths(
        principalMinor: principal,
        interestRateBp: rate,
        months: months,
        method: _method,
      );
      final total = principal + q.interestMinor;
      final lastAmount = total - q.installmentMinor * (months - 1);
      final last = LoanCalculator.monthlyDueDate(
        first,
        _dueDay ?? first.day,
        months - 1,
      );
      final interest = q.interestMinor > 0
          ? ' (${formatter.format(q.interestMinor)} interest)'
          : '';
      final finalNote = months > 1 && lastAmount != q.installmentMinor
          ? ', the last one ${formatter.format(lastAmount)}'
          : '';
      final plural = months == 1 ? '' : 's';
      return (
        text:
            '${formatter.format(q.installmentMinor)} per month for $months '
            'month$plural$finalNote. Last due ${_dateFormat.format(last)}. '
            'Total to repay ${formatter.format(total)}$interest.',
        error: false,
      );
    } on LoanException catch (e) {
      return (text: e.message, error: true);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final loans = context.read<LoanProvider>();
    final principal = Money.parseToMinor(_amount.text)!;
    final rate = parseRateBp(_rate.text) ?? 0;
    final monthly = _type == LoanRepaymentType.monthly;
    final months = monthly && _byMonths
        ? int.tryParse(_months.text.trim())
        : null;
    final installment = monthly && !_byMonths
        ? Money.parseToMinor(_installment.text)
        : null;
    setState(() => _saving = true);
    try {
      final snapshot = widget.snapshot;
      if (snapshot == null) {
        final loan = await loans.createLoan(
          borrowerName: _name.text,
          borrowerPhone: _phone.text,
          borrowerEmail: _email.text,
          principalMinor: principal,
          lentDate: _lentDate,
          repaymentType: _type,
          interestRateBp: rate,
          interestMethod: _method,
          installmentMinor: installment,
          firstDueDate: _firstDue,
          dueDay: _dueDay,
          endDate: _endDate,
          dueDate: _dueDate,
          notes: _notes.text,
          household: _household,
          months: months,
        );
        if (!mounted) return;
        Navigator.of(context).pop(loan.id);
        showAppSnackBar(context, 'Lending record saved');
      } else {
        await loans.updateLoan(
          snapshot,
          borrowerName: _name.text,
          borrowerPhone: _phone.text,
          borrowerEmail: _email.text,
          principalMinor: principal,
          lentDate: _lentDate,
          repaymentType: _type,
          interestRateBp: rate,
          interestMethod: _method,
          installmentMinor: installment,
          firstDueDate: _firstDue,
          dueDay: _dueDay,
          endDate: _endDate,
          dueDate: _dueDate,
          notes: _notes.text,
          months: months,
        );
        if (!mounted) return;
        Navigator.of(context).pop(snapshot.id);
        showAppSnackBar(context, 'Lending record updated');
      }
    } on LoanException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, isError: true);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Could not save: $e', isError: true);
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
    final loans = context.watch<LoanProvider>();
    final today = PeriodUtils.dateOnly(DateTime.now());
    final symbol = '${formatter.currency.symbol.trim()} ';
    final preview = _preview(formatter);
    final received = widget.snapshot?.receivedMinor ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit lending record' : 'Lend money'),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(
              Spacing.lg,
              Spacing.sm,
              Spacing.lg,
              Spacing.xxl,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_isEditing) ...[
                  SegmentedButton<bool>(
                    key: const Key('loanScopeSelector'),
                    segments: [
                      const ButtonSegment(
                        value: false,
                        label: Text('Personal'),
                        icon: Icon(Icons.person_outline_rounded),
                      ),
                      ButtonSegment(
                        value: true,
                        label: const Text('Household'),
                        icon: const Icon(Icons.home_outlined),
                        enabled: loans.hasHousehold && loans.uid != null,
                      ),
                    ],
                    selected: {_household},
                    onSelectionChanged: (s) =>
                        setState(() => _household = s.first),
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    _household
                        ? 'Lent from household money. Every household member '
                              'can see it and record repayments; it changes '
                              'only the household balance.'
                        : 'Only you can see it. It changes only your '
                              'personal balance.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: Spacing.lg),
                ] else if (received > 0) ...[
                  _InfoBanner(
                    text:
                        '${formatter.format(received)} has been repaid. '
                        'Changing the amount or schedule keeps the '
                        'repayment history and instalments that received '
                        'money; only the unpaid rest is recalculated.',
                  ),
                  const SizedBox(height: Spacing.lg),
                ],
                Text('Borrower', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  key: const Key('borrowerNameField'),
                  controller: _name,
                  autofocus: !_isEditing,
                  maxLength: LoanLimits.nameMaxLength,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: "Borrower's name",
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? "Please enter the borrower's name"
                      : null,
                ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  key: const Key('borrowerPhoneField'),
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  maxLength: LoanLimits.phoneMaxLength,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ()\-]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Phone (optional)',
                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                  validator: (v) {
                    final text = (v ?? '').trim();
                    if (text.isEmpty) return null;
                    return RegExp(r'^\+?[0-9 ()\-]{5,}$').hasMatch(text)
                        ? null
                        : 'Enter a valid phone number';
                  },
                ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  key: const Key('borrowerEmailField'),
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  maxLength: LoanLimits.emailMaxLength,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email (optional)',
                    prefixIcon: Icon(Icons.alternate_email_rounded),
                    counterText: '',
                  ),
                  validator: (v) {
                    final text = (v ?? '').trim();
                    if (text.isEmpty) return null;
                    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text)
                        ? null
                        : 'Enter a valid email address';
                  },
                ),
                const SizedBox(height: Spacing.lg),
                Text('Loan', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  key: const Key('loanAmountField'),
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: amountInputFormatters,
                  style: theme.textTheme.headlineSmall,
                  decoration: InputDecoration(
                    labelText: 'Amount lent',
                    prefixText: symbol,
                  ),
                  validator: validateAmount,
                ),
                const SizedBox(height: Spacing.sm),
                ListTile(
                  key: const Key('lentDateField'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: const Text('Date lent'),
                  subtitle: Text(_dateFormat.format(_lentDate)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () async {
                    final picked = await _pick(
                      _lentDate,
                      first: DateTime(today.year - 50),
                      last: today,
                      help: 'Date lent',
                    );
                    if (picked != null) setState(() => _lentDate = picked);
                  },
                ),
                TextFormField(
                  key: const Key('interestRateField'),
                  controller: _rate,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Interest rate per year (optional)',
                    hintText: '0',
                    suffixText: '%',
                    helperText: 'Per year',
                    prefixIcon: Icon(Icons.percent_rounded),
                  ),
                  validator: (v) {
                    final bp = parseRateBp(v ?? '');
                    if (bp == null || bp > LoanLimits.maxInterestRateBp) {
                      return 'Enter a rate from 0 to 100';
                    }
                    return null;
                  },
                ),
                if ((parseRateBp(_rate.text) ?? 0) > 0 &&
                    _type == LoanRepaymentType.monthly) ...[
                  const SizedBox(height: Spacing.sm),
                  SegmentedButton<InterestMethod>(
                    key: const Key('interestMethodSelector'),
                    segments: [
                      for (final m in InterestMethod.values)
                        ButtonSegment(value: m, label: Text(m.label)),
                    ],
                    selected: {_method},
                    onSelectionChanged: (v) =>
                        setState(() => _method = v.first),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    _method == InterestMethod.flat
                        ? 'Flat: interest on the amount lent for the whole '
                              'term, the same every month.'
                        : 'Reducing balance: interest each month on what is '
                              'still owed, so it falls as capital is repaid.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.lg),
                Text('Repayment', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                SegmentedButton<LoanRepaymentType>(
                  key: const Key('repaymentTypeSelector'),
                  segments: [
                    for (final t in LoanRepaymentType.values)
                      ButtonSegment(
                        value: t,
                        label: Text(t.label),
                        icon: Icon(t.icon),
                      ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
                const SizedBox(height: Spacing.md),
                if (_type == LoanRepaymentType.monthly) ...[
                  SegmentedButton<bool>(
                    key: const Key('monthlyModeSelector'),
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
                      key: const Key('monthsField'),
                      controller: _months,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(3),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Repay over',
                        hintText: 'e.g. 12',
                        suffixText: 'months',
                        helperText: 'The monthly amount is calculated for you',
                        prefixIcon: Icon(Icons.date_range_outlined),
                      ),
                      validator: (v) {
                        final n = int.tryParse((v ?? '').trim());
                        if (n == null || n < 1) {
                          return 'Enter the number of months';
                        }
                        if (n > LoanLimits.maxInstallments) {
                          return 'At most ${LoanLimits.maxInstallments} months';
                        }
                        return null;
                      },
                    )
                  else
                    TextFormField(
                      key: const Key('installmentField'),
                      controller: _installment,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: amountInputFormatters,
                      decoration: InputDecoration(
                        labelText: 'Monthly instalment',
                        prefixText: symbol,
                      ),
                      validator: validateAmount,
                    ),
                  const SizedBox(height: Spacing.sm),
                  ListTile(
                    key: const Key('firstDueField'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_repeat_rounded),
                    title: const Text('First repayment'),
                    subtitle: Text(_dateFormat.format(_firstDue!)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      final picked = await _pick(
                        _firstDue!,
                        first: _lentDate,
                        last: _farFuture,
                        help: 'First repayment',
                      );
                      if (picked != null) {
                        setState(() {
                          _firstDue = picked;
                          _dueDay = picked.day;
                        });
                      }
                    },
                  ),
                  DropdownButtonFormField<int>(
                    key: const Key('dueDayField'),
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
                    onChanged: (d) => setState(() => _dueDay = d),
                  ),
                  const SizedBox(height: Spacing.sm),
                  ListTile(
                    key: const Key('endDateField'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.flag_outlined),
                    title: const Text('Expected final repayment (optional)'),
                    subtitle: Text(
                      _endDate == null
                          ? 'Not set'
                          : _dateFormat.format(_endDate!),
                    ),
                    trailing: _endDate == null
                        ? const Icon(Icons.chevron_right_rounded)
                        : IconButton(
                            tooltip: 'Remove date',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () => setState(() => _endDate = null),
                          ),
                    onTap: () async {
                      final picked = await _pick(
                        _endDate ?? _firstDue!,
                        first: _firstDue!,
                        last: _farFuture,
                        help: 'Expected final repayment',
                      );
                      if (picked != null) setState(() => _endDate = picked);
                    },
                  ),
                ] else
                  ListTile(
                    key: const Key('dueDateField'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.event_available_rounded),
                    title: const Text('Expected repayment date'),
                    subtitle: Text(_dateFormat.format(_dueDate!)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () async {
                      final picked = await _pick(
                        _dueDate!,
                        first: _lentDate,
                        last: _farFuture,
                        help: 'Expected repayment date',
                      );
                      if (picked != null) setState(() => _dueDate = picked);
                    },
                  ),
                if (preview != null) ...[
                  const SizedBox(height: Spacing.sm),
                  _InfoBanner(
                    key: const Key('loanPreview'),
                    text: preview.text,
                    error: preview.error,
                  ),
                ],
                const SizedBox(height: Spacing.lg),
                TextFormField(
                  key: const Key('loanNotesField'),
                  controller: _notes,
                  maxLength: LoanLimits.notesMaxLength,
                  maxLines: 3,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
                const SizedBox(height: Spacing.lg),
                FilledButton.icon(
                  key: const Key('saveLoanButton'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_isEditing ? 'Save changes' : 'Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({super.key, required this.text, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error ? theme.colorScheme.error : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Spacing.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.info_outline_rounded,
            size: 18,
            color: color,
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: error ? color : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
