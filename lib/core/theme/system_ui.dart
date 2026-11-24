import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Status / navigation bar styling.
///
/// The app draws edge-to-edge: both system bars are fully transparent so the
/// screen background shows through them, and only their icon brightness
/// changes with the theme (dark icons on light backgrounds, light icons on
/// dark backgrounds).
class SystemUi {
  SystemUi._();

  /// Overlay style for a theme of the given [brightness].
  static SystemUiOverlayStyle overlayFor(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      // Status bar.
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: iconBrightness, // Android
      statusBarBrightness: brightness, // iOS (describes the background)
      // Navigation bar: transparent so the NavigationBar surface shows
      // through, without the scrim Android adds by default.
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: iconBrightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarContrastEnforced: false,
    );
  }

  /// Enables edge-to-edge drawing. Call once before `runApp`.
  static Future<void> enableEdgeToEdge(Brightness platformBrightness) async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(overlayFor(platformBrightness));
  }
}

/// Applies [SystemUi.overlayFor] for the current theme to every screen.
///
/// Placed in `MaterialApp.builder`, so it sits above all routes. Screens with
/// an [AppBar] get the same style from `AppBarTheme.systemOverlayStyle`.
class SystemUiOverlay extends StatelessWidget {
  const SystemUiOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUi.overlayFor(Theme.of(context).brightness),
      child: child,
    );
  }
}
