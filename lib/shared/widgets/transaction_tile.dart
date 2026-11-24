import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/money.dart';
import '../../models/category_model.dart';
import '../../models/transaction_model.dart';
import 'category_avatar.dart';

/// One row in a transaction list.
class TransactionTile extends StatelessWidget {
  const TransactionTile({
    super.key,
    required this.transaction,
    required this.category,
    required this.formatter,
    this.onTap,
    this.showDate = false,
    this.trailing,
    this.sharedLabel,
  });

  final TransactionModel transaction;
  final CategoryModel? category;
  final CurrencyFormatter formatter;
  final VoidCallback? onTap;
  final bool showDate;
  final Widget? trailing;

  /// For shared household transactions, e.g. "Shared · Sara".
  final String? sharedLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final finance = context.finance;
    final isIncome = transaction.isIncome;
    final amountColor = isIncome ? finance.income : finance.expense;
    final subtitleParts = <String>[
      if (showDate) DateFormat('d MMM').format(transaction.date),
      transaction.paymentMethod.label,
      if (transaction.note.isNotEmpty) transaction.note,
    ];

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Spacing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Spacing.sm,
          vertical: Spacing.sm + 2,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CategoryAvatar(category: category),
                  Positioned(
                    right: -3,
                    bottom: -3,
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(1.5),
                      child: Icon(
                        isIncome
                            ? Icons.arrow_circle_down_rounded
                            : Icons.arrow_circle_up_rounded,
                        size: 16,
                        color: amountColor,
                        semanticLabel: isIncome ? 'Income' : 'Expense',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      category?.name ?? 'Unknown category',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitleParts.join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (sharedLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(
                              Icons.group_rounded,
                              size: 13,
                              color: theme.colorScheme.tertiary,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                sharedLabel!,
                                key: ValueKey('shared-${transaction.id}'),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.tertiary,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: Spacing.sm),
              // A very large amount (or a large system font) shrinks to fit 40%
              // of the row instead of pushing the row past the screen edge.
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * 0.4,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    formatter.formatSigned(transaction.signedAmountMinor),
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: amountColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }
}
