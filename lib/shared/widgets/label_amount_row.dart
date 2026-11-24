import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

/// A label on the left and an amount on the right, for list and card rows.
///
/// The amount is never cut off: it may take up to [maxAmountFraction] of the
/// row and scales down beyond that (huge amounts, narrow phones, large system
/// fonts). The label takes the remaining width.
class LabelAmountRow extends StatelessWidget {
  const LabelAmountRow({
    super.key,
    required this.label,
    required this.amount,
    this.maxAmountFraction = 0.6,
    this.gap = Spacing.sm,
  });

  final Widget label;
  final Widget amount;
  final double maxAmountFraction;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        children: [
          Expanded(child: label),
          SizedBox(width: gap),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth * maxAmountFraction,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: amount,
            ),
          ),
        ],
      ),
    );
  }
}
