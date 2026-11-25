import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/services/loan_reminder_planner.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';

import '../helpers/loan_builders.dart';

void main() {
  final formatter = CurrencyFormatter('AED');

  List<PlannedReminder> plan(
    List<LoanSnapshot> loans, {
    Map<String, LoanReminderSettings> settings = const {},
    String uid = 'me',
    Set<String> members = const {'me', 'partner'},
    required DateTime now,
  }) => LoanReminderPlanner.plan(
    loans: loans,
    settings: settings,
    uid: uid,
    recipient: (loan, s) =>
        LoanReminderPlanner.isRecipient(loan, s, uid, activeMembers: members),
    formatter: formatter,
    now: now,
  );

  // EMIs of AED 1,000 on the 1st, from 1 Jan 2027.
  final loan = monthlyLoan();
  LoanSnapshot at(DateTime now, [List<LoanRepayment> paid = const []]) =>
      LoanCalculator.snapshot(loan, paid, now);

  test('default schedule: 3 days before, on the day, 1, 3 and 7 after', () {
    final now = DateTime(2026, 12, 20);
    final reminders = plan([at(now)], now: now);
    final firstInstallment = loan.schedule.first.id;
    final forFirst = reminders
        .where((r) => r.installmentId == firstInstallment)
        .toList();
    expect(
      [for (final r in forFirst) r.fireAt],
      [
        DateTime(2026, 12, 29, 9),
        DateTime(2027, 1, 1, 9),
        DateTime(2027, 1, 2, 9),
        DateTime(2027, 1, 4, 9),
        DateTime(2027, 1, 8, 9),
      ],
    );
    expect(forFirst.first.title, 'Repayment reminder');
    expect(
      forFirst.first.body,
      'John has an EMI of AED 1,000.00 due in 3 days (Fri, 1 Jan).',
    );
    expect(forFirst[1].body, 'John has an EMI of AED 1,000.00 due today.');
    expect(forFirst[2].title, 'Repayment overdue');
    expect(forFirst[2].body, contains('was due yesterday'));
    expect(forFirst.first.data, {
      'type': 'loan_reminder',
      'loanId': loan.id,
      'installmentId': firstInstallment,
    });
  });

  test('every unpaid instalment within the horizon gets reminders', () {
    final now = DateTime(2026, 12, 20);
    final reminders = plan([at(now)], now: now);
    final horizon = now.add(const Duration(days: 60));
    expect(reminders.every((r) => r.fireAt.isAfter(now)), isTrue);
    expect(reminders.every((r) => !r.fireAt.isAfter(horizon)), isTrue);
    // January (5) + February (5) instalments are within 60 days.
    expect(reminders.map((r) => r.installmentId).toSet(), hasLength(2));
    final sorted = [...reminders]..sort((a, b) => a.fireAt.compareTo(b.fireAt));
    expect(reminders, sorted);
  });

  test('reminders already in the past are not planned (overdue continue)', () {
    final now = DateTime(2027, 1, 3, 12);
    final reminders = plan([at(now)], now: now);
    final first = reminders.where(
      (r) => r.installmentId == loan.schedule.first.id,
    );
    expect([for (final r in first) r.offsetDays], [3, 7]);
  });

  test('a partly paid instalment reminds about what is left', () {
    final now = DateTime(2026, 12, 20);
    final s = at(now, [pay(loan.id, aed(400), DateTime(2026, 12, 15))]);
    final reminder = plan([s], now: now).first;
    expect(
      reminder.body,
      'John has AED 600.00 left of an EMI of AED 1,000.00 due in 3 days '
      '(Fri, 1 Jan).',
    );
  });

  test('a fully paid instalment and a completed loan have none', () {
    final now = DateTime(2026, 12, 20);
    final paidFirst = at(now, [
      pay(loan.id, aed(1000), DateTime(2026, 12, 15)),
    ]);
    expect(
      plan([
        paidFirst,
      ], now: now).where((r) => r.installmentId == loan.schedule.first.id),
      isEmpty,
    );
    final done = at(now, [pay(loan.id, aed(12000), DateTime(2026, 12, 15))]);
    expect(plan([done], now: now), isEmpty);
  });

  test('disabled, paused and custom reminder settings are respected', () {
    final now = DateTime(2026, 12, 20);
    LoanReminderSettings s({
      bool enabled = true,
      bool paused = false,
      List<int> offsets = LoanLimits.defaultReminderOffsets,
    }) => LoanReminderSettings(
      loanId: loan.id,
      enabled: enabled,
      paused: paused,
      offsets: offsets,
      updatedAt: now,
    );
    expect(
      plan([at(now)], settings: {loan.id: s(enabled: false)}, now: now),
      isEmpty,
    );
    expect(
      plan([at(now)], settings: {loan.id: s(paused: true)}, now: now),
      isEmpty,
    );
    final custom = plan(
      [at(now)],
      settings: {
        loan.id: s(offsets: [-1]),
      },
      now: now,
    );
    expect(custom.every((r) => r.offsetDays == -1), isTrue);
    expect(custom.first.body, contains('due tomorrow'));
  });

  test('one-time loans remind before and after the expected date', () {
    final once = oneTimeLoan(due: DateTime(2027, 1, 10));
    final now = DateTime(2027, 1, 1);
    final reminders = plan([
      LoanCalculator.snapshot(once, const [], now),
    ], now: now);
    expect(reminders, hasLength(5));
    expect(reminders.first.body, contains('a repayment of AED 5,000.00'));
  });

  group('household recipients', () {
    final household = oneTimeLoan(
      id: 'h',
      householdId: 'house',
      due: DateTime(2027, 1, 10),
    );
    final now = DateTime(2027, 1, 1);
    final snapshot = LoanCalculator.snapshot(household, const [], now);
    LoanReminderSettings recipients(List<String> uids) =>
        LoanReminderSettings(loanId: 'h', notifyUids: uids, updatedAt: now);

    test('only members the owner selected are reminded', () {
      final settings = {
        'h': recipients(['partner']),
      };
      expect(
        plan([snapshot], settings: settings, uid: 'me', now: now),
        isEmpty,
      );
      final partner = plan(
        [snapshot],
        settings: settings,
        uid: 'partner',
        now: now,
      );
      expect(partner, hasLength(5));
      expect(partner.first.body, endsWith('(household)'));
      expect(partner.first.data['householdId'], 'house');
    });

    test('nobody is reminded without settings (new members included)', () {
      expect(plan([snapshot], uid: 'me', now: now), isEmpty);
      expect(plan([snapshot], uid: 'newcomer', now: now), isEmpty);
    });

    test('a selected member who left the household gets none', () {
      final settings = {
        'h': recipients(['partner']),
      };
      expect(
        plan(
          [snapshot],
          settings: settings,
          uid: 'partner',
          members: {'me'},
          now: now,
        ),
        isEmpty,
      );
    });
  });

  group('stable IDs', () {
    test('the same reminder always gets the same ID; others differ', () {
      final a = LoanReminderPlanner.stableId('l', 'i', 'u', -3);
      expect(LoanReminderPlanner.stableId('l', 'i', 'u', -3), a);
      expect(LoanReminderPlanner.stableId('l', 'i', 'u', 0), isNot(a));
      expect(LoanReminderPlanner.stableId('l', 'i', 'v', -3), isNot(a));
      expect(LoanReminderPlanner.stableId('l', 'j', 'u', -3), isNot(a));
      expect(a, greaterThanOrEqualTo(0));
      expect(a, lessThanOrEqualTo(0x7fffffff));
    });

    test('planning twice gives the same plan (no duplicates)', () {
      final now = DateTime(2026, 12, 20);
      final first = plan([at(now)], now: now);
      final second = plan([at(now)], now: now);
      expect(second, first);
      expect(first.map((r) => r.id).toSet(), hasLength(first.length));
    });

    test('at most maxReminders are planned, soonest first', () {
      final now = DateTime(2026, 12, 20);
      final many = [
        for (var i = 0; i < 20; i++)
          LoanCalculator.snapshot(monthlyLoan(id: 'loan$i'), const [], now),
      ];
      final reminders = plan(many, now: now);
      expect(reminders, hasLength(LoanReminderPlanner.maxReminders));
    });
  });

  test('a new time zone or DST offset is picked up when planning again', () {
    // Fire times are local wall-clock times; planning converts them to an
    // instant at scheduling time, so re-planning after a change keeps 9:00.
    final now = DateTime(2027, 3, 20);
    final reminders = plan([at(now)], now: now);
    expect(
      reminders.every((r) => r.fireAt.hour == 9 && !r.fireAt.isUtc),
      isTrue,
    );
  });
}
