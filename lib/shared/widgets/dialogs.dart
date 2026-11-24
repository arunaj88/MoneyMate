import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/utils/money.dart';

/// Shows a confirmation dialog. Returns true when the user confirms.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      // Every dialog in the app is scrollable: its title and content scroll
      // (the actions stay put) instead of overflowing on a short landscape
      // screen, with a large font, or when the keyboard is open.
      return AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.error,
                    foregroundColor: scheme.onError,
                    minimumSize: const Size(64, 40),
                  )
                : FilledButton.styleFrom(minimumSize: const Size(64, 40)),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Input formatter allowing digits with at most two decimal places.
final List<TextInputFormatter> amountInputFormatters = [
  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
  TextInputFormatter.withFunction((oldValue, newValue) {
    final text = newValue.text.replaceAll(',', '');
    if (text.isEmpty) return newValue;
    return RegExp(r'^\d{0,12}(\.\d{0,2})?$').hasMatch(text)
        ? newValue
        : oldValue;
  }),
];

/// Validator for amount fields. Amounts must be greater than zero.
String? validateAmount(String? value) {
  final minor = Money.parseToMinor(value ?? '');
  if (value == null || value.trim().isEmpty) return 'Please enter an amount';
  if (minor == null) return 'Enter a valid amount (max 2 decimals)';
  if (minor <= 0) return 'Amount must be greater than zero';
  if (minor > Money.maxMinor) return 'Amount is too large';
  return null;
}

/// Asks the user for a money amount. Returns minor units, or null.
Future<int?> showAmountDialog(
  BuildContext context, {
  required String title,
  String? message,
  int? initialMinor,
  required String currencySymbol,
  String confirmLabel = 'Save',
}) {
  return showDialog<int>(
    context: context,
    builder: (context) => _AmountDialog(
      title: title,
      message: message,
      initialMinor: initialMinor,
      currencySymbol: currencySymbol,
      confirmLabel: confirmLabel,
    ),
  );
}

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({
    required this.title,
    required this.message,
    required this.initialMinor,
    required this.currencySymbol,
    required this.confirmLabel,
  });

  final String title;
  final String? message;
  final int? initialMinor;
  final String currencySymbol;
  final String confirmLabel;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialMinor != null
        ? Money.toInputString(widget.initialMinor!)
        : '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(Money.parseToMinor(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.message != null) ...[
              Text(widget.message!),
              const SizedBox(height: 16),
            ],
            TextFormField(
              key: const Key('amountDialogField'),
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: amountInputFormatters,
              decoration: InputDecoration(
                labelText: 'Amount',
                prefixText: '${widget.currencySymbol.trim()} ',
              ),
              validator: validateAmount,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarAction? action,
  bool isError = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      action: action,
      backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
    ),
  );
}
