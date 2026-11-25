import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/models/loan_model.dart';

import '../helpers/loan_builders.dart';

void main() {
  group('monthly schedule', () {
    test('AED 12,000 at AED 1,000 a month: 12 instalments on the 1st', () {
      final loan = monthlyLoan();
      expect(loan.schedule, hasLength(12));
      expect(loan.schedule.every((i) => i.expectedMinor == aed(1000)), isTrue);
      expect(loan.schedule.first.dueDate, DateTime(2027, 1, 1));
      expect(loan.schedule.last.dueDate, DateTime(2027, 12, 1));
      expect(
        [for (final i in loan.schedule) i.number],
        [for (var n = 1; n <= 12; n++) n],
      );
      expect(loan.schedule.map((i) => i.id).toSet(), hasLength(12));
    });

    test('the last instalment is only what is left, never more', () {
      final loan = monthlyLoan(principal: aed(10500), installment: aed(1000));
      expect(loan.schedule, hasLength(11));
      expect(loan.schedule.last.expectedMinor, aed(500));
      final total = loan.schedule.fold<int>(0, (s, i) => s + i.expectedMinor);
      expect(total, loan.totalOwedMinor);
    });

    test('the 31st falls on the last day of shorter months', () {
      final first = DateTime(2027, 1, 31);
      expect(
        LoanCalculator.monthlyDueDate(first, 31, 1),
        DateTime(2027, 2, 28),
      );
      expect(
        LoanCalculator.monthlyDueDate(first, 31, 2),
        DateTime(2027, 3, 31),
      );
      expect(
        LoanCalculator.monthlyDueDate(first, 31, 3),
        DateTime(2027, 4, 30),
      );
      // Leap year.
      expect(
        LoanCalculator.monthlyDueDate(DateTime(2028, 1, 31), 31, 1),
        DateTime(2028, 2, 29),
      );
      // Across the year end.
      expect(
        LoanCalculator.monthlyDueDate(DateTime(2027, 11, 30), 30, 3),
        DateTime(2028, 2, 29),
      );
    });

    test('the first instalment keeps its own date, later ones the due day', () {
      final loan = monthlyLoan(
        firstDue: DateTime(2027, 1, 15),
        dueDay: 1,
        principal: aed(3000),
      );
      expect(
        [for (final i in loan.schedule) i.dueDate],
        [DateTime(2027, 1, 15), DateTime(2027, 2, 1), DateTime(2027, 3, 1)],
      );
    });

    test('schedules longer than 50 years are refused', () {
      expect(
        () => LoanCalculator.quote(
          principalMinor: aed(1000000),
          interestRateBp: 0,
          type: LoanRepaymentType.monthly,
          lentDate: DateTime(2026),
          installmentMinor: aed(100),
        ),
        throwsA(isA<LoanException>()),
      );
    });
  });

  group('interest', () {
    test('one-time: simple interest for the days lent', () {
      final quote = LoanCalculator.quote(
        principalMinor: aed(10000),
        interestRateBp: 1000, // 10% a year
        type: LoanRepaymentType.oneTime,
        lentDate: DateTime(2027, 1, 1),
        dueDate: DateTime(2028, 1, 1),
      );
      expect(quote.interestMinor, aed(1000));
      expect(quote.installmentCount, 1);
    });

    test('monthly: flat interest for the months needed', () {
      // 12,000 at 12% a year → 120 a month. 1,120 a month needs
      // ceil(12000 / 1000) = 12 months → 1,440 interest.
      final loan = monthlyLoan(installment: aed(1120), rateBp: 1200);
      expect(loan.interestMinor, aed(1440));
      expect(loan.totalOwedMinor, aed(13440));
      expect(loan.schedule, hasLength(12));
      expect(loan.schedule.last.expectedMinor, aed(1120));
    });

    test('an instalment not covering the monthly interest is refused', () {
      expect(
        () => monthlyLoan(installment: aed(100), rateBp: 1200),
        throwsA(
          isA<LoanException>().having(
            (e) => e.message,
            'message',
            contains('more than the monthly interest'),
          ),
        ),
      );
    });

    test('repayments are split pro rata into principal and interest', () {
      final loan = oneTimeLoan(
        principal: aed(10000),
        rateBp: 1000,
        lent: DateTime(2027, 1, 1),
        due: DateTime(2028, 1, 1),
      );
      expect(loan.totalOwedMinor, aed(11000));
      final half = LoanCalculator.snapshot(loan, [
        pay(loan.id, aed(5500), DateTime(2027, 6, 1)),
      ], DateTime(2027, 6, 2));
      expect(half.principalReceivedMinor, aed(5000));
      expect(half.interestReceivedMinor, aed(500));
      expect(half.outstandingPrincipalMinor, aed(5000));
      final full = LoanCalculator.snapshot(loan, [
        pay(loan.id, aed(5500), DateTime(2027, 6, 1), id: 'a'),
        pay(loan.id, aed(5500), DateTime(2027, 9, 1), id: 'b'),
      ], DateTime(2027, 9, 2));
      expect(full.principalReceivedMinor, aed(10000));
      expect(full.interestReceivedMinor, aed(1000));
      expect(full.isCompleted, isTrue);
    });

    test('without interest everything received is principal', () {
      expect(
        LoanCalculator.principalPart(aed(300), aed(1000), aed(1000)),
        aed(300),
      );
    });
  });

  group('repayments and statuses', () {
    final loan = monthlyLoan();

    test('nothing paid: upcoming, then due, then overdue', () {
      var s = LoanCalculator.snapshot(loan, const [], DateTime(2026, 12, 10));
      expect(s.installments.first.status, InstallmentStatus.upcoming);
      expect(s.status, LoanStatus.active);

      s = LoanCalculator.snapshot(loan, const [], DateTime(2026, 12, 29));
      expect(s.installments.first.status, InstallmentStatus.due);

      s = LoanCalculator.snapshot(loan, const [], DateTime(2027, 1, 1, 18));
      expect(s.installments.first.status, InstallmentStatus.due);

      s = LoanCalculator.snapshot(loan, const [], DateTime(2027, 1, 2));
      expect(s.installments.first.status, InstallmentStatus.overdue);
      expect(s.status, LoanStatus.overdue);
      expect(s.overdueMinor, aed(1000));
    });

    test('a partial payment leaves the instalment partly paid', () {
      final s = LoanCalculator.snapshot(loan, [
        pay(loan.id, aed(400), DateTime(2026, 12, 20)),
      ], DateTime(2026, 12, 21));
      final first = s.installments.first;
      expect(first.status, InstallmentStatus.partiallyPaid);
      expect(first.receivedMinor, aed(400));
      expect(first.remainingMinor, aed(600));
      expect(s.outstandingMinor, aed(11600));
    });

    test('a partly paid instalment past its date is overdue', () {
      final s = LoanCalculator.snapshot(loan, [
        pay(loan.id, aed(400), DateTime(2026, 12, 20)),
      ], DateTime(2027, 1, 5));
      expect(s.installments.first.status, InstallmentStatus.overdue);
      expect(s.overdueMinor, aed(600));
    });

    test(
      'early and extra payments cover the next instalments, oldest first',
      () {
        final s = LoanCalculator.snapshot(loan, [
          pay(loan.id, aed(2500), DateTime(2026, 12, 5), id: 'big'),
        ], DateTime(2026, 12, 6));
        expect(s.installments[0].status, InstallmentStatus.paid);
        expect(s.installments[1].status, InstallmentStatus.paid);
        expect(s.installments[2].receivedMinor, aed(500));
        expect(s.installments[0].repaymentIds, ['big']);
        expect(s.installments[2].repaymentIds, ['big']);
        expect(s.nextDue!.number, 3);
      },
    );

    test('paying everything completes the loan', () {
      final s = LoanCalculator.snapshot(loan, [
        pay(loan.id, aed(12000), DateTime(2026, 12, 5)),
      ], DateTime(2027, 6, 1));
      expect(s.status, LoanStatus.completed);
      expect(s.outstandingMinor, 0);
      expect(s.overdueMinor, 0);
      expect(s.nextDue, isNull);
      expect(s.progress, 1);
    });

    test('voided and refused repayments do not count but stay listed', () {
      final s = LoanCalculator.snapshot(loan, [
        pay(loan.id, aed(1000), DateTime(2026, 12, 5), id: 'v', voided: true),
        pay(
          loan.id,
          aed(1000),
          DateTime(2026, 12, 6),
          id: 'x',
          state: RepaymentSyncState.rejected,
        ),
        pay(loan.id, aed(300), DateTime(2026, 12, 7), id: 'ok'),
      ], DateTime(2026, 12, 8));
      expect(s.receivedMinor, aed(300));
      expect(s.installments.first.repaymentIds, ['ok']);
    });

    test('one-time loans accept several partial repayments', () {
      final once = oneTimeLoan();
      final s = LoanCalculator.snapshot(once, [
        pay(once.id, aed(1000), DateTime(2026, 11, 10), id: 'a'),
        pay(once.id, aed(1500), DateTime(2026, 12, 10), id: 'b'),
      ], DateTime(2026, 12, 11));
      expect(s.installments, hasLength(1));
      expect(s.installments.first.status, InstallmentStatus.partiallyPaid);
      expect(s.outstandingMinor, aed(2500));
      expect(s.installments.first.repaymentIds, ['a', 'b']);
      final late = LoanCalculator.snapshot(
        once,
        const [],
        DateTime(2027, 2, 2),
      );
      expect(late.status, LoanStatus.overdue);
    });
  });

  group('schedule changes', () {
    test('paid and partly paid instalments are kept; the rest is rebuilt', () {
      final loan = monthlyLoan();
      final s = LoanCalculator.snapshot(loan, [
        pay(loan.id, aed(1500), DateTime(2027, 1, 1)),
      ], DateTime(2027, 1, 20));
      final settled = LoanCalculator.settledInstallments(s);
      expect(settled.map((i) => i.number), [1, 2]);
      final rebuilt = LoanCalculator.buildSchedule(
        loanId: loan.id,
        type: LoanRepaymentType.monthly,
        totalOwedMinor: loan.totalOwedMinor,
        newId: nextId,
        kept: settled,
        installmentMinor: aed(2000),
        firstDueDate: DateTime(2027, 3, 15),
        dueDay: 15,
      );
      expect(rebuilt.take(2), settled);
      // 12,000 − 2,000 kept = 10,000 → five instalments of 2,000.
      expect(rebuilt.skip(2).map((i) => i.expectedMinor), [
        for (var n = 0; n < 5; n++) aed(2000),
      ]);
      expect(rebuilt.skip(2).first.number, 3);
      expect(rebuilt.skip(2).first.dueDate, DateTime(2027, 3, 15));
      // History is untouched: the same repayment still covers 1½ instalments.
      final after = LoanCalculator.snapshot(loan.copyWith(schedule: rebuilt), [
        pay(loan.id, aed(1500), DateTime(2027, 1, 1)),
      ], DateTime(2027, 1, 20));
      expect(after.installments[0].isPaid, isTrue);
      expect(after.installments[1].receivedMinor, aed(500));
      expect(after.outstandingMinor, aed(10500));
    });

    test('a total below what is already scheduled and paid is refused', () {
      final loan = monthlyLoan();
      expect(
        () => LoanCalculator.buildSchedule(
          loanId: loan.id,
          type: LoanRepaymentType.monthly,
          totalOwedMinor: aed(500),
          newId: nextId,
          kept: loan.schedule.take(1).toList(),
          installmentMinor: aed(100),
          firstDueDate: DateTime(2027, 2, 1),
        ),
        throwsA(isA<LoanException>()),
      );
    });
  });

  group('summaries', () {
    test('totals and borrowers; loans of the same person stay separate', () {
      final a = oneTimeLoan(id: 'a', name: 'John', principal: aed(1000));
      final b = oneTimeLoan(id: 'b', name: ' john ', principal: aed(2000));
      final c = oneTimeLoan(id: 'c', name: 'Mia', principal: aed(500));
      final now = DateTime(2027, 3, 1); // all past due
      final snaps = [
        LoanCalculator.snapshot(a, [
          pay('a', aed(1000), DateTime(2026, 12, 1)),
        ], now),
        LoanCalculator.snapshot(b, [
          pay('b', aed(500), DateTime(2026, 12, 1)),
        ], now),
        LoanCalculator.snapshot(c, const [], now),
      ];
      final sum = LoanCalculator.summarize(snaps);
      expect(sum.lentMinor, aed(3500));
      expect(sum.receivedMinor, aed(1500));
      expect(sum.outstandingMinor, aed(2000));
      expect(sum.activeCount, 2);
      expect(sum.completedCount, 1);
      expect(sum.overdueCount, 2);
      expect(sum.overdueMinor, aed(2000));

      final borrowers = LoanCalculator.byBorrower(snaps);
      expect(borrowers, hasLength(2));
      final john = borrowers.firstWhere((x) => x.key == 'john');
      expect(john.loans, hasLength(2));
      expect(john.lentMinor, aed(3000));
      expect(john.outstandingMinor, aed(1500));
      expect(john.activeCount, 1);
      expect(john.completedCount, 1);
    });
  });

  group('rates', () {
    test('parse and format basis points', () {
      expect(parseRateBp('12.5'), 1250);
      expect(parseRateBp('12,05'), 1205);
      expect(parseRateBp(''), 0);
      expect(parseRateBp('abc'), isNull);
      expect(formatRateBp(1250), '12.5%');
      expect(formatRateBp(1205), '12.05%');
      expect(formatRateBp(800), '8%');
    });
  });
}
