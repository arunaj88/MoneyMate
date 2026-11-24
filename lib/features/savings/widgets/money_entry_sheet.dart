import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/providers/dashboard_provider.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/features/savings/widgets/savings_widgets.dart';

/// Bottom sheet that moves money into a goal (Add money) or back out of it
/// (Withdraw money).
class MoneyEntrySheet extends StatefulWidget {
  const MoneyEntrySheet({
    super.key,
    required this.type,
    this.initialGoal,
    this.ownership = SavingsOwnership.personal,
  });

  final SavingsEntryType type;
  final SavingsGoal? initialGoal;

  /// Which goals can be picked.
  final SavingsOwnership ownership;

  @override
  State<MoneyEntrySheet> createState() => _MoneyEntrySheetState();
}

class _MoneyEntrySheetState extends State<MoneyEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  late String? _goalId = widget.initialGoal?.id;
  DateTime _date = PeriodUtils.dateOnly(DateTime.now());
  bool _saving = false;
  String? _error;

  bool get _isDeposit => widget.type == SavingsEntryType.deposit;

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  /// Goals of this kind that can take this kind of entry from the user.
  List<SavingsGoal> _eligible(SavingsProvider savings) => [
    for (final g in savings.goalsOf(widget.ownership))
      if (_isDeposit
          ? g.isActive && savings.canContribute(g)
          : g.savedMinor > 0 && savings.canWithdraw(g))
        g,
  ];

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: now,
      helpText: _isDeposit ? 'Contribution date' : 'Withdrawal date',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _submit(SavingsGoal? goal) async {
    setState(() => _error = null);
    if (!_formKey.currentState!.validate() || goal == null) return;
    final amount = Money.parseToMinor(_amountController.text)!;
    final savings = context.read<SavingsProvider>();
    final formatter = context.read<SettingsProvider>().formatter;
    setState(() => _saving = true);
    try {
      if (_isDeposit) {
        await savings.addMoney(
          goal,
          amountMinor: amount,
          date: _date,
          note: _noteController.text,
        );
      } else {
        await savings.withdrawMoney(
          goal,
          amountMinor: amount,
          date: _date,
          note: _noteController.text,
        );
      }
      if (!mounted) return;
      final updated = savings.goalById(goal.id);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.hideCurrentSnackBar();
      final reached =
          _isDeposit &&
          updated != null &&
          updated.isActive &&
          updated.targetReached &&
          savings.canManage(updated);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            reached
                ? '🎉 ${goal.name} reached its target!'
                : _isDeposit
                ? 'Added ${formatter.format(amount)} to ${goal.name}'
                : 'Withdrew ${formatter.format(amount)} from ${goal.name}',
          ),
          action: reached
              ? SnackBarAction(
                  label: 'Complete',
                  onPressed: () => savings.completeGoal(updated),
                )
              : null,
        ),
      );
    } on SavingsException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final savings = context.watch<SavingsProvider>();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    // The available balance this goal draws on, when the dashboard shows
    // that view (personal or household). Shared goals draw on none.
    final dashboard = context.select<DashboardProvider, int?>((d) {
      final data = d.data;
      if (data == null) return null;
      return switch (widget.ownership) {
        SavingsOwnership.personal when data.scope.includePersonal =>
          data.availableMinor,
        SavingsOwnership.household when !data.scope.includePersonal =>
          data.availableMinor,
        _ => null,
      };
    });
    final goals = _eligible(savings);
    // The goal may have been deleted or become ineligible meanwhile.
    final goal = goals.where((g) => g.id == _goalId).firstOrNull;
    final color = _isDeposit ? finance.income : finance.warning;
    final title = _isDeposit ? 'Add money' : 'Withdraw money';

    final amount = Money.parseToMinor(_amountController.text) ?? 0;
    String? hint;
    if (_isDeposit && dashboard != null) {
      hint = amount > dashboard
          ? 'This is more than your available balance '
                '(${formatter.format(dashboard)}).'
          : 'Available balance: ${formatter.format(dashboard)}';
    } else if (!_isDeposit && goal != null) {
      hint = 'Saved in this goal: ${formatter.format(goal.savedMinor)}';
    }

    return Padding(
      // Keeps the form above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            0,
            Spacing.lg,
            Spacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: theme.textTheme.titleLarge),
              const SizedBox(height: Spacing.xs),
              Text(
                switch ((widget.ownership, _isDeposit)) {
                  (SavingsOwnership.shared, true) =>
                    'Records your contribution to the shared goal. It is not '
                        'deducted from your MoneyMate balance. Works offline; '
                        'it is uploaded when you are back online.',
                  (SavingsOwnership.shared, false) =>
                    'Takes money out of the shared goal. Needs a connection '
                        'so the latest balance can be checked.',
                  (SavingsOwnership.household, true) =>
                    'Moves household money into the goal. It is not counted '
                        'as an expense.',
                  (SavingsOwnership.household, false) =>
                    'Moves money back to the household balance (not income). '
                        'Needs a connection so the latest balance can be '
                        'checked.',
                  (_, true) =>
                    'Moves money from your available balance into a goal. '
                        'It is not counted as an expense.',
                  (_, false) =>
                    'Moves money from a goal back to your available '
                        'balance. It is not counted as income.',
                },
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: Spacing.lg),
              if (goals.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Spacing.lg),
                  child: Text(
                    _isDeposit
                        ? 'There is no active goal you can add money to. '
                              'Create or resume a goal first.'
                        : 'There is no goal you can withdraw money from.',
                    textAlign: TextAlign.center,
                  ),
                )
              else ...[
                DropdownButtonFormField<String>(
                  key: const Key('moneyGoalField'),
                  initialValue: goal?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Savings goal',
                    prefixIcon: Icon(Icons.flag_outlined),
                  ),
                  items: [
                    for (final g in goals)
                      DropdownMenuItem(
                        value: g.id,
                        child: Row(
                          children: [
                            Icon(
                              g.purpose.icon,
                              size: 20,
                              color: purposeColor(context, g.purpose),
                            ),
                            const SizedBox(width: Spacing.sm),
                            Expanded(
                              child: Text(
                                g.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  validator: (v) => v == null ? 'Please choose a goal' : null,
                  onChanged: (v) => setState(() => _goalId = v),
                ),
                const SizedBox(height: Spacing.lg),
                TextFormField(
                  key: const Key('moneyAmountField'),
                  controller: _amountController,
                  autofocus: widget.initialGoal != null,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: amountInputFormatters,
                  style: theme.textTheme.headlineSmall?.copyWith(color: color),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: '${formatter.currency.symbol.trim()} ',
                    helperText: hint,
                    helperMaxLines: 2,
                  ),
                  onChanged: (_) => setState(() {}),
                  validator: (value) {
                    final base = validateAmount(value);
                    if (base != null) return base;
                    final minor = Money.parseToMinor(value!)!;
                    if (!_isDeposit &&
                        goal != null &&
                        minor > goal.savedMinor) {
                      return 'Only ${formatter.format(goal.savedMinor)} is '
                          'saved in this goal';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: Spacing.md),
                ListTile(
                  key: const Key('moneyDateField'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_rounded),
                  title: const Text('Date'),
                  subtitle: Text(DateFormat('EEEE, d MMMM yyyy').format(_date)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _pickDate,
                ),
                TextFormField(
                  key: const Key('moneyNoteField'),
                  controller: _noteController,
                  maxLength: SavingsLimits.entryNoteMaxLength,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: Spacing.sm),
                  Text(
                    _error!,
                    key: const Key('moneyError'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: Spacing.lg),
                FilledButton.icon(
                  key: const Key('saveMoneyButton'),
                  onPressed: _saving ? null : () => _submit(goal),
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _isDeposit ? Icons.add_rounded : Icons.remove_rounded,
                        ),
                  label: Text(title),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
