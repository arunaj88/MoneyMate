import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/recurring_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/shared/widgets/category_avatar.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/state_views.dart';

/// Lists recurring transactions and lets the user stop them.
class RecurringScreen extends StatefulWidget {
  const RecurringScreen({super.key});

  @override
  State<RecurringScreen> createState() => _RecurringScreenState();
}

class _RecurringScreenState extends State<RecurringScreen> {
  @override
  void initState() {
    super.initState();
    context.read<RecurringProvider>().load();
  }

  Future<void> _stop(RecurringRule rule) async {
    final recurring = context.read<RecurringProvider>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Stop repeating?',
      message:
          'No new entries will be added. Transactions it already added are '
          'kept.',
      confirmLabel: 'Stop',
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      await recurring.stopRule(rule);
      if (mounted) showAppSnackBar(context, 'Stopped repeating');
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Could not stop it: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final recurring = context.watch<RecurringProvider>();
    final householdId = context.select<TransactionProvider, String?>(
      (t) => t.householdId,
    );
    final rules = recurring.rules;

    return Scaffold(
      appBar: AppBar(title: const Text('Recurring transactions')),
      body: SafeArea(
        child: !recurring.hasLoaded
            ? const LoadingView()
            : rules.isEmpty
            ? const Center(
                child: SingleChildScrollView(
                  child: EmptyState(
                    icon: Icons.repeat_rounded,
                    title: 'No recurring transactions',
                    message:
                        'When you add a transaction, choose Repeat to add it '
                        'automatically every week, month or year.',
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(Spacing.lg),
                itemCount: rules.length + 1,
                separatorBuilder: (_, _) => const SizedBox(height: Spacing.sm),
                itemBuilder: (context, i) {
                  if (i == rules.length) {
                    return Padding(
                      padding: const EdgeInsets.only(top: Spacing.sm),
                      child: Text(
                        'Entries are added on this device when they fall due '
                        'and then sync like any other transaction.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  final rule = rules[i];
                  return _RuleCard(
                    rule: rule,
                    paused: rule.isShared && rule.householdId != householdId,
                    onStop: () => _stop(rule),
                  );
                },
              ),
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.paused,
    required this.onStop,
  });

  final RecurringRule rule;

  /// A shared rule whose household is not (yet) known on this device.
  final bool paused;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final category = context.select<CategoryProvider, CategoryModel?>(
      (c) => c.byIdOrNull(rule.categoryId),
    );
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final amountColor = rule.isIncome ? finance.income : finance.expense;
    final title = rule.note.isNotEmpty
        ? rule.note
        : category?.name ?? rule.type.label;
    final next = paused
        ? 'Paused until you rejoin the household'
        : 'Next: ${DateFormat('EEE, d MMM yyyy').format(rule.nextDate)}';

    return Card(
      key: Key('recurringRule-${rule.id}'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.md,
          Spacing.xs,
          Spacing.md,
        ),
        child: Row(
          children: [
            CategoryAvatar(category: category),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${rule.isIncome ? '+' : '-'}'
                    '${formatter.format(rule.amountMinor)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: amountColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(rule.scheduleLabel, style: theme.textTheme.bodySmall),
                  Text(
                    '$next${rule.isShared ? ' · Shared household' : ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: Key('stopRule-${rule.id}'),
              tooltip: 'Stop repeating',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: onStop,
            ),
          ],
        ),
      ),
    );
  }
}
