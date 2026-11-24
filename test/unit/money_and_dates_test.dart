import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';

void main() {
  group('Money.parseToMinor', () {
    test('parses whole and decimal amounts exactly', () {
      expect(Money.parseToMinor('12'), 1200);
      expect(Money.parseToMinor('12.5'), 1250);
      expect(Money.parseToMinor('12.50'), 1250);
      expect(Money.parseToMinor('0.1'), 10);
      expect(Money.parseToMinor('.75'), 75);
      expect(Money.parseToMinor('1,234.56'), 123456);
      expect(Money.parseToMinor(' 7 '), 700);
    });

    test('rejects invalid input', () {
      expect(Money.parseToMinor(''), isNull);
      expect(Money.parseToMinor('.'), isNull);
      expect(Money.parseToMinor('abc'), isNull);
      expect(Money.parseToMinor('1.234'), isNull);
      expect(Money.parseToMinor('-5'), isNull);
      expect(Money.parseToMinor('1.2.3'), isNull);
    });

    test('zero parses to zero (validation rejects it separately)', () {
      expect(Money.parseToMinor('0'), 0);
      expect(Money.parseToMinor('0.00'), 0);
    });

    test('round-trips through toInputString', () {
      for (final minor in [0, 5, 99, 100, 1250, 123456]) {
        expect(Money.parseToMinor(Money.toInputString(minor)), minor);
      }
    });
  });

  group('CurrencyFormatter', () {
    test('formats AED', () {
      final f = CurrencyFormatter('AED');
      expect(f.format(123450), 'AED 1,234.50');
      expect(f.formatSigned(-5000), '-AED 50.00');
      expect(f.formatSigned(5000), '+AED 50.00');
    });

    test('unknown currency falls back to default', () {
      expect(CurrencyFormatter('XYZ').currency.code, 'AED');
    });
  });

  group('PeriodUtils weeks (Monday–Sunday by default)', () {
    test('any day maps to its Monday', () {
      // 23 Nov 2026 is a Monday.
      for (var d = 23; d <= 29; d++) {
        expect(
          PeriodUtils.startOfWeek(DateTime(2026, 11, d, 15)),
          DateTime(2026, 11, 23),
        );
      }
      expect(
        PeriodUtils.startOfWeek(DateTime(2026, 11, 30)),
        DateTime(2026, 11, 30),
      );
    });

    test('week range is half-open and 7 days long', () {
      final w = PeriodUtils.weekRange(DateTime(2026, 11, 25));
      expect(w.start, DateTime(2026, 11, 23));
      expect(w.end, DateTime(2026, 11, 30));
      expect(w.contains(DateTime(2026, 11, 29, 23, 59)), isTrue);
      expect(w.contains(DateTime(2026, 11, 30)), isFalse);
      expect(w.dayCount, 7);
    });

    test('custom first day of week (Sunday)', () {
      expect(
        PeriodUtils.startOfWeek(
          DateTime(2026, 11, 25),
          firstWeekday: DateTime.sunday,
        ),
        DateTime(2026, 11, 22),
      );
    });

    test('weeks spanning a month / year boundary', () {
      final w = PeriodUtils.weekRange(DateTime(2027, 1, 1));
      expect(w.start, DateTime(2026, 12, 28));
      expect(w.end, DateTime(2027, 1, 4));
    });

    test('lastWeeks returns oldest first, ending with current week', () {
      final weeks = PeriodUtils.lastWeeks(DateTime(2026, 11, 25), 3);
      expect(weeks.map((w) => w.start), [
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 16),
        DateTime(2026, 11, 23),
      ]);
    });
  });

  group('PeriodUtils months', () {
    test('calendar month range', () {
      final m = PeriodUtils.monthRange(DateTime(2026, 2, 14));
      expect(m.start, DateTime(2026, 2));
      expect(m.end, DateTime(2026, 3));
      expect(m.dayCount, 28);
    });

    test('lastMonths crosses year boundary', () {
      final months = PeriodUtils.lastMonths(DateTime(2026, 2, 10), 3);
      expect(months.map((m) => m.start), [
        DateTime(2025, 12),
        DateTime(2026, 1),
        DateTime(2026, 2),
      ]);
    });

    test('daysIn lists each day', () {
      final days = PeriodUtils.daysIn(
        PeriodUtils.monthRange(DateTime(2026, 11)),
      );
      expect(days.length, 30);
      expect(days.first, DateTime(2026, 11, 1));
      expect(days.last, DateTime(2026, 11, 30));
    });
  });
}
