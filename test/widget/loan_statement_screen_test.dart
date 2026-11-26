import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/file_service.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/features/lending/screens/loan_details_screen.dart';
import 'package:money_mate/features/lending/screens/loan_statement_screen.dart';
import 'package:money_mate/models/loan_model.dart';

import '../helpers/app_harness.dart';

/// Records what would have gone to the share sheet.
class FakeFileService extends FileService {
  FakeFileService();

  final List<({String fileName, Uint8List bytes, String? subject})> files = [];
  final List<String> texts = [];

  @override
  Future<bool> shareBytes({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? subject,
    Rect? origin,
  }) async {
    expect(mimeType, 'application/pdf');
    files.add((fileName: fileName, bytes: bytes, subject: subject));
    return true;
  }

  @override
  Future<bool> shareText({
    required String text,
    String? subject,
    Rect? origin,
  }) async {
    texts.add(text);
    return true;
  }
}

void main() {
  setUp(() => LoanStatementScreen.showPdfPreview = false);
  tearDown(() => LoanStatementScreen.showPdfPreview = true);

  final today = PeriodUtils.dateOnly(DateTime.now());

  Loan seededLoan({String phone = ''}) {
    final lent = today.subtract(const Duration(days: 40));
    final first = today.add(const Duration(days: 10));
    var n = 0;
    return Loan(
      id: 'seed',
      borrowerName: 'John',
      borrowerPhone: phone,
      principalMinor: 1200000,
      lentDate: lent,
      repaymentType: LoanRepaymentType.monthly,
      installmentMinor: 100000,
      originalInstallmentMinor: 100000,
      originalTermMonths: 12,
      firstDueDate: first,
      dueDay: first.day,
      schedule: LoanCalculator.buildSchedule(
        loanId: 'seed',
        type: LoanRepaymentType.monthly,
        principalMinor: 1200000,
        newId: () => 'seed-${++n}',
        months: 12,
        firstDueDate: first,
        dueDay: first.day,
      ),
      createdAt: lent,
      updatedAt: lent,
    );
  }

  Future<void> openStatement(WidgetTester tester, TestHarness app) async {
    await app.pump(tester);
    await openTab(tester, 'Settings');
    final tile = find.byKey(const Key('lendingTile'));
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('loanTile-seed')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('loanTile-seed')));
    await tester.pumpAndSettle();
    expect(find.byType(LoanDetailsScreen), findsOneWidget);
    expect(find.byKey(const Key('shareLoanButton')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('shareLoanDetailsButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shareLoanDetailsButton')));
    await tester.pumpAndSettle();
    expect(find.byType(LoanStatementScreen), findsOneWidget);
  }

  testWidgets('the lender reviews and shares the statement as PDF or text', (
    tester,
  ) async {
    final files = FakeFileService();
    final app = TestHarness(withLoans: true, fileService: files);
    final loan = seededLoan();
    app.loans!.loans[loan.id] = loan;
    // An extra capital payment revised the EMI.
    app.loans!.repayments['r1'] = LoanRepayment(
      id: 'r1',
      loanId: loan.id,
      amountMinor: 150000,
      date: today,
      createdAt: today,
      updatedAt: today,
      syncState: RepaymentSyncState.synced,
    );
    await openStatement(tester, app);

    // Nothing is sent until the lender chooses to.
    expect(files.files, isEmpty);
    expect(files.texts, isEmpty);
    expect(
      find.textContaining('cannot be updated or recalled'),
      findsOneWidget,
    );

    await tester.tap(find.text('Share as text'));
    await tester.pumpAndSettle();
    final text = files.texts.single;
    expect(text, contains('Borrower: John'));
    expect(text, contains('Lender: Sam Lee'));
    expect(text, contains('Revised EMI: AED 954.55'));
    expect(text, contains('Outstanding Capital: AED 10,500.00'));
    expect(text, contains('Remaining Instalments: 11'));

    await tester.tap(find.text('Share PDF'));
    await tester.pumpAndSettle();
    final shared = files.files.single;
    expect(shared.fileName, startsWith('MoneyMate-Loan-Statement-ML-'));
    expect(shared.fileName, endsWith('.pdf'));
    expect(latin1.decode(shared.bytes.sublist(0, 5)), '%PDF-');
    expect(shared.subject, 'Loan statement - John');
  });

  testWidgets('contact details are offered only when saved, and off', (
    tester,
  ) async {
    final files = FakeFileService();
    final app = TestHarness(withLoans: true, fileService: files);
    final loan = seededLoan(phone: '+971 50 123 4567');
    app.loans!.loans[loan.id] = loan;
    await openStatement(tester, app);

    await tester.tap(find.byKey(const Key('statementOptions')));
    await tester.pumpAndSettle();
    final contact = find.byKey(const Key('statementContactSwitch'));
    expect(tester.widget<SwitchListTile>(contact).value, isFalse);
    expect(tester.widget<SwitchListTile>(contact).onChanged, isNotNull);

    await tester.enterText(
      find.byKey(const Key('statementLenderField')),
      'Sam',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share as text'));
    await tester.pumpAndSettle();
    expect(files.texts.single, contains('Lender: Sam\n'));
    expect(files.texts.single, isNot(contains('+971')));
  });
}
