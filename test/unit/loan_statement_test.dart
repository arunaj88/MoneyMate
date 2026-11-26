import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/services/loan_statement.dart';
import 'package:money_mate/core/services/loan_statement_pdf.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/transaction_model.dart';

import '../helpers/loan_builders.dart';

void main() {
  final jan = DateTime(2027, 1, 1, 12);
  final feb = DateTime(2027, 2, 1, 12);
  final now = DateTime(2027, 1, 20, 14, 5);

  LoanStatement build(
    Loan loan,
    List<LoanRepayment> repayments, {
    DateTime? at,
    LoanStatementOptions options = const LoanStatementOptions(
      lenderName: 'Sam Lee',
    ),
  }) => LoanStatement.build(
    loan: loan,
    repayments: repayments,
    now: at ?? now,
    currencyCode: 'AED',
    options: options,
  );

  /// Page objects of an uncompressed PDF.
  int pageCount(List<int> bytes) =>
      RegExp(r'/Type\s*/Page[^s]').allMatches(latin1.decode(bytes)).length;

  /// The words drawn on the pages of an uncompressed PDF, in order.
  String wordsOf(List<int> bytes) => [
    for (final m in RegExp(
      r'\[\(((?:\\.|[^\\)])*)\)\]TJ',
    ).allMatches(latin1.decode(bytes)))
      m.group(1)!.replaceAllMapped(RegExp(r'\\(.)'), (e) => e.group(1)!),
  ].join(' ');

  Future<String> pdfText(LoanStatement s, {String? logo}) async =>
      wordsOf(await LoanStatementPdf.build(s, logoSvg: logo, compress: false));

  group('a new loan agreement', () {
    final loan = monthlyLoan(months: 12);

    test('shows the agreed terms and the full 12-month schedule', () {
      final s = build(loan, const []);
      expect(s.reference, startsWith('ML-20261201-'));
      expect(s.reference, LoanStatement.referenceOf(loan));
      expect(s.lenderName, 'Sam Lee');
      expect(s.borrowerName, 'John');
      expect(s.principalMinor, aed(12000));
      expect(s.originalEmiMinor, aed(1000));
      expect(s.originalTermMonths, 12);
      expect(s.originalFinalDueDate, DateTime(2027, 12, 1));
      expect(s.currentFinalDueDate, DateTime(2027, 12, 1));
      expect(s.interestLabel, 'Interest-free');
      expect(s.installments, hasLength(12));
      expect(s.installments.first.status, InstallmentStatus.overdue);
      expect(s.installments[1].status, InstallmentStatus.upcoming);
      expect(
        s.installments.every((i) => i.scheduledMinor == aed(1000)),
        isTrue,
      );
      expect(s.repayments, isEmpty);
      expect(s.revisions, isEmpty);
      expect(s.emiRevised, isFalse);
      expect(s.remainingInstallments, 12);
      expect(s.completedInstallments, 0);
      expect(s.nextAmountMinor, aed(1000));
      expect(s.nextDueDate, DateTime(2027, 1, 1));
      expect(s.status, LoanStatus.overdue);
    });

    test('summary text', () {
      final text = build(loan, const [], at: DateTime(2026, 12, 2)).toText();
      expect(text, contains('MoneyMate - Loan Repayment Details'));
      expect(text, contains('Borrower: John'));
      expect(text, contains('Lender: Sam Lee'));
      expect(text, contains('Loan Amount: AED 12,000.00'));
      expect(text, contains('Loan Date: 1 December 2026'));
      expect(text, contains('Original EMI: AED 1,000.00'));
      expect(text, contains('Current EMI: AED 1,000.00'));
      expect(text, contains('Remaining Instalments: 12'));
      expect(text, contains('Next Due Date: 1 January 2027'));
      expect(text, contains('Statement Date: 2 December 2026'));
      expect(text, isNot(contains('Interest:')));
      expect(text, isNot(contains('attached')));
    });
  });

  group('after an extra capital payment', () {
    final loan = monthlyLoan(months: 12);
    final repayments = [pay(loan.id, aed(1500), jan, id: 'jan')];

    test('revised EMI on every later instalment, marked where it starts', () {
      final s = build(loan, repayments);
      final first = s.installments.first;
      expect(first.status, InstallmentStatus.paid);
      expect(first.scheduledMinor, aed(1000));
      expect(first.receivedMinor, aed(1500));
      expect(first.extraPrincipalMinor, aed(500));
      for (final i in s.installments.skip(1).take(10)) {
        expect(i.scheduledMinor, 95455);
      }
      expect(s.installments.last.scheduledMinor, 95450);
      expect(s.installments[1].revisedFromHere, isTrue);
      expect(s.installments.where((i) => i.revisedFromHere), hasLength(1));
      // The agreement keeps the original terms.
      expect(s.originalEmiMinor, aed(1000));
      expect(s.currentEmiMinor, 95455);
      expect(s.emiRevised, isTrue);
      expect(s.extraPrincipalMinor, aed(500));
      expect(s.principalRepaidMinor, aed(1500));
      expect(s.outstandingPrincipalMinor, aed(10500));
    });

    test('the revision is listed in full', () {
      final r = build(loan, repayments).revisions.single;
      expect(r.date, jan);
      expect(r.capitalBeforeMinor, aed(12000));
      expect(r.extraPrincipalMinor, aed(500));
      expect(r.capitalAfterMinor, aed(10500));
      expect(r.previousEmiMinor, aed(1000));
      expect(r.newEmiMinor, 95455);
      expect(r.remainingInstallments, 11);
      expect(r.effectiveFrom, DateTime(2027, 2, 1));
    });

    test('the repayment history shows how it was applied', () {
      final h = build(loan, repayments).repayments.single;
      expect(h.amountMinor, aed(1500));
      expect(h.scheduledEmiMinor, aed(1000));
      expect(h.principalMinor, aed(1000));
      expect(h.interestMinor, 0);
      expect(h.extraPrincipalMinor, aed(500));
      expect(h.capitalAfterMinor, aed(10500));
    });

    test('the text matches the borrower example', () {
      final text = build(loan, repayments).toText(withAttachment: true);
      expect(text, contains('Original EMI: AED 1,000.00'));
      expect(text, contains('Revised EMI: AED 954.55'));
      expect(text, contains('Outstanding Capital: AED 10,500.00'));
      expect(text, contains('Remaining Instalments: 11'));
      expect(text, contains('Next Payment: AED 954.55'));
      expect(text, contains('Next Due Date: 1 February 2027'));
      expect(
        text,
        contains(
          'Please refer to the attached complete repayment statement for the '
          'instalment schedule and payment history.',
        ),
      );
    });

    test('stored allocations are used as recorded', () {
      final before = LoanCalculator.snapshot(loan, const [], jan);
      final after = LoanCalculator.snapshot(loan, repayments, jan);
      final allocation = LoanCalculator.allocation(
        before: before,
        after: after,
        amountMinor: aed(1500),
        now: jan,
      );
      final stored = LoanRepayment(
        id: 'jan',
        loanId: loan.id,
        amountMinor: aed(1500),
        date: jan,
        createdAt: jan,
        updatedAt: jan,
        syncState: RepaymentSyncState.synced,
        allocation: allocation,
      );
      final fromStored = build(loan, [stored]);
      final replayed = build(loan, repayments);
      expect(
        fromStored.revisions.single.newEmiMinor,
        replayed.revisions.single.newEmiMinor,
      );
      expect(
        fromStored.repayments.single.capitalAfterMinor,
        replayed.repayments.single.capitalAfterMinor,
      );
    });
  });

  test('multiple EMI revisions are all kept, oldest first', () {
    final loan = monthlyLoan(months: 12);
    final s = build(loan, [
      pay(loan.id, aed(1500), jan, id: 'jan'),
      pay(loan.id, 95455 + aed(1000), feb, id: 'feb'),
    ], at: DateTime(2027, 2, 10));
    expect(s.revisions, hasLength(2));
    expect(s.revisions[0].newEmiMinor, 95455);
    expect(s.revisions[1].previousEmiMinor, 95455);
    expect(s.revisions[1].capitalBeforeMinor, aed(10500));
    expect(s.revisions[1].capitalAfterMinor, aed(10500) - 95455 - aed(1000));
    expect(s.revisions[1].effectiveFrom, DateTime(2027, 3, 1));
    expect(s.revisions[1].remainingInstallments, 10);
    expect(s.installments[1].revisedFromHere, isTrue);
    expect(s.installments[2].revisedFromHere, isTrue);
    expect(s.currentEmiMinor, s.revisions[1].newEmiMinor);
    expect(s.extraPrincipalMinor, aed(1500));
    expect(s.repayments.map((r) => r.date), [jan, feb]);
  });

  test('a partially repaid loan', () {
    final loan = monthlyLoan(months: 12);
    final early = build(loan, [
      pay(loan.id, aed(400), DateTime(2026, 12, 20)),
    ], at: DateTime(2026, 12, 21));
    expect(early.installments.first.status, InstallmentStatus.partiallyPaid);
    expect(early.installments.first.unpaidMinor, aed(600));
    expect(early.nextAmountMinor, aed(600));
    expect(early.repayments.single.principalMinor, aed(400));
    expect(early.repayments.single.extraPrincipalMinor, 0);

    final late = build(loan, [pay(loan.id, aed(400), DateTime(2026, 12, 20))]);
    expect(late.installments.first.statusLabel, 'Overdue (part paid)');
    expect(late.overdueMinor, aed(600));
    expect(late.toText(), contains('Overdue: AED 600.00'));
  });

  test('a completed loan', () {
    final loan = monthlyLoan(months: 3, principal: aed(3000));
    final s = build(loan, [
      pay(loan.id, aed(1000), jan, id: 'a'),
      pay(loan.id, aed(1000), feb, id: 'b'),
      pay(loan.id, aed(1000), DateTime(2027, 3, 1), id: 'c'),
    ], at: DateTime(2027, 3, 5));
    expect(s.status, LoanStatus.completed);
    expect(s.isCompleted, isTrue);
    expect(s.currentEmiMinor, isNull);
    expect(s.nextDueDate, isNull);
    expect(s.completedInstallments, 3);
    expect(s.remainingInstallments, 0);
    expect(s.outstandingPrincipalMinor, 0);
    final text = s.toText();
    expect(text, contains('Status: Repaid in full'));
    expect(text, contains('Total Repaid: AED 3,000.00'));
    expect(text, isNot(contains('Next Payment')));
  });

  test('a loan with reducing-balance interest', () {
    final loan = monthlyLoan(
      months: 12,
      rateBp: 1200,
      method: InterestMethod.reducing,
    );
    final s = build(loan, [
      pay(loan.id, loan.schedule.first.expectedMinor, jan),
    ]);
    expect(s.interestLabel, '12% a year (Reducing balance)');
    expect(s.interestMethodLabel, 'Reducing balance');
    expect(
      s.installments.fold<int>(0, (t, i) => t + i.interestMinor),
      s.currentInterestMinor,
    );
    expect(
      s.installments.fold<int>(0, (t, i) => t + i.principalMinor),
      aed(12000),
    );
    // First month's interest: 12,000 × 1%.
    expect(s.installments.first.interestMinor, aed(120));
    expect(s.interestReceivedMinor, aed(120));
    expect(s.repayments.single.interestMinor, aed(120));
    expect(s.toText(), contains('Interest: 12% a year (Reducing balance)'));
    expect(s.toText(), contains('Total Outstanding:'));
  });

  test('one-time loan with simple interest', () {
    final loan = oneTimeLoan(rateBp: 1000);
    final s = build(loan, const [], at: DateTime(2026, 11, 2));
    expect(s.isMonthly, isFalse);
    expect(s.installments, hasLength(1));
    expect(s.interestLabel, '10% a year (Simple interest (by days))');
    expect(s.originalPeriodLabel, 'One-time repayment by 1 February 2027');
    expect(s.originalFinalDueDate, DateTime(2027, 2, 1));
    expect(s.nextAmountMinor, loan.totalOwedMinor);
    expect(s.toText(), isNot(contains('EMI')));
  });

  test(
    'voided repayments are listed but not counted; refused ones left out',
    () {
      final loan = monthlyLoan(months: 12);
      final s = build(loan, [
        pay(loan.id, aed(1000), jan, id: 'ok'),
        pay(
          loan.id,
          aed(5000),
          jan.add(const Duration(hours: 1)),
          id: 'v',
          voided: true,
        ),
        pay(
          loan.id,
          aed(700),
          feb,
          id: 'x',
          state: RepaymentSyncState.rejected,
        ),
      ]);
      expect(s.repayments, hasLength(2));
      expect(s.repayments[1].voided, isTrue);
      expect(s.repayments[1].capitalAfterMinor, isNull);
      expect(s.outstandingPrincipalMinor, aed(11000));
      expect(s.revisions, isEmpty);
    },
  );

  group('privacy', () {
    final household = monthlyLoan(months: 12);
    final loan = Loan(
      id: household.id,
      borrowerName: 'John',
      borrowerPhone: '+971 50 000 0000',
      borrowerEmail: 'john@example.com',
      principalMinor: household.principalMinor,
      lentDate: household.lentDate,
      repaymentType: LoanRepaymentType.monthly,
      installmentMinor: household.installmentMinor,
      originalInstallmentMinor: household.originalInstallmentMinor,
      originalTermMonths: household.originalTermMonths,
      firstDueDate: household.firstDueDate,
      dueDay: household.dueDay,
      notes: 'Pay by bank transfer',
      schedule: household.schedule,
      householdId: 'household-secret-id',
      createdBy: 'uid-alex',
      createdByName: 'Alexandra',
      createdAt: household.createdAt,
      updatedAt: household.updatedAt,
    );
    final repayments = [
      LoanRepayment(
        id: 'r1',
        loanId: loan.id,
        amountMinor: aed(1000),
        date: jan,
        method: PaymentMethod.bankTransfer,
        note: 'Internal note for members',
        createdAt: jan,
        updatedAt: jan,
        userUid: 'uid-alex',
        userName: 'Alexandra',
        syncState: RepaymentSyncState.synced,
      ),
      // Another borrower's repayment must never appear.
      pay('other-loan', aed(9999), jan, id: 'other'),
    ];

    test('contact details only when chosen; notes can be left out', () {
      final hidden = build(loan, repayments);
      expect(hidden.borrowerPhone, isNull);
      expect(hidden.borrowerEmail, isNull);
      expect(hidden.notes, 'Pay by bank transfer');
      expect(hidden.repayments, hasLength(1));

      final shown = build(
        loan,
        repayments,
        options: const LoanStatementOptions(
          lenderName: 'Sam',
          includeContactDetails: true,
          includeNotes: false,
        ),
      );
      expect(shown.borrowerPhone, '+971 50 000 0000');
      expect(shown.borrowerEmail, 'john@example.com');
      expect(shown.notes, isNull);
    });

    test(
      'no household, member or other-loan data in the text or PDF',
      () async {
        final s = build(loan, repayments);
        final pdf = await pdfText(s);
        for (final secret in [
          'household-secret-id',
          'Alexandra',
          'uid-alex',
          'Internal note',
          '99.99',
          '+971',
          'john@example.com',
        ]) {
          expect(s.toText(), isNot(contains(secret)), reason: secret);
          expect(pdf, isNot(contains(secret)), reason: secret);
        }
        // The PDF does carry the statement itself.
        expect(pdf, contains('John'));
        expect(pdf, contains('Sam Lee'));
        expect(pdf, contains(s.reference));
      },
    );
  });

  group('PDF', () {
    final logo = File('assets/branding/app_icon.svg').readAsStringSync();

    test('a 12-month schedule after an extra payment', () async {
      final loan = monthlyLoan(months: 12);
      final s = build(loan, [pay(loan.id, aed(1500), jan, id: 'jan')]);
      final bytes = await LoanStatementPdf.build(s, logoSvg: logo);
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      final text = await pdfText(s, logo: logo);
      for (final heading in [
        'MoneyMate',
        'LATEST SCHEDULE',
        'A. Loan agreement',
        'B. Current repayment summary',
        'C. Repayment schedule',
        'D. EMI revision history',
        'E. Repayment history',
        'Original agreement',
        'Current schedule',
        'Current revised EMI',
        '954.55',
        '10,500.00',
        'Page 1 of',
      ]) {
        expect(text, contains(heading), reason: heading);
      }
    });

    test('long schedules span pages with the heading on each', () async {
      // AED 60,000 over the longest schedule allowed (600 months).
      final loan = monthlyLoan(principal: aed(60000), months: 600);
      final repayments = [
        for (var m = 0; m < 30; m++)
          pay(loan.id, aed(100), DateTime(2027, 1 + m, 1, 12), id: 'm$m'),
      ];
      final s = build(loan, repayments, at: DateTime(2029, 7, 2));
      expect(s.installments, hasLength(600));
      final bytes = await LoanStatementPdf.build(s, compress: false);
      final pages = pageCount(bytes);
      expect(pages, greaterThan(10));
      expect(pages, lessThanOrEqualTo(LoanStatementPdf.maxPages));
      final text = wordsOf(bytes);
      expect(
        'Scheduled EMI'.allMatches(text).length,
        greaterThanOrEqualTo(pages - 2),
      );
      expect(text, contains('Page $pages of $pages'));
    });

    test('completed and one-time loans render', () async {
      final once = oneTimeLoan(rateBp: 500);
      final paid = build(once, [
        pay(once.id, once.totalOwedMinor, DateTime(2027, 1, 15)),
      ], at: DateTime(2027, 1, 16));
      expect(paid.isCompleted, isTrue);
      final text = await pdfText(paid);
      expect(text, contains('C. Expected repayment'));
      expect(text, contains('Completed (repaid in full)'));
      expect(text, isNot(contains('EMI revision history')));
    });

    test('text outside the standard fonts is replaced, not dropped', () {
      expect(LoanStatementPdf.safe('O’Brien – café'), "O'Brien - café");
      expect(LoanStatementPdf.safe('محمد'), '????');
    });
  });
}
