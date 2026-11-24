import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/category_avatar.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';

/// Opens the editor for a new or existing category budget.
Future<void> showCategoryBudgetSheet(
  BuildContext context, {
  required BudgetPeriod period,
  CategoryBudget? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Read the keyboard inset from the sheet's own context: the caller's
    // context sits under a Scaffold that has already consumed it (always 0).
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: _CategoryBudgetSheet(period: period, existing: existing),
    ),
  );
}

class _CategoryBudgetSheet extends StatefulWidget {
  const _CategoryBudgetSheet({required this.period, this.existing});

  final BudgetPeriod period;
  final CategoryBudget? existing;

  @override
  State<_CategoryBudgetSheet> createState() => _CategoryBudgetSheetState();
}

class _CategoryBudgetSheetState extends State<_CategoryBudgetSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount = TextEditingController(
    text: widget.existing != null
        ? Money.toInputString(widget.existing!.amountMinor)
        : '',
  );
  late BudgetPeriod _period = widget.existing?.period ?? widget.period;
  String? _categoryId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _categoryId = widget.existing?.categoryId;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    try {
      await context.read<BudgetProvider>().saveCategoryBudget(
        id: widget.existing?.id,
        categoryId: _categoryId!,
        period: _period,
        amountMinor: Money.parseToMinor(_amount.text)!,
      );
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showAppSnackBar(context, 'Could not save budget: $e', isError: true);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete category budget?',
      message: 'Your transactions are not affected.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    final navigator = Navigator.of(context);
    await context.read<BudgetProvider>().deleteCategoryBudget(
      widget.existing!.id,
    );
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final budget = context.read<BudgetProvider>();
    final currency = context.read<SettingsProvider>().currency.symbol.trim();
    final available = budget.availableCategoriesFor(
      _period,
      includeCategoryId: widget.existing?.period == _period
          ? widget.existing?.categoryId
          : null,
    );
    if (_categoryId != null && !available.any((c) => c.id == _categoryId)) {
      _categoryId = null;
    }

    return SafeArea(
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            0,
            Spacing.lg,
            Spacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.existing == null
                          ? 'New category budget'
                          : 'Edit category budget',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  if (widget.existing != null)
                    IconButton(
                      tooltip: 'Delete',
                      onPressed: _delete,
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
                ],
              ),
              const SizedBox(height: Spacing.lg),
              SegmentedButton<BudgetPeriod>(
                segments: const [
                  ButtonSegment(
                    value: BudgetPeriod.weekly,
                    label: Text('Weekly'),
                  ),
                  ButtonSegment(
                    value: BudgetPeriod.monthly,
                    label: Text('Monthly'),
                  ),
                ],
                selected: {_period},
                onSelectionChanged: (s) => setState(() => _period = s.first),
              ),
              const SizedBox(height: Spacing.lg),
              if (available.isEmpty)
                Text(
                  'Every expense category already has a ${_period.label.toLowerCase()} budget.',
                  style: theme.textTheme.bodyMedium,
                )
              else
                DropdownButtonFormField<String>(
                  key: ValueKey('category-${_period.name}'),
                  initialValue: _categoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    for (final CategoryModel c in available)
                      DropdownMenuItem(
                        value: c.id,
                        child: Row(
                          children: [
                            CategoryAvatar(category: c, size: 28),
                            const SizedBox(width: Spacing.md),
                            Flexible(
                              child: Text(
                                c.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _categoryId = v),
                  validator: (v) =>
                      v == null ? 'Please choose a category' : null,
                ),
              const SizedBox(height: Spacing.lg),
              TextFormField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: amountInputFormatters,
                decoration: InputDecoration(
                  labelText: '${_period.label} limit',
                  prefixText: '$currency ',
                ),
                validator: validateAmount,
              ),
              const SizedBox(height: Spacing.xl),
              FilledButton(
                onPressed: _saving || available.isEmpty ? null : _save,
                child: Text(widget.existing == null ? 'Create budget' : 'Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
