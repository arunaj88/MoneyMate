import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/category_model.dart';
import '../../../models/transaction_model.dart';
import '../../../providers/category_provider.dart';
import '../../../providers/transaction_provider.dart';
import '../../../shared/widgets/category_avatar.dart';

/// Search field with a short debounce so typing doesn't query on every key.
class TransactionSearchField extends StatefulWidget {
  const TransactionSearchField({super.key});

  @override
  State<TransactionSearchField> createState() => _TransactionSearchFieldState();
}

class _TransactionSearchFieldState extends State<TransactionSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<TransactionProvider>().filter.query,
  );
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() {}); // refresh clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) context.read<TransactionProvider>().setQuery(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const Key('transactionSearchField'),
      controller: _controller,
      onChanged: _onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search notes, categories, payment…',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  _controller.clear();
                  _onChanged('');
                },
              ),
      ),
    );
  }
}

/// Horizontal chips for type, date range and category filters.
class TransactionFilterBar extends StatelessWidget {
  const TransactionFilterBar({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.read<TransactionProvider>();
    final filter = context.select<TransactionProvider, TransactionFilter>(
      (p) => p.filter,
    );
    final dateFormat = DateFormat('d MMM');

    String dateLabel() {
      if (filter.start == null && filter.end == null) return 'Any date';
      final start = filter.start;
      final end = filter.end == null
          ? null
          : DateTime(filter.end!.year, filter.end!.month, filter.end!.day - 1);
      if (start != null && end != null) {
        return '${dateFormat.format(start)} – ${dateFormat.format(end)}';
      }
      return start != null
          ? 'From ${dateFormat.format(start)}'
          : 'Until ${dateFormat.format(end!)}';
    }

    Future<void> pickDates() async {
      final now = DateTime.now();
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime(now.year + 1, 12, 31),
        initialDateRange: filter.start != null && filter.end != null
            ? DateTimeRange(
                start: filter.start!,
                end: DateTime(
                  filter.end!.year,
                  filter.end!.month,
                  filter.end!.day - 1,
                ),
              )
            : null,
        helpText: 'Filter by date',
      );
      if (picked == null) return;
      await provider.setFilter(
        filter.copyWith(
          start: () =>
              DateTime(picked.start.year, picked.start.month, picked.start.day),
          end: () =>
              DateTime(picked.end.year, picked.end.month, picked.end.day + 1),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: Row(
        children: [
          for (final option in <TransactionType?>[
            null,
            TransactionType.expense,
            TransactionType.income,
          ])
            Padding(
              padding: const EdgeInsets.only(right: Spacing.sm),
              child: ChoiceChip(
                label: Text(option?.label ?? 'All'),
                selected: filter.type == option,
                onSelected: (_) =>
                    provider.setFilter(filter.copyWith(type: () => option)),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: Spacing.sm),
            child: FilterChip(
              avatar: const Icon(Icons.date_range_rounded, size: 18),
              label: Text(dateLabel()),
              selected: filter.start != null || filter.end != null,
              onSelected: (_) => pickDates(),
              onDeleted: filter.start != null || filter.end != null
                  ? () => provider.setFilter(
                      filter.copyWith(start: () => null, end: () => null),
                    )
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: Spacing.sm),
            child: FilterChip(
              avatar: const Icon(Icons.category_outlined, size: 18),
              label: Text(
                filter.categoryIds.isEmpty
                    ? 'All categories'
                    : '${filter.categoryIds.length} '
                          '${filter.categoryIds.length == 1 ? 'category' : 'categories'}',
              ),
              selected: filter.categoryIds.isNotEmpty,
              onSelected: (_) => _pickCategories(context, filter),
              onDeleted: filter.categoryIds.isNotEmpty
                  ? () => provider.setFilter(filter.copyWith(categoryIds: {}))
                  : null,
            ),
          ),
          if (filter.activeFilterCount > 0)
            TextButton.icon(
              onPressed: provider.clearFilters,
              icon: const Icon(Icons.filter_alt_off_rounded, size: 18),
              label: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  Future<void> _pickCategories(
    BuildContext context,
    TransactionFilter filter,
  ) async {
    final categories = context.read<CategoryProvider>();
    final selected = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CategoryFilterSheet(
        expense: categories.expenseCategories,
        income: categories.incomeCategories,
        initial: filter.categoryIds,
        type: filter.type,
      ),
    );
    if (selected == null || !context.mounted) return;
    await context.read<TransactionProvider>().setFilter(
      filter.copyWith(categoryIds: selected),
    );
  }
}

class _CategoryFilterSheet extends StatefulWidget {
  const _CategoryFilterSheet({
    required this.expense,
    required this.income,
    required this.initial,
    required this.type,
  });

  final List<CategoryModel> expense;
  final List<CategoryModel> income;
  final Set<String> initial;
  final TransactionType? type;

  @override
  State<_CategoryFilterSheet> createState() => _CategoryFilterSheetState();
}

class _CategoryFilterSheetState extends State<_CategoryFilterSheet> {
  late final Set<String> _selected = {...widget.initial};

  Widget _group(String title, List<CategoryModel> categories) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: Spacing.sm),
        Wrap(
          spacing: Spacing.sm,
          runSpacing: Spacing.sm,
          children: [
            for (final c in categories)
              FilterChip(
                avatar: CategoryAvatar(category: c, size: 22),
                label: Text(c.name),
                selected: _selected.contains(c.id),
                onSelected: (value) => setState(
                  () => value ? _selected.add(c.id) : _selected.remove(c.id),
                ),
              ),
          ],
        ),
        const SizedBox(height: Spacing.lg),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Filter by category',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(_selected.clear),
                    child: const Text('Reset'),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(Spacing.lg),
                children: [
                  if (widget.type != TransactionType.income)
                    _group('Expense', widget.expense),
                  if (widget.type != TransactionType.expense)
                    _group('Income', widget.income),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.lg,
                0,
                Spacing.lg,
                Spacing.lg,
              ),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: Text(
                    _selected.isEmpty
                        ? 'Show all categories'
                        : 'Apply (${_selected.length})',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
