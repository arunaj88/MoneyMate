import 'package:flutter/material.dart';

/// Closes the on-screen keyboard when the user taps outside a text field.
///
/// The iOS number pad (amount fields) has no Done/Return key, so without
/// this the keyboard could only be closed by leaving the screen. Taps on
/// buttons, fields and other controls still go to those controls: they win
/// the gesture arena, so this only sees taps on empty space.
class DismissKeyboardOnTap extends StatelessWidget {
  const DismissKeyboardOnTap({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: child,
    );
  }
}
