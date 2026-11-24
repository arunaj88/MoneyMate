import 'package:flutter/material.dart';

import 'system_ui.dart';

/// Brand and semantic colours.
class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF0F766E); // deep teal
  static const Color primaryDark = Color(0xFF2DD4BF);
  static const Color income = Color(0xFF16A34A);
  static const Color incomeDark = Color(0xFF4ADE80);
  static const Color expense = Color(0xFFDC2626);
  static const Color expenseDark = Color(0xFFF87171);
  static const Color warning = Color(0xFFF59E0B);
  static const Color caution = Color(0xFFEAB308);

  static const Color lightBackground = Color(0xFFF5F7FA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color darkBackground = Color(0xFF0B1120);
  static const Color darkSurface = Color(0xFF151C2C);
}

/// Semantic colours that differ between light and dark themes.
@immutable
class FinanceColors extends ThemeExtension<FinanceColors> {
  const FinanceColors({
    required this.income,
    required this.expense,
    required this.warning,
    required this.caution,
    required this.balanceGradient,
  });

  final Color income;
  final Color expense;
  final Color warning;
  final Color caution;
  final List<Color> balanceGradient;

  static const light = FinanceColors(
    income: AppColors.income,
    expense: AppColors.expense,
    warning: AppColors.warning,
    caution: AppColors.caution,
    balanceGradient: [Color(0xFF0F766E), Color(0xFF115E59), Color(0xFF134E4A)],
  );

  static const dark = FinanceColors(
    income: AppColors.incomeDark,
    expense: AppColors.expenseDark,
    warning: AppColors.warning,
    caution: AppColors.caution,
    balanceGradient: [Color(0xFF0F766E), Color(0xFF0E5550), Color(0xFF0B3B39)],
  );

  @override
  FinanceColors copyWith({
    Color? income,
    Color? expense,
    Color? warning,
    Color? caution,
    List<Color>? balanceGradient,
  }) => FinanceColors(
    income: income ?? this.income,
    expense: expense ?? this.expense,
    warning: warning ?? this.warning,
    caution: caution ?? this.caution,
    balanceGradient: balanceGradient ?? this.balanceGradient,
  );

  @override
  FinanceColors lerp(FinanceColors? other, double t) {
    if (other == null) return this;
    return FinanceColors(
      income: Color.lerp(income, other.income, t)!,
      expense: Color.lerp(expense, other.expense, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      caution: Color.lerp(caution, other.caution, t)!,
      balanceGradient: t < 0.5 ? balanceGradient : other.balanceGradient,
    );
  }
}

extension FinanceColorsX on BuildContext {
  FinanceColors get finance =>
      Theme.of(this).extension<FinanceColors>() ?? FinanceColors.light;
}

/// Spacing scale used across the app.
class Spacing {
  Spacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  static const double radius = 20;
  static const double radiusSm = 12;
}

class AppTheme {
  AppTheme._();

  static ThemeData light() => _build(
    brightness: Brightness.light,
    seed: AppColors.primary,
    background: AppColors.lightBackground,
    surface: AppColors.lightSurface,
    finance: FinanceColors.light,
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    seed: AppColors.primary,
    background: AppColors.darkBackground,
    surface: AppColors.darkSurface,
    finance: FinanceColors.dark,
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color seed,
    required Color background,
    required Color surface,
    required FinanceColors finance,
  }) {
    final isDark = brightness == Brightness.dark;
    var scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness)
        .copyWith(
          primary: isDark ? AppColors.primaryDark : AppColors.primary,
          surface: surface,
          error: finance.expense,
        );
    if (isDark) {
      scheme = scheme.copyWith(
        onPrimary: const Color(0xFF042F2E),
        surfaceContainerLowest: const Color(0xFF0F1626),
        surfaceContainerLow: const Color(0xFF131A2A),
        surfaceContainer: const Color(0xFF1A2235),
        surfaceContainerHigh: const Color(0xFF212A3F),
        surfaceContainerHighest: const Color(0xFF283249),
      );
    }

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: background,
      extensions: [finance],
    );

    final textTheme = base.textTheme.apply(
      bodyColor: scheme.onSurface,
      displayColor: scheme.onSurface,
    );

    return base.copyWith(
      textTheme: textTheme.copyWith(
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        titleLarge: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        labelLarge: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        // Transparent status bar over the app bar, icons matching the theme.
        systemOverlayStyle: SystemUi.overlayFor(brightness),
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          fontSize: 22,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Spacing.radius),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: isDark ? 0.25 : 0.5),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.15),
        elevation: 2,
        height: 68,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Spacing.radiusSm),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Spacing.radiusSm),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Spacing.radiusSm),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Spacing.radiusSm),
          borderSide: BorderSide(color: scheme.error, width: 1.2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Spacing.radiusSm),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 46),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Spacing.radiusSm),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
        space: 1,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
