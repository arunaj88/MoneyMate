import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/models/loan_model.dart';

import '../helpers/loan_builders.dart';

/// The standard reducing-balance EMI, rounded up to a whole minor unit.
int emiFormula(int principal, int rateBp, int months) {
  final r = rateBp / 120000;
  final g = math.pow(1 + r, months).toDouble();
  return (principal * r * g / (g - 1)).ceil();
}

int totalPrincipal(LoanSnapshot s) =>
    s.installments.fold(0, (sum, i) => sum + i.principalMinor);

void main() {
  final jan = DateTime(2027, 1, 1, 12);
  LoanSnapshot apply(Loan loan, List<LoanRepayment> paid, [DateTime? now]) =>
      LoanCalculator.snapshot(loan, paid, now ?? DateTime(2027, 1, 2));

  RepaymentAllocation allocate(
    Loan loan,
    List<LoanRepayment> before,
    LoanRepayment repayment,
  ) => LoanCalculator.allocation(
    before: apply(loan, before),
    after: apply(loan, [...before, repayment]),
    amountMinor: repayment.amountMinor,
    now: DateTime(2027, 1, 2),
  );

  group('zero interest', () {
    // AED 12,000 over 12 months at AED 1,000, first EMI on 1 January.
    final loan = monthlyLoan(months: 12);

    test('AED 1,500 in January: 500 to capital, EMI revised to 954.55', () {
      final s = apply(loan, [pay(loan.id, aed(1500), jan, id: 'jan')]);
      final january = s.installments.first;
      expect(january.isPaid, isTrue);
      expect(january.scheduledMinor, aed(1000));
      expect(january.extraPrincipalMinor, aed(500));
      expect(s.outstandingPrincipalMinor, aed(10500));
      expect(s.remainingInstallments, 11);
      expect(s.currentEmiMinor, 95455);
      // Final instalment settles the exact rest: 10,500 − 954.55 × 10.
      expect(s.installments.last.expectedMinor, 1050000 - 95455 * 10);
      expect(s.installments.last.expectedMinor, 95450);
      // Same dates as agreed.
      expect(s.installments[1].dueDate, DateTime(2027, 2, 1));
      expect(s.installments.last.dueDate, DateTime(2027, 12, 1));
      expect(totalPrincipal(s), aed(12000));
    });

    test('the allocation is recorded in full', () {
      final a = allocate(loan, const [], pay(loan.id, aed(1500), jan));
      expect(a.installmentNumber, 1);
      expect(a.scheduledEmiMinor, aed(1000));
      expect(a.appliedToInstallmentMinor, aed(1000));
      expect(a.interestPortionMinor, 0);
      expect(a.principalPortionMinor, aed(1000));
      expect(a.extraPrincipalMinor, aed(500));
      expect(a.principalBeforeMinor, aed(12000));
      expect(a.principalAfterMinor, aed(10500));
      expect(a.previousEmiMinor, aed(1000));
      expect(a.revisedEmiMinor, 95455);
      expect(a.remainingInstallments, 11);
      expect(a.effectiveFrom, DateTime(2027, 2, 1));
      // It survives storage unchanged.
      expect(RepaymentAllocation.fromJson(a.toJson()), a);
    });

    test('several extra payments: a fresh EMI after each', () {
      final paid = <LoanRepayment>[pay(loan.id, aed(1500), jan, id: 'jan')];
      var s = apply(loan, paid);
      final afterJan = s.currentEmiMinor!;
      expect(afterJan, 95455);
      paid.add(pay(loan.id, afterJan, DateTime(2027, 2, 1, 12), id: 'feb'));
      s = apply(loan, paid);
      expect(
        s.currentEmiMinor,
        afterJan,
        reason: 'an exact EMI changes nothing',
      );

      // March: the EMI plus 400 extra.
      paid.add(
        pay(loan.id, afterJan + aed(400), DateTime(2027, 3, 1, 12), id: 'mar'),
      );
      s = apply(loan, paid);
      // 12,000 − 1,500 − 954.55 × 2 − 400 = 8,190.90 over 9 months.
      final capitalAfterMarch =
          aed(12000) - aed(1500) - 2 * afterJan - aed(400);
      expect(s.outstandingPrincipalMinor, capitalAfterMarch);
      expect(s.remainingInstallments, 9);
      expect(s.currentEmiMinor, (capitalAfterMarch + 8) ~/ 9);
      final afterMarch = s.currentEmiMinor!;

      // June-style big payment on the next due date: EMI + 2,000 extra.
      paid.add(
        pay(
          loan.id,
          afterMarch + aed(2000),
          DateTime(2027, 4, 1, 12),
          id: 'apr',
        ),
      );
      s = apply(loan, paid);
      final capitalAfterApril = capitalAfterMarch - afterMarch - aed(2000);
      expect(s.outstandingPrincipalMinor, capitalAfterApril);
      expect(s.remainingInstallments, 8);
      expect(s.currentEmiMinor, (capitalAfterApril + 7) ~/ 8);
      expect(s.currentEmiMinor, lessThan(afterMarch));
      expect(totalPrincipal(s), aed(12000));
      expect(
        s.installments.where((i) => i.extraPrincipalMinor > 0),
        hasLength(3),
      );
    });

    test('a partly paid EMI is completed first, the rest goes to capital', () {
      final s = apply(loan, [
        pay(loan.id, aed(400), DateTime(2026, 12, 20), id: 'part'),
        pay(loan.id, aed(1500), DateTime(2026, 12, 28), id: 'more'),
      ]);
      expect(s.installments.first.isPaid, isTrue);
      expect(s.installments.first.extraPrincipalMinor, aed(900));
      // 12,000 − 1,000 − 900 = 10,100 over 11 months.
      expect(s.outstandingPrincipalMinor, aed(10100));
      expect(s.currentEmiMinor, (1010000 + 10) ~/ 11);
    });

    test(
      'paid before the due date: applied to the current EMI the same way',
      () {
        final early = pay(loan.id, aed(1500), DateTime(2026, 12, 10, 12));
        final s = apply(loan, [early], DateTime(2026, 12, 11));
        expect(s.installments.first.isPaid, isTrue);
        expect(s.installments.first.extraPrincipalMinor, aed(500));
        final a = LoanCalculator.allocation(
          before: apply(loan, const [], DateTime(2026, 12, 11)),
          after: s,
          amountMinor: early.amountMinor,
          now: DateTime(2026, 12, 11),
        );
        expect(a.installmentNumber, 1);
        expect(a.effectiveFrom, DateTime(2027, 2, 1));
      },
    );

    test('paying the settlement amount completes the loan', () {
      final before = apply(loan, [pay(loan.id, aed(1500), jan, id: 'jan')]);
      expect(before.settlementMinor, aed(10500));
      final s = apply(loan, [
        pay(loan.id, aed(1500), jan, id: 'jan'),
        pay(loan.id, aed(10500), DateTime(2027, 1, 20, 12), id: 'rest'),
      ], DateTime(2027, 1, 21));
      expect(s.isCompleted, isTrue);
      expect(s.outstandingMinor, 0);
      expect(s.remainingInstallments, 0);
      expect(s.nextDue, isNull);
    });

    test('voiding an extra payment restores the agreed schedule', () {
      final s = apply(loan, [
        pay(loan.id, aed(1500), jan, id: 'jan', voided: true),
      ]);
      expect(s.currentEmiMinor, aed(1000));
      expect(s.installments.every((i) => i.expectedMinor == aed(1000)), isTrue);
    });
  });

  group('reducing balance', () {
    // AED 12,000 at 12% a year over 12 months.
    final loan = monthlyLoan(
      months: 12,
      rateBp: 1200,
      method: InterestMethod.reducing,
    );

    test('the schedule follows the standard EMI formula', () {
      final s = apply(loan, const [], DateTime(2026, 12, 2));
      final emi = emiFormula(aed(12000), 1200, 12);
      expect(s.currentEmiMinor, emi);
      // First month: 1% of 12,000 is interest.
      expect(s.installments.first.interestMinor, aed(120));
      expect(totalPrincipal(s), aed(12000));
      expect(s.installments, hasLength(12));
      // Interest falls as the balance falls.
      expect(
        s.installments[11].interestMinor,
        lessThan(s.installments[0].interestMinor),
      );
    });

    test('an extra payment cuts capital; the EMI is recalculated', () {
      final emi = emiFormula(aed(12000), 1200, 12);
      final s = apply(loan, [pay(loan.id, emi + aed(500), jan, id: 'jan')]);
      final january = s.installments.first;
      // January's interest and principal as scheduled, then 500 capital.
      expect(january.interestMinor, aed(120));
      expect(january.extraPrincipalMinor, aed(500));
      final capital = aed(12000) - (emi - aed(120)) - aed(500);
      expect(s.outstandingPrincipalMinor, capital);
      expect(s.remainingInstallments, 11);
      expect(s.currentEmiMinor, emiFormula(capital, 1200, 11));
      // February's interest is on the reduced capital.
      expect(s.installments[1].interestMinor, (capital / 100).round());
      expect(totalPrincipal(s), aed(12000));
      // Less interest is owed overall than agreed.
      expect(s.loan.interestMinor, lessThan(loan.interestMinor));
    });

    test('settling early: future interest is not owed', () {
      final emi = emiFormula(aed(12000), 1200, 12);
      final before = apply(loan, [pay(loan.id, emi, jan, id: 'jan')]);
      expect(before.settlementMinor, lessThan(before.outstandingMinor));
      final settled = apply(loan, [
        pay(loan.id, emi, jan, id: 'jan'),
        pay(loan.id, before.settlementMinor, DateTime(2027, 1, 20), id: 'all'),
      ], DateTime(2027, 1, 21));
      expect(settled.isCompleted, isTrue);
      expect(settled.outstandingPrincipalMinor, 0);
    });

    test('the agreed EMI and term stay on record', () {
      final emi = emiFormula(aed(12000), 1200, 12);
      final s = apply(loan, [pay(loan.id, emi + aed(500), jan)]);
      expect(s.loan.originalInstallmentMinor, emi);
      expect(s.loan.originalTermMonths, 12);
      expect(s.currentEmiMinor, isNot(emi));
    });
  });

  group('flat interest', () {
    test('the revised EMI uses flat interest on the reduced capital', () {
      // 12,000 at 12% flat over 12 months: 1,120 a month.
      final loan = monthlyLoan(months: 12, rateBp: 1200);
      expect(loan.installmentMinor, aed(1120));
      final s = apply(loan, [pay(loan.id, aed(1620), jan)]);
      expect(s.installments.first.extraPrincipalMinor, aed(500));
      // 10,500 for 11 months: 1,155 interest, (10,500 + 1,155) / 11.
      expect(s.outstandingPrincipalMinor, aed(10500));
      expect(s.currentEmiMinor, (1165500 + 10) ~/ 11);
    });
  });

  test('one-time loans: every repayment goes to the single amount due', () {
    final loan = oneTimeLoan(principal: aed(5000));
    final s = apply(loan, [pay(loan.id, aed(3000), DateTime(2026, 11, 10))]);
    expect(s.installments.single.extraPrincipalMinor, 0);
    expect(s.outstandingMinor, aed(2000));
    expect(s.settlementMinor, aed(2000));
  });
}
