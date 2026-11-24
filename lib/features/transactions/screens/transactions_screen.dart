import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';
import 'package:money_mate/shared/widgets/state_views.dart';
import 'package:money_mate/shared/widgets/transaction_tile.dart';
import 'package:money_mate/features/household/widgets/household_widgets.dart';
import 'package:money_mate/features/transactions/transaction_actions.dart';
import 'package:money_mate/features/transactions/widgets/transaction_filter_bar.dart';

/// Transaction history grouped by date with search and filters.
class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      // The search and filter header never takes more than half the height.
      // On a short screen (landscape, keyboard open, large font) it scrolls
      // on its own instead of overflowing, and the list keeps the rest.
      body: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: constraints.maxHeight / 2),
              child: const SingleChildScrollView(
                child: Column(
                  children: [
                    ViewScopeSelector(
                      padding: EdgeInsets.fromLTRB(
                        Spacing.lg,
                        Spacing.xs,
                        Spacing.lg,
                        Spacing.xs,
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        Spacing.lg,
                        Spacing.xs,
                        Spacing.lg,
                        Spacing.sm,
                      ),
                      child: TransactionSearchField(),
                    ),
                    TransactionFilterBar(),
                    SizedBox(height: Spacing.sm),
                    _FilteredSummary(),
                  ],
                ),
              ),
            ),
            const Expanded(child: _TransactionList()),
          ],
        ),
      ),
    );
  }
}

class _FilteredSummary extends StatelessWidget {
  const _FilteredSummary();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransactionProvider>();
    if (provider.transactions.isEmpty) return const SizedBox.shrink();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final finance = context.finance;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${provider.transactions.length} '
              '${provider.transactions.length == 1 ? 'transaction' : 'transactions'}',
              style: theme.textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _Amount(
            '+${formatter.format(provider.filteredIncomeMinor)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: finance.income,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: Spacing.md),
          _Amount(
            '-${formatter.format(provider.filteredExpenseMinor)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: finance.expense,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Amount text that shrinks instead of overflowing on narrow screens.
class _Amount extends StatelessWidget {
  const _Amount(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Flexible(
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, style: style),
    ),
  );
}

class _TransactionList extends StatelessWidget {
  const _TransactionList();

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransactionProvider>();
    final categories = context.watch<CategoryProvider>().byId;
    final formatter = context.watch<SettingsProvider>().formatter;
    final household = context.watch<HouseholdProvider>();

    if (!provider.hasLoaded && provider.isLoading) return const LoadingView();
    if (provider.error != null && provider.transactions.isEmpty) {
      return Center(
        child: ErrorState(message: provider.error!, onRetry: provider.load),
      );
    }
    if (provider.transactions.isEmpty) {
      final empty = provider.filter.isEmpty
          ? EmptyState(
              icon: Icons.receipt_long_rounded,
              title: 'No transactions yet',
              message: 'Add your first income or expense to start tracking.',
              actionLabel: 'Add transaction',
              onAction: () => openTransactionForm(context),
            )
          : EmptyState(
              icon: Icons.search_off_rounded,
              title: 'No matching transactions',
              message: 'Try a different search or clear the filters.',
            );
      return SingleChildScrollView(
        child: Column(
          children: [
            empty,
            if (provider.canLoadCloudHistory) const CloudHistoryFooter(),
          ],
        ),
      );
    }

    final groups = provider.groupedByDay;
    return RefreshIndicator(
      onRefresh: provider.load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          for (final group in groups) ...[
            SliverToBoxAdapter(
              child: _DayHeader(
                day: group.key,
                netMinor: group.value.fold<int>(
                  0,
                  (s, t) => s + t.signedAmountMinor,
                ),
                formatter: formatter,
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
              sliver: SliverToBoxAdapter(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
                    child: Column(
                      children: [
                        for (final t in group.value)
                          _DismissibleTransaction(
                            key: ValueKey(t.id),
                            transaction: t,
                            child: TransactionTile(
                              transaction: t,
                              category: categories[t.categoryId],
                              formatter: formatter,
                              sharedLabel: sharedLabelFor(household, t),
                              onTap: () =>
                                  openTransactionForm(context, transaction: t),
                              trailing: provider.isCloudOnly(t.id)
                                  ? Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Tooltip(
                                          message: 'Stored in the cloud',
                                          child: Icon(
                                            Icons.cloud_outlined,
                                            key: ValueKey('cloud-${t.id}'),
                                            size: 16,
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                        _TileMenu(transaction: t),
                                      ],
                                    )
                                  : _TileMenu(transaction: t),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (provider.canLoadCloudHistory)
            const SliverToBoxAdapter(child: CloudHistoryFooter()),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }
}

/// Loads transactions older than the on-device retention window from the
/// cloud, and explains why it cannot when offline.
class CloudHistoryFooter extends StatelessWidget {
  const CloudHistoryFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<TransactionProvider>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final Widget content;
    switch (provider.historyStatus) {
      case CloudHistoryStatus.loading:
        content = const SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        );
      case CloudHistoryStatus.exhausted:
        content = Text(
          'No older transactions in the cloud',
          style: muted,
          textAlign: TextAlign.center,
        );
      case CloudHistoryStatus.offline:
      case CloudHistoryStatus.error:
        content = Column(
          children: [
            Text(
              provider.historyMessage ?? '',
              style: muted,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Spacing.sm),
            TextButton.icon(
              onPressed: provider.loadCloudHistory,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try again'),
            ),
          ],
        );
      case CloudHistoryStatus.idle:
      case CloudHistoryStatus.loaded:
        content = Column(
          children: [
            OutlinedButton.icon(
              key: const Key('loadCloudHistory'),
              onPressed: provider.loadCloudHistory,
              icon: const Icon(Icons.cloud_download_outlined),
              label: Text(
                provider.historyStatus == CloudHistoryStatus.idle
                    ? 'Load older transactions'
                    : 'Load more',
              ),
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'Older history is kept safely in the cloud',
              style: muted,
              textAlign: TextAlign.center,
            ),
          ],
        );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Spacing.lg, Spacing.lg, Spacing.lg, 0),
      child: Center(child: content),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.day,
    required this.netMinor,
    required this.formatter,
  });

  final DateTime day;
  final int netMinor;
  final CurrencyFormatter formatter;

  String _label() {
    final today = PeriodUtils.dateOnly(DateTime.now());
    if (PeriodUtils.isSameDay(day, today)) return 'Today';
    if (PeriodUtils.isSameDay(
      day,
      DateTime(today.year, today.month, today.day - 1),
    )) {
      return 'Yesterday';
    }
    return DateFormat(
      day.year == today.year ? 'EEEE, d MMM' : 'd MMM yyyy',
    ).format(day);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg + Spacing.xs,
        Spacing.lg,
        Spacing.lg + Spacing.xs,
        Spacing.sm,
      ),
      child: LabelAmountRow(
        label: Text(
          _label(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        amount: Text(
          formatter.formatSigned(netMinor),
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _DismissibleTransaction extends StatelessWidget {
  const _DismissibleTransaction({
    super.key,
    required this.transaction,
    required this.child,
  });

  final TransactionModel transaction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Dismissible(
      key: ValueKey('dismiss-${transaction.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: Spacing.xl),
        color: color.withValues(alpha: 0.12),
        child: Icon(Icons.delete_outline_rounded, color: color),
      ),
      // The provider removes the row itself once deletion succeeds, so the
      // Dismissible never removes it optimistically.
      confirmDismiss: (_) async {
        await confirmAndDeleteTransaction(context, transaction);
        return false;
      },
      child: child,
    );
  }
}

class _TileMenu extends StatelessWidget {
  const _TileMenu({required this.transaction});

  final TransactionModel transaction;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert_rounded, size: 20),
      onSelected: (value) {
        if (value == 'edit') {
          openTransactionForm(context, transaction: transaction);
        } else if (value == 'delete') {
          confirmAndDeleteTransaction(context, transaction);
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('Edit'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline_rounded),
            title: Text('Delete'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}
