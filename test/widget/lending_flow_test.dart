import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/features/lending/screens/loan_details_screen.dart';
import 'package:money_mate/features/lending/widgets/lending_widgets.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/transaction_model.dart';

import '../helpers/app_harness.dart';
import '../helpers/fake_household_service.dart';
import '../helpers/fake_notifications.dart';
import '../helpers/fakes.dart';

void main() {
  final today = PeriodUtils.dateOnly(DateTime.now());

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

  /// Scrolls the screen's list until [finder] is built and visible.
  Future<void> scrollTo(WidgetTester tester, Finder finder) async {
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
  }

  /// The details list builds lazily: scroll back up to the summary first.
  Future<String> outstanding(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.byKey(const Key('loanOutstandingText')),
      -300,
      scrollable: find
          .descendant(
            of: find.byType(LoanDetailsScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    return textOf(tester, 'loanOutstandingText');
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> openLending(WidgetTester tester) async {
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
    expect(find.text('Money lent'), findsWidgets);
  }

  /// A loan stored directly, as if synced: [daysAgo] lent, first EMI due
  /// [firstDueInDays] from today.
  Loan seededLoan({
    String id = 'seed',
    String? householdId,
    String? createdBy,
    int firstDueInDays = -5,
  }) {
    final lent = today.subtract(const Duration(days: 40));
    final first = today.add(Duration(days: firstDueInDays));
    var n = 0;
    return Loan(
      id: id,
      borrowerName: 'John',
      principalMinor: 300000,
      lentDate: lent,
      repaymentType: LoanRepaymentType.monthly,
      installmentMinor: 100000,
      originalInstallmentMinor: 100000,
      originalTermMonths: 3,
      firstDueDate: first,
      dueDay: first.day,
      householdId: householdId,
      createdBy: createdBy,
      createdByName: createdBy == null ? null : 'Alex',
      schedule: LoanCalculator.buildSchedule(
        loanId: id,
        type: LoanRepaymentType.monthly,
        principalMinor: 300000,
        newId: () => '$id-${++n}',
        installmentMinor: 100000,
        firstDueDate: first,
        dueDay: first.day,
      ),
      createdAt: lent,
      updatedAt: lent,
    );
  }

  testWidgets('lend money monthly: schedule, balance and repayments', (
    tester,
  ) async {
    final app = TestHarness(
      withLoans: true,
      transactions: [
        tx(
          id: 'salary',
          amountMinor: 2000000,
          date: today,
          type: TransactionType.income,
          categoryId: 'inc_salary',
        ),
      ],
    );
    await app.pump(tester);
    expect(textOf(tester, 'balanceText'), 'AED 20,000.00');
    expect(find.byKey(const Key('lendingOverviewCard')), findsNothing);

    await openLending(tester);
    expect(find.text('No money lent yet'), findsOneWidget);
    await tester.tap(find.byKey(const Key('lendMoneyButton')));
    await tester.pumpAndSettle();
    expect(find.text('Lend money'), findsWidgets);

    // Validation.
    await tapVisible(tester, find.byKey(const Key('saveLoanButton')));
    expect(find.text("Please enter the borrower's name"), findsOneWidget);
    expect(find.text('Please enter an amount'), findsWidgets);

    await tester.enterText(find.byKey(const Key('borrowerNameField')), 'John');
    await tester.enterText(find.byKey(const Key('loanAmountField')), '12000');
    // Switching the repayment type shows the matching fields.
    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('repaymentTypeSelector')),
        matching: find.text('One-time'),
      ),
    );
    expect(find.byKey(const Key('dueDateField')), findsOneWidget);
    expect(find.byKey(const Key('installmentField')), findsNothing);
    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('repaymentTypeSelector')),
        matching: find.text('Monthly (EMI)'),
      ),
    );
    expect(find.byKey(const Key('installmentField')), findsOneWidget);
    expect(find.byKey(const Key('dueDateField')), findsNothing);
    await tester.enterText(find.byKey(const Key('installmentField')), '1000');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('loanPreview')),
              matching: find.byType(Text),
            ),
          )
          .data,
      startsWith('12 monthly instalments'),
    );
    await tapVisible(tester, find.byKey(const Key('saveLoanButton')));

    // Back on the overview with the new record.
    final loan = app.loans!.loans.values.single;
    expect(loan.schedule, hasLength(12));
    expect(loan.isPersonal, isTrue);
    expect(find.byKey(Key('loanTile-${loan.id}')), findsOneWidget);
    expect(find.byKey(const Key('statTotalLent')), findsOneWidget);

    // Details.
    await tapVisible(tester, find.byKey(Key('loanTile-${loan.id}')));
    expect(find.byType(LoanDetailsScreen), findsOneWidget);
    expect(textOf(tester, 'loanOutstandingText'), 'AED 12,000.00');
    expect(find.byType(InstallmentTile), findsNWidgets(6));
    await tapVisible(tester, find.byKey(const Key('showAllInstallments')));
    expect(find.byType(InstallmentTile), findsNWidgets(12));

    // A partial repayment.
    await tester.tap(find.byKey(const Key('recordRepaymentButton')));
    await tester.pumpAndSettle();
    expect(find.text('Outstanding: AED 12,000.00'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('repaymentAmountField')),
      '400',
    );
    await tapVisible(tester, find.byKey(const Key('saveRepaymentButton')));
    expect(await outstanding(tester), 'AED 11,600.00');
    expect(find.text('Partially paid'), findsWidgets);
    expect(app.loans!.repayments, hasLength(1));
    await scrollTo(tester, find.byKey(const Key('repaymentHistory')));
    expect(find.byType(RepaymentTile), findsOneWidget);

    // More than outstanding is refused in the form.
    await tester.tap(find.byKey(const Key('recordRepaymentButton')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('repaymentAmountField')),
      '20000',
    );
    await tapVisible(tester, find.byKey(const Key('saveRepaymentButton')));
    expect(find.text('No more than AED 11,600.00'), findsOneWidget);

    // The full rest.
    await tapVisible(tester, find.byKey(const Key('repaymentFullChip')));
    await tapVisible(tester, find.byKey(const Key('saveRepaymentButton')));
    expect(await outstanding(tester), 'AED 0.00');
    expect(find.text('Completed'), findsWidgets);
    expect(find.byKey(const Key('recordRepaymentButton')), findsNothing);
    expect(app.loans!.repayments, hasLength(2));

    // The dashboard: everything is back; nothing counted as income.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await openTab(tester, 'Dashboard');
    expect(textOf(tester, 'balanceText'), 'AED 20,000.00');
    expect(app.transactions.items, hasLength(1));
  });

  testWidgets('choosing a number of months calculates the monthly amount', (
    tester,
  ) async {
    final app = TestHarness(withLoans: true);
    await app.pump(tester);
    await openLending(tester);
    await tester.tap(find.byKey(const Key('lendMoneyButton')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('borrowerNameField')), 'Mia');
    await tester.enterText(find.byKey(const Key('loanAmountField')), '12000');
    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('monthlyModeSelector')),
        matching: find.text('Number of months'),
      ),
    );
    expect(find.byKey(const Key('installmentField')), findsNothing);
    await tester.enterText(find.byKey(const Key('monthsField')), '6');
    await tester.pumpAndSettle();
    final preview = tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('loanPreview')),
            matching: find.byType(Text),
          ),
        )
        .data!;
    expect(preview, startsWith('AED 2,000.00 per month for 6 months.'));
    await tapVisible(tester, find.byKey(const Key('saveLoanButton')));
    final loan = app.loans!.loans.values.single;
    expect(loan.installmentMinor, 200000);
    expect(loan.schedule, hasLength(6));
  });

  testWidgets('an extra payment shows how it reduces capital and the EMI', (
    tester,
  ) async {
    final app = TestHarness(withLoans: true);
    // AED 3,000 at AED 1,000 a month, first EMI in 10 days.
    final loan = seededLoan(firstDueInDays: 10);
    app.loans!.loans[loan.id] = loan;
    await app.pump(tester);
    await openLending(tester);
    await tapVisible(tester, find.byKey(Key('loanTile-${loan.id}')));

    await tester.tap(find.byKey(const Key('recordRepaymentButton')));
    await tester.pumpAndSettle();
    // The scheduled EMI alone: nothing to explain.
    expect(find.byKey(const Key('extraPaymentPanel')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('repaymentAmountField')),
      '1500',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('extraPaymentPanel')), findsOneWidget);
    expect(textOf(tester, 'extraToCapitalText'), 'AED 500.00');
    // 3,000 − 1,000 − 500 = 1,500 over the 2 months left.
    expect(textOf(tester, 'revisedEmiText'), 'AED 1,000.00 → AED 750.00');
    expect(
      find.text('The extra reduces the capital and lowers the remaining EMIs'),
      findsOneWidget,
    );
    await tapVisible(tester, find.byKey(const Key('saveRepaymentButton')));

    final repayment = app.loans!.repayments.values.single;
    expect(repayment.allocation!.extraPrincipalMinor, 50000);
    expect(repayment.allocation!.revisedEmiMinor, 75000);
    await scrollTo(tester, find.byKey(const Key('emiHistory')));
    expect(find.textContaining('AED 1,000.00 → AED 750.00'), findsWidgets);
    expect(find.text('Agreed: AED 1,000.00 × 3 months'), findsOneWidget);
  });

  testWidgets('money lent stays out of the balance and month income', (
    tester,
  ) async {
    final app = TestHarness(
      withLoans: true,
      transactions: [
        tx(
          id: 'salary',
          amountMinor: 2000000,
          date: today,
          type: TransactionType.income,
          categoryId: 'inc_salary',
        ),
      ],
    );
    final loan = seededLoan(firstDueInDays: 10);
    app.loans!.loans[loan.id] = loan;
    await app.pump(tester);
    // The balance card is income minus expenses only, with no lending.
    expect(find.text('Total balance'), findsOneWidget);
    expect(textOf(tester, 'balanceText'), 'AED 20,000.00');
    expect(find.byKey(const Key('balanceLentText')), findsNothing);
    expect(find.text('AED 20,000.00'), findsWidgets);
    // Lending has its own card.
    final card = find.byKey(const Key('lendingOverviewCard'));
    await tester.ensureVisible(card);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: card, matching: find.text('AED 3,000.00')),
      findsOneWidget,
    );
  });

  testWidgets('a reminder tap opens the instalment; nothing is recorded '
      'until the user saves', (tester) async {
    final local = RecordingLocalNotifier();
    final app = TestHarness(withLoans: true, localNotifier: local);
    final loan = seededLoan(firstDueInDays: -3); // first EMI overdue
    app.loans!.loans[loan.id] = loan;
    await app.pump(tester);

    local.tap(
      AppNotification(
        title: 'Repayment overdue',
        body: 'John still owes …',
        channel: NotificationChannel.loanReminders,
        data: {
          'type': 'loan_reminder',
          'loanId': loan.id,
          'installmentId': loan.schedule.first.id,
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoanDetailsScreen), findsOneWidget);
    expect(find.byKey(const Key('reminderBanner')), findsOneWidget);
    expect(find.textContaining('Overdue'), findsWidgets);
    expect(app.loans!.repayments, isEmpty);

    await tapVisible(tester, find.byKey(const Key('bannerRecordInstallment')));
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const Key('repaymentAmountField')),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      '1000.00',
    );
    // Closed without saving: still nothing recorded.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(app.loans!.repayments, isEmpty);
  });

  testWidgets('household lending: filters and owner-chosen recipients', (
    tester,
  ) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    await households.createHousehold('Khan family');
    households.members = [
      ...households.members,
      const HouseholdMember(
        uid: 'partner',
        role: HouseholdRole.member,
        status: MembershipStatus.active,
        displayName: 'Alex',
      ),
    ];
    final app = TestHarness(withLoans: true, households: households);
    await app.pump(tester);

    await openLending(tester);
    await tester.tap(find.byKey(const Key('lendMoneyButton')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('loanScopeSelector')),
        matching: find.text('Household'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('borrowerNameField')), 'Omar');
    await tester.enterText(find.byKey(const Key('loanAmountField')), '500');
    await tapVisible(
      tester,
      find.descendant(
        of: find.byKey(const Key('repaymentTypeSelector')),
        matching: find.text('One-time'),
      ),
    );
    await tapVisible(tester, find.byKey(const Key('saveLoanButton')));
    final loan = app.loans!.loans.values.single;
    expect(loan.householdId, 'house-1');
    // The owner is reminded by default; nobody else.
    expect(app.loans!.reminders[loan.id]!.notifyUids, [testUser.uid]);

    // Filters.
    await tester.tap(find.byKey(const Key('loanFilter-personal')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('loanTile-${loan.id}')), findsNothing);
    await tester.tap(find.byKey(const Key('loanFilter-household')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('loanTile-${loan.id}')), findsOneWidget);

    // The owner adds the partner as a recipient.
    await tapVisible(tester, find.byKey(Key('loanTile-${loan.id}')));
    await tester.tap(find.byKey(const Key('loanActionsMenu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reminder settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remindersReadOnlyNote')), findsNothing);
    await scrollTo(tester, find.byKey(const Key('recipient-partner')));
    expect(find.text('Sam Lee (you)'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('recipient-partner')));
    await tapVisible(tester, find.byKey(const Key('saveRemindersButton')));
    expect(app.loans!.reminders[loan.id]!.notifyUids, [
      'partner',
      testUser.uid,
    ]);
  });

  testWidgets('household members see reminder recipients read-only', (
    tester,
  ) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    await households.createHousehold('Khan family');
    households.household = const Household(
      id: 'house-1',
      name: 'Khan family',
      ownerUid: 'partner',
    );
    households.members = const [
      HouseholdMember(
        uid: 'partner',
        role: HouseholdRole.owner,
        status: MembershipStatus.active,
        displayName: 'Alex',
      ),
      HouseholdMember(
        uid: 'uid-1',
        role: HouseholdRole.member,
        status: MembershipStatus.active,
        displayName: 'Sam Lee',
      ),
    ];
    final app = TestHarness(withLoans: true, households: households);
    final loan = seededLoan(householdId: 'house-1', createdBy: 'partner');
    app.loans!.loans[loan.id] = loan;
    app.loans!.reminders[loan.id] = LoanReminderSettings(
      loanId: loan.id,
      notifyUids: const ['partner'],
      updatedAt: loan.createdAt,
    );
    await app.pump(tester);

    await openLending(tester);
    await tapVisible(tester, find.byKey(Key('loanTile-${loan.id}')));
    await tester.tap(find.byKey(const Key('loanActionsMenu')));
    await tester.pumpAndSettle();
    // A member may record repayments and edit, but not delete someone
    // else's record or pause the owner's reminders.
    expect(find.text('Delete'), findsNothing);
    expect(find.text('Pause reminders'), findsNothing);
    await tester.tap(find.text('Reminder settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('remindersReadOnlyNote')), findsOneWidget);
    await scrollTo(tester, find.byKey(const Key('recipient-uid-1')));
    expect(find.byKey(const Key('saveRemindersButton')), findsNothing);
    final me = tester.widget<CheckboxListTile>(
      find.byKey(const Key('recipient-uid-1')),
    );
    expect(me.value, isFalse);
    expect(me.onChanged, isNull);
  });
}
