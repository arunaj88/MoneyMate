import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/theme/system_ui.dart';

void main() {
  test('light theme: transparent status bar with dark icons', () {
    final style = SystemUi.overlayFor(Brightness.light);
    expect(style.statusBarColor, Colors.transparent);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.statusBarBrightness, Brightness.light);
    expect(style.systemNavigationBarColor, Colors.transparent);
  });

  test('dark theme: transparent status bar with light icons', () {
    final style = SystemUi.overlayFor(Brightness.dark);
    expect(style.statusBarColor, Colors.transparent);
    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.statusBarBrightness, Brightness.dark);
  });

  test('app bars use the same overlay style as the theme', () {
    expect(
      AppTheme.light().appBarTheme.systemOverlayStyle,
      SystemUi.overlayFor(Brightness.light),
    );
    expect(
      AppTheme.dark().appBarTheme.systemOverlayStyle,
      SystemUi.overlayFor(Brightness.dark),
    );
  });
}
