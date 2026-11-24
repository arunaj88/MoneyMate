import 'package:flutter/material.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:provider/provider.dart';
import 'screens/add_edit_transaction_screen.dart';

/// Opens the add/edit form. Pass [transaction] to edit an existing entry.
Future<void> openTransactionForm(
  BuildContext context, {
  TransactionModel? transaction,
  TransactionType? initialType,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AddEditTransactionScreen(
        transaction: transaction,
        initialType: initialType,
      ),
      fullscreenDialog: true,
    ),
  );
}

/// Asks for confirmation, deletes the transaction and offers undo.
/// Returns true if the transaction was deleted.
Future<bool> confirmAndDeleteTransaction(
  BuildContext context,
  TransactionModel transaction,
) async {
  final confirmed = await showConfirmDialog(
    context,
    title: 'Delete transaction?',
    message:
        'This ${transaction.type.label.toLowerCase()} will be removed '
        'and your balance and budgets will be recalculated.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return false;

  final provider = context.read<TransactionProvider>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    await provider.deleteTransaction(transaction.id);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Transaction deleted'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => provider.restoreTransaction(transaction),
          ),
        ),
      );
    return true;
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        'Could not delete the transaction',
        isError: true,
      );
    }
    return false;
  }
}
