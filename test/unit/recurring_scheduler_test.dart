import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/recurring_scheduler.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/models/transaction_model.dart';

RecurringRule rule({
  required RecurrenceFrequency frequency,
  required DateTime start,
  int nextIndex = 0,
  String id = 'rule-1',
}) => RecurringRule(
  id: id,
  type: TransactionType.income,
  amountMinor: 1000000,
  categoryId: 'inc_salary',
  frequency: frequency,
  startDate: start,
  note: 'Salary',
  nextIndex: nextIndex,
  createdAt: start,
  updatedAt: start,
);

void main() {
  group('occurrence dates', () {
    test('monthly keeps the day and time of the start date', () {
      final r = rule(
        frequency: RecurrenceFrequency.monthly,
        start: DateTime(2026, 3, 1, 9, 30),
      );
      expect(r.occurrenceDate(0), DateTime(2026, 3, 1, 9, 30));
      expect(r.occurrenceDate(1), DateTime(2026, 4, 1, 9, 30));
      expect(r.occurrenceDate(10), DateTime(2027, 1, 1, 9, 30));
    });

    test('monthly on the 31st uses the last day of shorter months', () {
      final r = rule(
        frequency: RecurrenceFrequency.monthly,
        start: DateTime(2026, 1, 31),
      );
      expect(r.occurrenceDate(1), DateTime(2026, 2, 28));
      expect(r.occurrenceDate(2), DateTime(2026, 3, 31));
      expect(r.occurrenceDate(3), DateTime(2026, 4, 30));
      // Leap year February.
      expect(r.occurrenceDate(25), DateTime(2028, 2, 29));
    });

    test('weekly adds seven calendar days', () {
      final r = rule(
        frequency: RecurrenceFrequency.weekly,
        start: DateTime(2026, 10, 19, 8),
      );
      expect(r.occurrenceDate(1), DateTime(2026, 10, 26, 8));
      expect(r.occurrenceDate(2), DateTime(2026, 11, 2, 8));
    });

    test('yearly on 29 February falls on the 28th in other years', () {
      final r = rule(
        frequency: RecurrenceFrequency.yearly,
        start: DateTime(2028, 2, 29),
      );
      expect(r.occurrenceDate(1), DateTime(2029, 2, 28));
      expect(r.occurrenceDate(4), DateTime(2032, 2, 29));
    });

    test('describes the schedule', () {
      expect(
        RecurringRule.describe(RecurrenceFrequency.monthly, DateTime(2026, 3)),
        'Every month on the 1st',
      );
      expect(
        RecurringRule.describe(
          RecurrenceFrequency.monthly,
          DateTime(2026, 3, 31),
        ),
        'Every month on the 31st (or the last day)',
      );
      expect(
        RecurringRule.describe(
          RecurrenceFrequency.weekly,
          DateTime(2026, 11, 23),
        ),
        'Every week on Monday',
      );
      expect(RecurringRule.ordinal(12), '12th');
      expect(RecurringRule.ordinal(22), '22nd');
    });
  });

  group('due occurrences', () {
    test('the first occurrence is due at once, even in the future', () {
      final r = rule(
        frequency: RecurrenceFrequency.monthly,
        start: DateTime(2026, 12, 1),
      );
      final due = RecurringScheduler.due(r, DateTime(2026, 11, 24));
      expect(due.transactions.map((t) => t.date), [DateTime(2026, 12, 1)]);
      expect(due.nextIndex, 1);
    });

    test('a past start date catches up to today, inclusive', () {
      final r = rule(
        frequency: RecurrenceFrequency.monthly,
        start: DateTime(2026, 3, 1, 9),
      );
      final due = RecurringScheduler.due(r, DateTime(2026, 11, 1, 6));
      expect(due.transactions, hasLength(9)); // March to November.
      expect(due.transactions.last.date, DateTime(2026, 11, 1, 9));
      expect(due.nextIndex, 9);
      final t = due.transactions.first;
      expect(t.type, TransactionType.income);
      expect(t.amountMinor, 1000000);
      expect(t.note, 'Salary');
      expect(t.isPersonal, isTrue);
    });

    test('nothing is due before the next occurrence day', () {
      final r = rule(
        frequency: RecurrenceFrequency.monthly,
        start: DateTime(2026, 3, 1),
        nextIndex: 9,
      );
      expect(RecurringScheduler.due(r, DateTime(2026, 11, 30)).isEmpty, isTrue);
      expect(
        RecurringScheduler.due(r, DateTime(2026, 12, 1)).transactions,
        hasLength(1),
      );
    });

    test('occurrence IDs are stable and unique per rule and index', () {
      final a = RecurringScheduler.occurrenceId('rule-1', 3);
      expect(RecurringScheduler.occurrenceId('rule-1', 3), a);
      expect(RecurringScheduler.occurrenceId('rule-1', 4), isNot(a));
      expect(RecurringScheduler.occurrenceId('rule-2', 3), isNot(a));
    });

    test('one run adds at most maxPerRun occurrences', () {
      final r = rule(
        frequency: RecurrenceFrequency.weekly,
        start: DateTime(2000, 1, 3),
      );
      final due = RecurringScheduler.due(r, DateTime(2026, 11, 24));
      expect(due.transactions, hasLength(RecurringScheduler.maxPerRun));
      expect(due.nextIndex, RecurringScheduler.maxPerRun);
    });

    test('a shared rule creates shared transactions with its author', () {
      final shared = RecurringRule(
        id: 'r',
        type: TransactionType.expense,
        amountMinor: 500000,
        categoryId: 'exp_rent',
        frequency: RecurrenceFrequency.monthly,
        startDate: DateTime(2026, 11, 1),
        scope: TransactionScope.shared,
        householdId: 'h1',
        createdAt: DateTime(2026, 11, 1),
        updatedAt: DateTime(2026, 11, 1),
        createdBy: 'uid-1',
        createdByName: 'Sam',
      );
      final t = RecurringScheduler.due(
        shared,
        DateTime(2026, 11, 2),
      ).transactions.single;
      expect(t.isShared, isTrue);
      expect(t.householdId, 'h1');
      expect(t.createdBy, 'uid-1');
      expect(t.createdByName, 'Sam');
    });
  });

  test('round-trips through its database map', () {
    final r = rule(
      frequency: RecurrenceFrequency.yearly,
      start: DateTime(2026, 5, 6, 7),
      nextIndex: 2,
    );
    final back = RecurringRule.fromMap(r.toMap());
    expect(back.toMap(), r.toMap());
  });
}
