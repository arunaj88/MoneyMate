import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/features/lending/widgets/lending_widgets.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/label_amount_row.dart';
import 'package:money_mate/shared/widgets/state_views.dart';

/// Every lending record of one borrower, kept separate, with totals.
class BorrowerScreen extends StatelessWidget {
  const BorrowerScreen({super.key, required this.borrowerKey});

  /// `LoanCalculator.borrowerKey` of the borrower's name.
  final String borrowerKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final matches = context
        .watch<LoanProvider>()
        .borrowers(LoanFilter.all)
        .where((b) => b.key == borrowerKey);
    if (matches.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Borrower')),
        body: const EmptyState(
          icon: Icons.person_off_outlined,
          title: 'No lending records for this person',
        ),
      );
    }
    final b = matches.first;
    Widget row(String label, String value, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LabelAmountRow(
        label: Text(label),
        amount: Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w700, color: color),
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(b.name)),
      body: ListView(
        padding: const EdgeInsets.all(Spacing.lg),
        children: [
          AppCard(
            key: const Key('borrowerSummaryCard'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                row('Total lent', formatter.format(b.lentMinor)),
                row('Total received', formatter.format(b.receivedMinor)),
                row('Outstanding', formatter.format(b.outstandingMinor)),
                row(
                  'Overdue',
                  formatter.format(b.overdueMinor),
                  color: b.overdueMinor > 0 ? context.finance.expense : null,
                ),
                row('Active records', '${b.activeCount}'),
                row('Completed records', '${b.completedCount}'),
              ],
            ),
          ),
          const SizedBox(height: Spacing.lg),
          Text(
            'Each loan is tracked separately',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: Spacing.sm),
          for (final s in b.loans) ...[
            LoanTile(snapshot: s, formatter: formatter),
            const SizedBox(height: Spacing.sm),
          ],
        ],
      ),
    );
  }
}
