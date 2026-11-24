import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/recurring_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/features/household/widgets/household_widgets.dart';
import 'package:money_mate/features/transactions/transaction_actions.dart';
import 'package:money_mate/features/transactions/widgets/category_picker.dart';

/// Form for creating or editing an income / expense transaction.
class AddEditTransactionScreen extends StatefulWidget {
  const AddEditTransactionScreen({
    super.key,
    this.transaction,
    this.initialType,
  });

  final TransactionModel? transaction;
  final TransactionType? initialType;

  @override
  State<AddEditTransactionScreen> createState() =>
      _AddEditTransactionScreenState();
}

class _AddEditTransactionScreenState extends State<AddEditTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amountController;
  late final TextEditingController _noteController;
  late TransactionType _type;
  String? _categoryId;
  late DateTime _date;
  late PaymentMethod _paymentMethod;
  late TransactionScope _scope;

  /// How a new transaction repeats; null = it does not.
  RecurrenceFrequency? _repeat;
  bool _saving = false;

  bool get _isEditing => widget.transaction != null;

  @override
  void initState() {
    super.initState();
    final t = widget.transaction;
    _type = t?.type ?? widget.initialType ?? TransactionType.expense;
    _amountController = TextEditingController(
      text: t != null ? Money.toInputString(t.amountMinor) : '',
    );
    _noteController = TextEditingController(text: t?.note ?? '');
    _categoryId = t?.categoryId;
    _date = t?.date ?? DateTime.now();
    _paymentMethod = t?.paymentMethod ?? PaymentMethod.cash;
    // New transactions follow the current view: shared when the user is
    // looking at shared data, otherwise personal.
    final view = context.read<TransactionScopeProvider>();
    _scope =
        t?.scope ??
        (view.canShare && view.view == ViewScope.shared
            ? TransactionScope.shared
            : TransactionScope.personal);
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _changeType(TransactionType type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      final category = context.read<CategoryProvider>().byIdOrNull(
        _categoryId ?? '',
      );
      if (category == null || category.type != type) _categoryId = null;
    });
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, now.month, now.day),
      helpText: 'Transaction date',
    );
    if (picked == null) return;
    setState(() {
      // Keep the original time of day so ordering within a day is stable.
      _date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _date.hour,
        _date.minute,
        _date.second,
      );
    });
  }

  Future<void> _pickRepeat() async {
    final picked = await showModalBottomSheet<_RepeatChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => _RepeatSheet(selected: _repeat, date: _date),
    );
    if (picked == null || !mounted) return;
    setState(() => _repeat = picked.frequency);
  }

  /// Explicit confirmation before a transaction changes owner.
  Future<bool> _confirmMove(String householdName) => showConfirmDialog(
    context,
    title: _scope == TransactionScope.shared
        ? 'Share with $householdName?'
        : 'Make this transaction personal?',
    message: _scope == TransactionScope.shared
        ? 'Every member of $householdName will be able to see, edit and '
              'delete it.'
        : 'It will be removed from $householdName for every member and '
              'only you will see it.',
    confirmLabel: _scope == TransactionScope.shared ? 'Share' : 'Move',
  );

  Future<void> _save() async {
    if (_saving) return;
    if (!_formKey.currentState!.validate()) return;
    final amount = Money.parseToMinor(_amountController.text)!;
    final provider = context.read<TransactionProvider>();
    final scope = context.read<TransactionScopeProvider>();
    final user = context.read<AuthProvider>().user;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final householdName = scope.householdName ?? 'your household';

    if (_scope == TransactionScope.shared && !scope.canShare) {
      showAppSnackBar(
        context,
        'Create or join a household to add shared transactions.',
        isError: true,
      );
      return;
    }
    final original = widget.transaction;
    final moving = original != null && original.scope != _scope;
    if (moving && !await _confirmMove(householdName)) return;
    if (!mounted) return;

    final repeat = _isEditing ? null : _repeat;
    var successMessage = _isEditing
        ? (moving
              ? (_scope == TransactionScope.shared
                    ? 'Shared with $householdName'
                    : 'Moved to personal')
              : 'Transaction updated')
        : '${_type.label} of '
              '${context.read<SettingsProvider>().formatter.format(amount)} '
              'added${_scope == TransactionScope.shared ? ' to $householdName' : ''}'
              '${repeat != null ? ' · repeats ${repeat.label.toLowerCase()}' : ''}';
    final recurring = context.read<RecurringProvider>();

    setState(() => _saving = true);
    try {
      if (original != null) {
        var edited = original.copyWith(
          type: _type,
          amountMinor: amount,
          categoryId: _categoryId,
          date: _date,
          note: _noteController.text,
          paymentMethod: _paymentMethod,
          // Records from before accounts existed get their author now.
          createdBy: original.createdBy ?? user?.uid,
          createdByName: original.createdByName ?? user?.name,
        );
        if (moving) {
          edited = edited.withScope(
            _scope,
            householdId: scope.householdId,
            updatedAt: DateTime.now(),
            updatedBy: user?.uid,
          );
        }
        await provider.updateTransaction(edited, updatedBy: user?.uid);
      } else if (repeat != null) {
        final added = await recurring.addRule(
          type: _type,
          amountMinor: amount,
          categoryId: _categoryId!,
          startDate: _date,
          frequency: repeat,
          note: _noteController.text,
          paymentMethod: _paymentMethod,
          scope: _scope,
          householdId: scope.householdId,
          createdBy: user?.uid,
          createdByName: user?.name,
        );
        // A start date in the past also adds the repeats since then.
        if (added > 1) {
          successMessage =
              '$added ${_type.label.toLowerCase()} entries added · repeats '
              '${repeat.label.toLowerCase()}';
        }
      } else {
        await provider.addTransaction(
          type: _type,
          amountMinor: amount,
          categoryId: _categoryId!,
          date: _date,
          note: _noteController.text,
          paymentMethod: _paymentMethod,
          scope: _scope,
          householdId: scope.householdId,
          createdBy: user?.uid,
          createdByName: user?.name,
        );
      }
      navigator.pop();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppSnackBar(context, 'Could not save: $e', isError: true);
    }
  }

  Future<void> _delete() async {
    final deleted = await confirmAndDeleteTransaction(
      context,
      widget.transaction!,
    );
    if (deleted && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final currency = context.select<SettingsProvider, String>(
      (s) => s.currency.symbol.trim(),
    );
    final categories = context.select<CategoryProvider, List<CategoryModel>>(
      (p) => p.forType(_type),
    );
    final typeColor = _type == TransactionType.income
        ? finance.income
        : finance.expense;
    final scope = context.watch<TransactionScopeProvider>();
    final household = context.watch<HouseholdProvider>();
    final canRepeat =
        !_isEditing &&
        context.select<RecurringProvider, bool>((r) => r.isAvailable);
    final createdLabel = widget.transaction == null
        ? null
        : sharedLabelFor(household, widget.transaction!);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit transaction' : 'New transaction'),
        actions: [
          if (_isEditing)
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          // A non-lazy scroll view so every FormField is built and validated.
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
                SegmentedButton<TransactionScope>(
                  key: const Key('scopeSelector'),
                  segments: [
                    const ButtonSegment(
                      value: TransactionScope.personal,
                      label: Text('Personal'),
                      icon: Icon(Icons.person_outline_rounded),
                    ),
                    ButtonSegment(
                      value: TransactionScope.shared,
                      label: const Text('Shared household'),
                      icon: const Icon(Icons.group_outlined),
                      // Without a household only an existing shared record
                      // (being moved back) can stay shared.
                      enabled:
                          scope.canShare ||
                          widget.transaction?.isShared == true,
                    ),
                  ],
                  selected: {_scope},
                  onSelectionChanged: (s) => setState(() => _scope = s.first),
                ),
                const SizedBox(height: Spacing.sm),
                if (!scope.canShare)
                  _HouseholdHint(onOpen: () => openHouseholdScreen(context))
                else
                  Text(
                    _scope == TransactionScope.shared
                        ? 'Visible to everyone in '
                              '${scope.householdName ?? 'your household'}'
                              '${createdLabel != null ? ' · ${createdLabel.replaceFirst('Shared · ', 'added by ')}' : ''}'
                        : 'Only you can see this transaction',
                    key: const Key('scopeHint'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(height: Spacing.lg),
                SegmentedButton<TransactionType>(
                  key: const Key('typeSelector'),
                  segments: const [
                    ButtonSegment(
                      value: TransactionType.expense,
                      label: Text('Expense'),
                      icon: Icon(Icons.arrow_upward_rounded),
                    ),
                    ButtonSegment(
                      value: TransactionType.income,
                      label: Text('Income'),
                      icon: Icon(Icons.arrow_downward_rounded),
                    ),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => _changeType(s.first),
                  style: ButtonStyle(
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? typeColor.withValues(alpha: 0.15)
                          : null,
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.selected)
                          ? typeColor
                          : null,
                    ),
                  ),
                ),
                const SizedBox(height: Spacing.xl),
                TextFormField(
                  key: const Key('amountField'),
                  controller: _amountController,
                  autofocus: !_isEditing,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: amountInputFormatters,
                  textInputAction: TextInputAction.next,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: typeColor,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    prefixText: '$currency ',
                    prefixStyle: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  validator: validateAmount,
                ),
                const SizedBox(height: Spacing.xl),
                Text('Category', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                FormField<String>(
                  key: ValueKey('categoryField-${_type.name}'),
                  initialValue: _categoryId,
                  validator: (_) =>
                      _categoryId == null ? 'Please choose a category' : null,
                  builder: (field) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CategoryPicker(
                        categories: categories,
                        selectedId: _categoryId,
                        onSelected: (id) {
                          setState(() => _categoryId = id);
                          field.didChange(id);
                        },
                      ),
                      if (field.hasError)
                        Padding(
                          padding: const EdgeInsets.only(top: Spacing.sm),
                          child: Text(
                            field.errorText!,
                            style: TextStyle(
                              color: theme.colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: Spacing.xl),
                _FieldTile(
                  icon: Icons.calendar_today_rounded,
                  label: 'Date',
                  value: DateFormat('EEEE, d MMMM yyyy').format(_date),
                  onTap: _pickDate,
                ),
                if (canRepeat) ...[
                  const SizedBox(height: Spacing.sm),
                  _FieldTile(
                    key: const Key('repeatField'),
                    icon: Icons.repeat_rounded,
                    label: 'Repeat',
                    value: _repeat == null
                        ? 'Does not repeat'
                        : RecurringRule.describe(_repeat!, _date),
                    onTap: _pickRepeat,
                  ),
                ],
                const SizedBox(height: Spacing.lg),
                Text('Payment method', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final method in PaymentMethod.values)
                      ChoiceChip(
                        label: Text(method.label),
                        avatar: Icon(_paymentIcon(method), size: 18),
                        selected: _paymentMethod == method,
                        onSelected: (_) =>
                            setState(() => _paymentMethod = method),
                      ),
                  ],
                ),
                const SizedBox(height: Spacing.xl),
                TextFormField(
                  key: const Key('noteField'),
                  controller: _noteController,
                  maxLength: 200,
                  maxLines: 2,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Description / notes (optional)',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
                const SizedBox(height: Spacing.lg),
                FilledButton.icon(
                  key: const Key('saveTransactionButton'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(
                    _isEditing ? 'Save changes' : 'Add ${_type.label}',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static IconData _paymentIcon(PaymentMethod method) {
    switch (method) {
      case PaymentMethod.cash:
        return Icons.payments_outlined;
      case PaymentMethod.card:
        return Icons.credit_card_rounded;
      case PaymentMethod.bankTransfer:
        return Icons.account_balance_outlined;
      case PaymentMethod.other:
        return Icons.more_horiz_rounded;
    }
  }
}

/// Shown instead of the scope hint when the user has no household.
class _HouseholdHint extends StatelessWidget {
  const _HouseholdHint({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            'Shared transactions need a household.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          key: const Key('createOrJoinHousehold'),
          onPressed: onOpen,
          child: const Text('Create or join'),
        ),
      ],
    );
  }
}

/// Result of the repeat sheet (wraps null = "does not repeat").
class _RepeatChoice {
  const _RepeatChoice(this.frequency);

  final RecurrenceFrequency? frequency;
}

/// Bottom sheet for choosing how a new transaction repeats.
class _RepeatSheet extends StatelessWidget {
  const _RepeatSheet({required this.selected, required this.date});

  final RecurrenceFrequency? selected;
  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget option(RecurrenceFrequency? frequency, String title, String? sub) {
      final isSelected = frequency == selected;
      return ListTile(
        key: Key('repeat-${frequency?.name ?? 'never'}'),
        leading: Icon(
          isSelected
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_off_rounded,
          color: isSelected ? theme.colorScheme.primary : null,
        ),
        title: Text(title),
        subtitle: sub == null ? null : Text(sub),
        onTap: () => Navigator.of(context).pop(_RepeatChoice(frequency)),
      );
    }

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                0,
                Spacing.lg,
                Spacing.sm,
              ),
              child: Text('Repeat', style: theme.textTheme.titleMedium),
            ),
            option(null, 'Does not repeat', null),
            for (final f in RecurrenceFrequency.values)
              option(f, f.label, RecurringRule.describe(f, date)),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                Spacing.sm,
                Spacing.lg,
                Spacing.lg,
              ),
              child: Text(
                'Repeats are added automatically when they fall due. Stop '
                'one any time in Settings → Recurring transactions.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldTile extends StatelessWidget {
  const _FieldTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.inputDecorationTheme.fillColor,
      borderRadius: BorderRadius.circular(Spacing.radiusSm),
      child: InkWell(
        borderRadius: BorderRadius.circular(Spacing.radiusSm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodySmall),
                    Text(value, style: theme.textTheme.bodyLarge),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );
  }
}
