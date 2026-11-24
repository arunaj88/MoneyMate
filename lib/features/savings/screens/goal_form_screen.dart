import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/features/savings/widgets/savings_widgets.dart';

/// Creates a savings goal, or edits [goal].
class GoalFormScreen extends StatefulWidget {
  const GoalFormScreen({
    super.key,
    this.goal,
    this.initialOwnership = SavingsOwnership.personal,
  });

  final SavingsGoal? goal;

  /// Kind of a new goal (an existing goal keeps its kind).
  final SavingsOwnership initialOwnership;

  @override
  State<GoalFormScreen> createState() => _GoalFormScreenState();
}

class _GoalFormScreenState extends State<GoalFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final _nameController = TextEditingController(
    text: widget.goal?.name ?? '',
  );
  late final _customPurposeController = TextEditingController(
    text: widget.goal?.customPurpose ?? '',
  );
  late final _targetController = TextEditingController(
    text: widget.goal == null
        ? ''
        : Money.toInputString(widget.goal!.targetMinor),
  );
  late final _notesController = TextEditingController(
    text: widget.goal?.notes ?? '',
  );
  late SavingsPurpose _purpose = widget.goal?.purpose ?? SavingsPurpose.trip;
  late SavingsOwnership _ownership =
      widget.goal?.ownership ?? widget.initialOwnership;
  late DateTime? _targetDate = widget.goal?.targetDate;
  bool _saving = false;

  bool get _isEditing => widget.goal != null;

  @override
  void dispose() {
    _nameController.dispose();
    _customPurposeController.dispose();
    _targetController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickTargetDate() async {
    final today = PeriodUtils.dateOnly(DateTime.now());
    final initial = _targetDate != null && !_targetDate!.isBefore(today)
        ? _targetDate!
        : DateTime(today.year + 1, today.month, today.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today,
      lastDate: DateTime(today.year + 50),
      helpText: 'Target date',
    );
    if (picked != null) setState(() => _targetDate = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final savings = context.read<SavingsProvider>();
    final target = Money.parseToMinor(_targetController.text)!;
    setState(() => _saving = true);
    try {
      final goal = widget.goal;
      if (goal == null) {
        await savings.createGoal(
          ownership: _ownership,
          name: _nameController.text,
          purpose: _purpose,
          customPurpose: _customPurposeController.text,
          targetMinor: target,
          targetDate: _targetDate,
          notes: _notesController.text,
        );
      } else {
        await savings.updateGoal(
          goal,
          name: _nameController.text,
          purpose: _purpose,
          customPurpose: _customPurposeController.text,
          targetMinor: target,
          targetDate: _targetDate,
          notes: _notesController.text,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnackBar(context, _isEditing ? 'Goal updated' : 'Goal created');
    } on SavingsException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, isError: true);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Could not save the goal: $e', isError: true);
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
    final saved = widget.goal?.savedMinor ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit goal' : 'New savings goal'),
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
                  _OwnershipSelector(
                    value: _ownership,
                    onChanged: (o) => setState(() => _ownership = o),
                  ),
                  const SizedBox(height: Spacing.lg),
                ],
                TextFormField(
                  key: const Key('goalNameField'),
                  controller: _nameController,
                  autofocus: !_isEditing,
                  maxLength: SavingsLimits.nameMaxLength,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Goal name',
                    hintText: 'e.g. Summer in Japan',
                    prefixIcon: Icon(Icons.flag_outlined),
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Please enter a name' : null,
                ),
                const SizedBox(height: Spacing.md),
                Text('Purpose', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.sm),
                Wrap(
                  spacing: Spacing.sm,
                  runSpacing: Spacing.sm,
                  children: [
                    for (final p in SavingsPurpose.values)
                      ChoiceChip(
                        key: Key('purpose-${p.name}'),
                        avatar: Icon(
                          p.icon,
                          size: 18,
                          color: purposeColor(context, p),
                        ),
                        label: Text(p.label),
                        selected: _purpose == p,
                        onSelected: (_) => setState(() => _purpose = p),
                      ),
                  ],
                ),
                if (_purpose == SavingsPurpose.other) ...[
                  const SizedBox(height: Spacing.md),
                  TextFormField(
                    key: const Key('customPurposeField'),
                    controller: _customPurposeController,
                    maxLength: SavingsLimits.purposeMaxLength,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Your purpose (optional)',
                      hintText: 'e.g. Wedding, New laptop',
                      prefixIcon: Icon(Icons.edit_outlined),
                    ),
                  ),
                ],
                const SizedBox(height: Spacing.lg),
                TextFormField(
                  key: const Key('goalTargetField'),
                  controller: _targetController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: amountInputFormatters,
                  style: theme.textTheme.headlineSmall,
                  decoration: InputDecoration(
                    labelText: 'Target amount',
                    prefixText: '${formatter.currency.symbol.trim()} ',
                    helperText: saved > 0
                        ? 'Saved so far: ${formatter.format(saved)}'
                        : null,
                  ),
                  validator: validateAmount,
                ),
                const SizedBox(height: Spacing.md),
                ListTile(
                  key: const Key('goalTargetDateField'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: const Text('Target date (optional)'),
                  subtitle: Text(
                    _targetDate == null
                        ? 'No deadline'
                        : DateFormat('EEEE, d MMMM yyyy').format(_targetDate!),
                  ),
                  trailing: _targetDate == null
                      ? const Icon(Icons.chevron_right_rounded)
                      : IconButton(
                          tooltip: 'Remove target date',
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () => setState(() => _targetDate = null),
                        ),
                  onTap: _pickTargetDate,
                ),
                const SizedBox(height: Spacing.sm),
                TextFormField(
                  key: const Key('goalNotesField'),
                  controller: _notesController,
                  maxLength: SavingsLimits.notesMaxLength,
                  maxLines: 3,
                  minLines: 1,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Description / notes (optional)',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
                const SizedBox(height: Spacing.lg),
                FilledButton.icon(
                  key: const Key('saveGoalButton'),
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_rounded),
                  label: Text(_isEditing ? 'Save changes' : 'Create goal'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Personal / Household / Shared, with what each means.
class _OwnershipSelector extends StatelessWidget {
  const _OwnershipSelector({required this.value, required this.onChanged});

  final SavingsOwnership value;
  final ValueChanged<SavingsOwnership> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final savings = context.watch<SavingsProvider>();
    bool enabled(SavingsOwnership o) => switch (o) {
      SavingsOwnership.personal => true,
      SavingsOwnership.household => savings.hasHousehold && savings.uid != null,
      SavingsOwnership.shared => savings.canUseShared,
    };
    final hint = switch (value) {
      SavingsOwnership.personal =>
        'Only you can see it. Money you add leaves your personal available '
            'balance.',
      SavingsOwnership.household =>
        'Everyone in your household can see it and contribute. Money added '
            'leaves the household available balance.',
      SavingsOwnership.shared =>
        'Invite friends who use MoneyMate. Each member records what they '
            "contribute; nobody's balance changes. Needs a connection.",
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<SavingsOwnership>(
          key: const Key('ownershipSelector'),
          segments: [
            for (final o in SavingsOwnership.values)
              ButtonSegment(
                value: o,
                label: Text(o.label),
                icon: Icon(o.icon),
                enabled: enabled(o),
              ),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: Spacing.sm),
        Text(
          hint,
          key: const Key('ownershipHint'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
