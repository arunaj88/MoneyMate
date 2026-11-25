import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/models/loan_model.dart';

import '../helpers/loan_builders.dart';

void main() {
  group('monthly amount from a number of months', () {
    test('AED 12,000 over 12 months is AED 1,000 a month', () {
      final q = LoanCalculator.quoteForMonths(
        principalMinor: aed(12000),
        interestRateBp: 0,
        months: 12,
      );
      expect(q.installmentMinor, aed(1000));
      expect(q.interestMinor, 0);
    });

    test('an uneven split rounds up; the last month is smaller', () {
      final q = LoanCalculator.quoteForMonths(
        principalMinor: aed(1000),
        interestRateBp: 0,
        months: 3,
      );
      expect(q.installmentMinor, 33334);
      final schedule = LoanCalculator.buildSchedule(
        loanId: 'l',
        type: LoanRepaymentType.monthly,
        principalMinor: aed(1000),
        newId: nextId,
        months: 3,
        firstDueDate: DateTime(2027, 1, 1),
      );
      expect(schedule.map((i) => i.expectedMinor), [33334, 33334, 33332]);
    });

    test('interest is for the months chosen and spread over them', () {
      // 12,000 at 12% a year for 12 months: 1,440 interest, 1,120 a month.
      final q = LoanCalculator.quoteForMonths(
        principalMinor: aed(12000),
        interestRateBp: 1200,
        months: 12,
      );
      expect(q.interestMinor, aed(1440));
      expect(q.installmentMinor, aed(1120));
    });

    test('invalid months and amounts too small to split are refused', () {
      for (final months in [0, -1, LoanLimits.maxInstallments + 1]) {
        expect(
          () => LoanCalculator.quoteForMonths(
            principalMinor: aed(100),
            interestRateBp: 0,
            months: months,
          ),
          throwsA(isA<LoanException>()),
        );
      }
      // 10 fils cannot be spread over 6 months.
      expect(
        () => LoanCalculator.quoteForMonths(
          principalMinor: 10,
          interestRateBp: 0,
          months: 6,
        ),
        throwsA(isA<LoanException>()),
      );
    });
  });
}
