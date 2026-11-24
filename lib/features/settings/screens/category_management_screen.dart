import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/category_icons.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/category_model.dart';
import '../../../models/transaction_model.dart';
import '../../../providers/category_provider.dart';
import '../../../shared/widgets/category_avatar.dart';
import '../../../shared/widgets/dialogs.dart';

/// Lists categories and lets the user add, edit and delete custom ones.
class CategoryManagementScreen extends StatelessWidget {
  const CategoryManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Builder(
        builder: (context) {
          return Scaffold(
            appBar: AppBar(
              title: const Text('Categories'),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Expense'),
                  Tab(text: 'Income'),
                ],
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () {
                final index = DefaultTabController.of(context).index;
                showCategoryEditor(
                  context,
                  type: index == 0
                      ? TransactionType.expense
                      : TransactionType.income,
                );
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('New category'),
            ),
            body: const TabBarView(
              children: [
                _CategoryList(type: TransactionType.expense),
                _CategoryList(type: TransactionType.income),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.type});

  final TransactionType type;

  Future<void> _delete(BuildContext context, CategoryModel category) async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete "${category.name}"?',
      message:
          'Transactions in this category will be moved to "Other". '
          'Category budgets for it will be removed.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await context.read<CategoryProvider>().deleteCategory(category);
      if (context.mounted) showAppSnackBar(context, 'Category deleted');
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(context, 'Could not delete: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = context.watch<CategoryProvider>().forType(type);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.lg,
        Spacing.lg,
        100,
      ),
      itemCount: categories.length,
      separatorBuilder: (_, __) => const SizedBox(height: Spacing.sm),
      itemBuilder: (context, i) {
        final c = categories[i];
        return Card(
          child: ListTile(
            leading: CategoryAvatar(category: c, size: 40),
            title: Text(c.name),
            subtitle: Text(c.isDefault ? 'Built-in' : 'Custom'),
            onTap: () => showCategoryEditor(context, type: type, existing: c),
            trailing: c.isDefault
                ? const Icon(Icons.edit_outlined, size: 20)
                : IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _delete(context, c),
                  ),
          ),
        );
      },
    );
  }
}

/// Bottom sheet for creating or editing a category.
Future<void> showCategoryEditor(
  BuildContext context, {
  required TransactionType type,
  CategoryModel? existing,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: _CategoryEditor(type: type, existing: existing),
    ),
  );
}

class _CategoryEditor extends StatefulWidget {
  const _CategoryEditor({required this.type, this.existing});

  final TransactionType type;
  final CategoryModel? existing;

  @override
  State<_CategoryEditor> createState() => _CategoryEditorState();
}

class _CategoryEditorState extends State<_CategoryEditor> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late String _iconKey = widget.existing?.iconKey ?? 'other';
  late int _color =
      widget.existing?.colorValue ?? CategoryColors.palette.first.toARGB32();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final provider = context.read<CategoryProvider>();
    final navigator = Navigator.of(context);
    final error = await provider.validateName(
      _name.text,
      widget.type,
      excludeId: widget.existing?.id,
    );
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() => _saving = true);
    try {
      if (widget.existing == null) {
        await provider.addCategory(
          name: _name.text,
          type: widget.type,
          iconKey: _iconKey,
          colorValue: _color,
        );
      } else {
        await provider.updateCategory(
          widget.existing!.copyWith(
            name: _name.text,
            iconKey: _iconKey,
            colorValue: _color,
          ),
        );
      }
      navigator.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = CategoryModel(
      id: 'preview',
      name: _name.text,
      type: widget.type,
      iconKey: _iconKey,
      colorValue: _color,
    );
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          0,
          Spacing.lg,
          Spacing.lg,
        ),
        children: [
          Row(
            children: [
              CategoryAvatar(category: preview, size: 48),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Text(
                  widget.existing == null
                      ? 'New ${widget.type.label.toLowerCase()} category'
                      : 'Edit category',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          TextField(
            controller: _name,
            autofocus: widget.existing == null,
            maxLength: 30,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(labelText: 'Name', errorText: _error),
            onChanged: (_) => setState(() => _error = null),
          ),
          Text('Icon', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.sm),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              for (final entry in CategoryIcons.icons.entries)
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _iconKey = entry.key),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: entry.key == _iconKey
                          ? Color(_color).withValues(alpha: 0.18)
                          : null,
                      border: Border.all(
                        color: entry.key == _iconKey
                            ? Color(_color)
                            : theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: Icon(
                      entry.value,
                      color: entry.key == _iconKey ? Color(_color) : null,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.lg),
          Text('Colour', style: theme.textTheme.titleSmall),
          const SizedBox(height: Spacing.sm),
          // Each swatch keeps its 34px look inside a 44px touch target.
          Wrap(
            children: [
              for (final color in CategoryColors.palette)
                Semantics(
                  button: true,
                  selected: color.toARGB32() == _color,
                  label: 'Colour',
                  child: InkResponse(
                    radius: 24,
                    onTap: () => setState(() => _color = color.toARGB32()),
                    child: SizedBox.square(
                      dimension: 44,
                      child: Center(
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: color.toARGB32() == _color
                                  ? theme.colorScheme.onSurface
                                  : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                          child: color.toARGB32() == _color
                              ? const Icon(
                                  Icons.check_rounded,
                                  color: Colors.white,
                                  size: 18,
                                )
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Spacing.xl),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(widget.existing == null ? 'Create category' : 'Save'),
          ),
        ],
      ),
    );
  }
}
