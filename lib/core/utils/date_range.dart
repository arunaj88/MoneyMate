import 'package:intl/intl.dart';

/// A half-open range of local dates: [start] inclusive, [end] exclusive.
class DateRange {
  DateRange(this.start, this.end)
    : assert(!end.isBefore(start), 'end must not be before start');

  final DateTime start;
  final DateTime end;

  bool contains(DateTime date) => !date.isBefore(start) && date.isBefore(end);

  /// Number of calendar days covered by the range.
  int get dayCount => PeriodUtils.daysBetween(start, end);

  /// Last day included in the range (end - 1 day).
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'DateRange($start – $end)';
}

/// Calendar helpers for weekly and monthly periods.
///
/// All calculations use local calendar dates and `DateTime(y, m, d + n)`
/// arithmetic so they stay correct across daylight saving changes.
class PeriodUtils {
  PeriodUtils._();

  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Start of the week containing [date]. [firstWeekday] uses
  /// [DateTime.monday] (1) … [DateTime.sunday] (7). Defaults to Monday.
  static DateTime startOfWeek(
    DateTime date, {
    int firstWeekday = DateTime.monday,
  }) {
    final diff = (date.weekday - firstWeekday + 7) % 7;
    return DateTime(date.year, date.month, date.day - diff);
  }

  static DateRange weekRange(
    DateTime date, {
    int firstWeekday = DateTime.monday,
  }) {
    final start = startOfWeek(date, firstWeekday: firstWeekday);
    return DateRange(start, DateTime(start.year, start.month, start.day + 7));
  }

  static DateTime startOfMonth(DateTime date) =>
      DateTime(date.year, date.month);

  static DateRange monthRange(DateTime date) => DateRange(
    DateTime(date.year, date.month),
    DateTime(date.year, date.month + 1),
  );

  static DateRange dayRange(DateTime date) =>
      DateRange(dateOnly(date), DateTime(date.year, date.month, date.day + 1));

  static DateRange yearRange(DateTime date) =>
      DateRange(DateTime(date.year), DateTime(date.year + 1));

  /// The [count] most recent weeks ending with the week containing [date],
  /// oldest first.
  static List<DateRange> lastWeeks(
    DateTime date,
    int count, {
    int firstWeekday = DateTime.monday,
  }) {
    final current = startOfWeek(date, firstWeekday: firstWeekday);
    return List.generate(count, (i) {
      final offset = (count - 1 - i) * 7;
      final start = DateTime(current.year, current.month, current.day - offset);
      return DateRange(start, DateTime(start.year, start.month, start.day + 7));
    });
  }

  /// The [count] most recent months ending with the month containing [date],
  /// oldest first.
  static List<DateRange> lastMonths(DateTime date, int count) {
    return List.generate(count, (i) {
      final offset = count - 1 - i;
      final start = DateTime(date.year, date.month - offset);
      return DateRange(start, DateTime(start.year, start.month + 1));
    });
  }

  /// Every day in [range], in order.
  static List<DateTime> daysIn(DateRange range) {
    final days = <DateTime>[];
    var d = dateOnly(range.start);
    while (d.isBefore(range.end)) {
      days.add(d);
      d = DateTime(d.year, d.month, d.day + 1);
    }
    return days;
  }

  /// Calendar days from [a] to [b] (ignores time-of-day and DST).
  static int daysBetween(DateTime a, DateTime b) {
    final ua = DateTime.utc(a.year, a.month, a.day);
    final ub = DateTime.utc(b.year, b.month, b.day);
    return ub.difference(ua).inDays;
  }

  static bool isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  static String weekLabel(DateRange week) {
    final f = DateFormat('d MMM');
    return '${f.format(week.start)} – ${f.format(week.lastDay)}';
  }

  static String monthLabel(DateRange month) =>
      DateFormat('MMMM yyyy').format(month.start);

  static String shortMonthLabel(DateTime date) =>
      DateFormat('MMM').format(date);

  static String weekdayName(int weekday) =>
      DateFormat('EEEE').format(DateTime(2024, 1, weekday)); // 1 Jan 2024 = Mon
}
