import 'package:intl/intl.dart';

import '../constants/currencies.dart';

/// Helpers for converting between user input, minor units and display text.
///
/// Amounts are persisted as integers in minor units (1/100 of the major
/// currency unit), e.g. AED 12.50 is stored as 1250.
class Money {
  Money._();

  static const int minorPerMajor = 100;

  /// Largest amount accepted from user input (100 million major units).
  static const int maxMinor = 100000000 * minorPerMajor;

  /// Parses user input such as "1,234.5" into minor units.
  ///
  /// Returns null when the text is not a valid non-negative amount with at
  /// most two decimal places. Uses exact string arithmetic (no doubles).
  static int? parseToMinor(String input) {
    final text = input.trim().replaceAll(',', '').replaceAll(' ', '');
    if (text.isEmpty) return null;
    final match = RegExp(r'^(\d+)?(?:\.(\d{0,2}))?$').firstMatch(text);
    if (match == null) return null;
    final wholePart = match.group(1);
    final fractionPart = match.group(2);
    if ((wholePart == null || wholePart.isEmpty) &&
        (fractionPart == null || fractionPart.isEmpty)) {
      return null;
    }
    if (wholePart != null && wholePart.length > 12) return null;
    final whole = int.parse(
      wholePart == null || wholePart.isEmpty ? '0' : wholePart,
    );
    final fraction = (fractionPart ?? '').padRight(2, '0');
    final minor =
        whole * minorPerMajor + int.parse(fraction.isEmpty ? '0' : fraction);
    return minor;
  }

  /// Converts minor units to an editable input string, e.g. 1250 -> "12.50".
  static String toInputString(int minor) {
    final negative = minor < 0;
    final abs = minor.abs();
    final whole = abs ~/ minorPerMajor;
    final fraction = (abs % minorPerMajor).toString().padLeft(2, '0');
    return '${negative ? '-' : ''}$whole.$fraction';
  }

  /// Converts minor units to a double. Only use for charts/percentages,
  /// never for arithmetic that is persisted.
  static double toMajor(int minor) => minor / minorPerMajor;
}

/// Formats minor-unit amounts for display in the selected currency.
class CurrencyFormatter {
  CurrencyFormatter(String currencyCode)
    : currency = Currencies.byCode(currencyCode),
      _full = NumberFormat.currency(
        locale: 'en_US',
        symbol: Currencies.byCode(currencyCode).symbol,
        decimalDigits: 2,
      ),
      _compact = NumberFormat.compactCurrency(
        locale: 'en_US',
        symbol: Currencies.byCode(currencyCode).symbol,
        decimalDigits: 1,
      );

  final CurrencyInfo currency;
  final NumberFormat _full;
  final NumberFormat _compact;

  /// e.g. "AED 1,234.50"
  String format(int minor) => _full.format(Money.toMajor(minor));

  /// e.g. "+AED 50.00" / "-AED 50.00"
  String formatSigned(int minor) {
    if (minor == 0) return format(0);
    return '${minor > 0 ? '+' : '-'}${format(minor.abs())}';
  }

  /// e.g. "AED 1.2K" for chart axes and tight spaces.
  String compact(int minor) {
    if (minor.abs() < 1000 * Money.minorPerMajor) {
      return NumberFormat.currency(
        locale: 'en_US',
        symbol: currency.symbol,
        decimalDigits: 0,
      ).format(Money.toMajor(minor));
    }
    return _compact.format(Money.toMajor(minor));
  }

  /// Short axis label without the currency symbol, e.g. "1.2K".
  static String axis(double major) {
    if (major.abs() < 1000) return major.toStringAsFixed(0);
    return NumberFormat.compact(locale: 'en_US').format(major);
  }
}
