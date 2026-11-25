import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/loan_reminder_planner.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/repositories/loan_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_notifications.dart';

void main() {
  sqfliteFfiInit();

  var now = DateTime(2026, 11, 20, 10);
  late AppDatabase db;
  late SqliteLoanRepository repo;
  late RecordingLocalNotifier notifier;
  late LoanProvider provider;

  LoanProvider newProvider() => LoanProvider(
    repo,
    notifier: notifier,
    clock: () => now,
    reminderDebounce: Duration.zero,
  );

  setUp(() async {
    now = DateTime(2026, 11, 20, 10);
    db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
    repo = SqliteLoanRepository(db);
    notifier = RecordingLocalNotifier();
    provider = newProvider();
    await provider.setContextForTesting(uid: 'me', name: 'Me');
  });

  tearDown(() async {
    provider.dispose();
    await db.close();
  });

  Future<LoanSnapshot> emi({
    int principal = 1200000,
    int installment = 100000,
    int rateBp = 0,
    bool household = false,
  }) async {
    final loan = await provider.createLoan(
      borrowerName: ' John ',
      borrowerPhone: '+971 50 123 4567',
      principalMinor: principal,
      lentDate: DateTime(2026, 11, 1),
      repaymentType: LoanRepaymentType.monthly,
      interestRateBp: rateBp,
      installmentMinor: installment,
      firstDueDate: DateTime(2026, 12, 1),
      household: household,
    );
    return provider.snapshotById(loan.id)!;
  }

  Future<LoanSnapshot> once({int principal = 500000, DateTime? due}) async {
    final loan = await provider.createLoan(
      borrowerName: 'Sara',
      principalMinor: principal,
      lentDate: DateTime(2026, 11, 1),
      repaymentType: LoanRepaymentType.oneTime,
      dueDate: due ?? DateTime(2026, 12, 10),
    );
    return provider.snapshotById(loan.id)!;
  }

  group('creating', () {
    test('a monthly loan gets its schedule and default reminders', () async {
      final s = await emi();
      expect(s.loan.borrowerName, 'John');
      expect(s.loan.schedule, hasLength(12));
      expect(s.loan.createdBy, 'me');
      expect(s.outstandingMinor, 1200000);
      expect(provider.reminderSettingsOf(s.id).offsets, [-3, 0, 1, 3, 7]);
      expect(provider.localChangeVersion, 1);
    });

    test('invalid input is refused with a message', () async {
      Future<void> bad({
        String name = 'John',
        int principal = 1000,
        DateTime? lent,
        int? installment = 100,
        DateTime? firstDue,
        String phone = '',
        String email = '',
        int rate = 0,
      }) => provider.createLoan(
        borrowerName: name,
        borrowerPhone: phone,
        borrowerEmail: email,
        principalMinor: principal,
        lentDate: lent ?? DateTime(2026, 11, 1),
        repaymentType: LoanRepaymentType.monthly,
        installmentMinor: installment,
        interestRateBp: rate,
        firstDueDate: firstDue ?? DateTime(2026, 12, 1),
      );
      final cases = <Future<void> Function()>[
        () => bad(name: '  '),
        () => bad(principal: 0),
        () => bad(principal: -5),
        () => bad(lent: DateTime(2026, 12, 1)),
        () => bad(installment: 0),
        () => bad(firstDue: DateTime(2026, 10, 1)),
        () => bad(phone: 'abc'),
        () => bad(email: 'nope'),
        () => bad(rate: 20000),
      ];
      for (final c in cases) {
        await expectLater(c(), throwsA(isA<LoanException>()));
      }
      expect(provider.loans, isEmpty);
      expect(provider.localChangeVersion, 0);
    });

    test('household lending needs a household', () async {
      await expectLater(emi(household: true), throwsA(isA<LoanException>()));
    });
  });

  group('repayments', () {
    test('partial, then full repayment completes the loan', () async {
      final s = await once();
      await provider.recordRepayment(
        s,
        amountMinor: 200000,
        date: DateTime(2026, 11, 10),
        method: PaymentMethod.bankTransfer,
      );
      var now1 = provider.snapshotById(s.id)!;
      expect(now1.outstandingMinor, 300000);
      expect(now1.installments.single.status, InstallmentStatus.partiallyPaid);
      await provider.recordRepayment(
        now1,
        amountMinor: 300000,
        date: DateTime(2026, 11, 20),
      );
      now1 = provider.snapshotById(s.id)!;
      expect(now1.isCompleted, isTrue);
      expect(provider.repaymentsOf(s.id), hasLength(2));
      expect(
        provider.repaymentsOf(s.id).last.method,
        PaymentMethod.bankTransfer,
      );
      await expectLater(
        provider.recordRepayment(
          now1,
          amountMinor: 1,
          date: DateTime(2026, 11, 20),
        ),
        throwsA(isA<LoanException>()),
      );
    });

    test(
      'more than outstanding, future dates and dates before lending fail',
      () async {
        final s = await once();
        for (final c in [
          () => provider.recordRepayment(
            s,
            amountMinor: 500001,
            date: DateTime(2026, 11, 10),
          ),
          () => provider.recordRepayment(
            s,
            amountMinor: 100,
            date: DateTime(2026, 11, 21),
          ),
          () => provider.recordRepayment(
            s,
            amountMinor: 100,
            date: DateTime(2026, 10, 31),
          ),
          () => provider.recordRepayment(
            s,
            amountMinor: 0,
            date: DateTime(2026, 11, 10),
          ),
        ]) {
          await expectLater(c(), throwsA(isA<LoanException>()));
        }
        expect(provider.repaymentsOf(s.id), isEmpty);
      },
    );

    test(
      'voiding without a cloud keeps the record but stops it counting',
      () async {
        final s = await once();
        final r = await provider.recordRepayment(
          s,
          amountMinor: 100000,
          date: DateTime(2026, 11, 10),
        );
        await provider.voidRepayment(r, reason: 'Wrong loan');
        final after = provider.snapshotById(s.id)!;
        expect(after.receivedMinor, 0);
        final history = provider.repaymentsOf(s.id).single;
        expect(history.voided, isTrue);
        expect(history.voidedBy, 'me');
        expect(history.voidReason, 'Wrong loan');
      },
    );
  });

  group('editing and rescheduling', () {
    test('changing the instalment keeps paid ones and the history', () async {
      final s = await emi();
      await provider.recordRepayment(
        s,
        amountMinor: 150000,
        date: DateTime(2026, 11, 15),
      );
      final paid = provider.snapshotById(s.id)!;
      await provider.updateLoan(
        paid,
        borrowerName: 'John',
        principalMinor: 1200000,
        lentDate: DateTime(2026, 11, 1),
        repaymentType: LoanRepaymentType.monthly,
        installmentMinor: 200000,
        firstDueDate: DateTime(2026, 12, 1),
        dueDay: 1,
      );
      final edited = provider.snapshotById(s.id)!;
      // Instalment 1 (paid, with 500 extra capital) keeps its ID and amount;
      // the extra is now part of it (the repayment's record still shows it).
      expect(edited.loan.schedule.first.id, paid.loan.schedule.first.id);
      expect(edited.loan.schedule.first.expectedMinor, 150000);
      expect(edited.loan.schedule.first.principalMinor, 150000);
      expect(
        provider.repaymentsOf(s.id).single.allocation!.extraPrincipalMinor,
        50000,
      );
      // 1,200,000 − 150,000 kept = 1,050,000 → five of 200,000 and 50,000
      // from January.
      final rest = edited.loan.schedule.skip(1).toList();
      expect(rest.map((i) => i.expectedMinor), [
        ...List.filled(5, 200000),
        50000,
      ]);
      expect(rest.first.dueDate, DateTime(2027, 1, 1));
      expect(edited.receivedMinor, 150000);
      expect(edited.currentEmiMinor, 200000);
      expect(provider.repaymentsOf(s.id), hasLength(1));
    });

    test('the total cannot drop below what was repaid', () async {
      final s = await emi();
      await provider.recordRepayment(
        s,
        amountMinor: 500000,
        date: DateTime(2026, 11, 15),
      );
      await expectLater(
        provider.updateLoan(
          provider.snapshotById(s.id)!,
          borrowerName: 'John',
          principalMinor: 400000,
          lentDate: DateTime(2026, 11, 1),
          repaymentType: LoanRepaymentType.monthly,
          installmentMinor: 100000,
          firstDueDate: DateTime(2026, 12, 1),
        ),
        throwsA(isA<LoanException>()),
      );
    });

    test('a number of months sets the monthly amount', () async {
      final loan = await provider.createLoan(
        borrowerName: 'John',
        principalMinor: 1200000,
        lentDate: DateTime(2026, 11, 1),
        repaymentType: LoanRepaymentType.monthly,
        interestRateBp: 1200,
        firstDueDate: DateTime(2026, 12, 1),
        months: 12,
      );
      expect(loan.installmentMinor, 112000);
      expect(loan.interestMinor, 144000);
      expect(loan.schedule, hasLength(12));
      expect(loan.schedule.every((i) => i.expectedMinor == 112000), isTrue);

      // Editing to 6 months keeps the history and recalculates the rest.
      final snapshot = provider.snapshotById(loan.id)!;
      await provider.updateLoan(
        snapshot,
        borrowerName: 'John',
        principalMinor: 1200000,
        lentDate: DateTime(2026, 11, 1),
        repaymentType: LoanRepaymentType.monthly,
        interestRateBp: 1200,
        firstDueDate: DateTime(2026, 12, 1),
        dueDay: 1,
        months: 6,
      );
      final edited = provider.snapshotById(loan.id)!.loan;
      expect(edited.interestMinor, 72000);
      expect(edited.installmentMinor, 212000);
      expect(edited.schedule, hasLength(6));
    });

    test('rescheduling over a number of months spreads the rest', () async {
      final s = await emi();
      await provider.recordRepayment(
        s,
        amountMinor: 100000,
        date: DateTime(2026, 11, 15),
      );
      final paid = provider.snapshotById(s.id)!;
      expect(provider.monthlyAmountForRest(paid, 4), 275000);
      await provider.reschedule(
        paid,
        months: 4,
        nextDueDate: DateTime(2027, 1, 1),
        dueDay: 1,
      );
      final r = provider.snapshotById(s.id)!;
      // The paid instalment, then 11,000 over four months.
      expect(r.loan.schedule, hasLength(5));
      expect(r.loan.schedule.skip(1).map((i) => i.expectedMinor), [
        275000,
        275000,
        275000,
        275000,
      ]);
      expect(r.loan.installmentMinor, 275000);
      expect(
        () => provider.monthlyAmountForRest(r, 0),
        throwsA(isA<LoanException>()),
      );
    });

    test('rescheduling moves only the unpaid instalments', () async {
      final s = await emi();
      await provider.recordRepayment(
        s,
        amountMinor: 100000,
        date: DateTime(2026, 11, 15),
      );
      await provider.reschedule(
        provider.snapshotById(s.id)!,
        installmentMinor: 50000,
        nextDueDate: DateTime(2027, 1, 31),
        dueDay: 31,
      );
      final r = provider.snapshotById(s.id)!;
      expect(r.loan.schedule.first.dueDate, DateTime(2026, 12, 1));
      expect(r.loan.schedule.first.expectedMinor, 100000);
      expect(r.loan.schedule, hasLength(1 + 22));
      expect(r.loan.schedule[1].dueDate, DateTime(2027, 1, 31));
      expect(r.loan.schedule[2].dueDate, DateTime(2027, 2, 28));
      expect(r.loan.installmentMinor, 50000);
      expect(r.outstandingMinor, 1100000);
    });

    test('a one-time loan can get a new expected date', () async {
      final s = await once();
      await provider.reschedule(s, dueDate: DateTime(2027, 3, 1));
      final r = provider.snapshotById(s.id)!;
      expect(r.loan.dueDate, DateTime(2027, 3, 1));
      expect(r.loan.schedule.single.dueDate, DateTime(2027, 3, 1));
    });
  });

  group('accounting', () {
    test(
      'lending figures: unpaid principal and interest received, per scope',
      () async {
        // 10,000 lent at 10% for a year: 11,000 owed.
        final loan = await provider.createLoan(
          borrowerName: 'Ali',
          principalMinor: 1000000,
          lentDate: DateTime(2025, 11, 20),
          repaymentType: LoanRepaymentType.oneTime,
          interestRateBp: 1000,
          dueDate: DateTime(2026, 11, 20),
        );
        const scope = ScopeFilter.personal();
        expect(provider.lentOutstandingForScope(scope), 1000000);
        expect(provider.interestForScope(scope), 0);
        await provider.recordRepayment(
          provider.snapshotById(loan.id)!,
          amountMinor: 550000,
          date: DateTime(2026, 11, 20),
        );
        // Interest is paid first within the instalment: 1,000 interest,
        // 4,500 principal.
        expect(provider.lentOutstandingForScope(scope), 550000);
        expect(provider.interestForScope(scope), 100000);
        // Household figures are unaffected by personal lending.
        expect(
          provider.lentOutstandingForScope(const ScopeFilter.shared('h')),
          0,
        );
      },
    );
  });

  group('extra capital repayments', () {
    test('the repayment keeps how it was applied, for the record', () async {
      final s = await emi();
      final r = await provider.recordRepayment(
        s,
        amountMinor: 150000,
        date: DateTime(2026, 11, 20),
      );
      final a = provider.repaymentById(r.id)!.allocation!;
      expect(a.scheduledEmiMinor, 100000);
      expect(a.appliedToInstallmentMinor, 100000);
      expect(a.extraPrincipalMinor, 50000);
      expect(a.principalBeforeMinor, 1200000);
      expect(a.principalAfterMinor, 1050000);
      expect(a.previousEmiMinor, 100000);
      expect(a.revisedEmiMinor, 95455);
      expect(a.remainingInstallments, 11);
      expect(a.effectiveFrom, DateTime(2027, 1, 1));
      expect(a.recalculatedAt, now);
      final after = provider.snapshotById(s.id)!;
      expect(after.currentEmiMinor, 95455);
      expect(after.loan.originalInstallmentMinor, 100000);
      // The preview shows the same treatment before saving.
      final preview = provider.previewRepayment(
        after,
        amountMinor: 95455 + 10000,
      );
      expect(preview.extraPrincipalMinor, 10000);
      expect(preview.installmentNumber, 2);
    });

    test('nothing above the settlement amount can be recorded', () async {
      final s = await emi(rateBp: 1200, installment: 112000);
      final max = provider.maxRepaymentMinor(s);
      // Settling now: this EMI plus the capital after it, not the future
      // interest.
      expect(max, lessThan(s.outstandingMinor));
      await expectLater(
        provider.recordRepayment(
          s,
          amountMinor: max + 1,
          date: DateTime(2026, 11, 20),
        ),
        throwsA(isA<LoanException>()),
      );
      await provider.recordRepayment(
        s,
        amountMinor: max,
        date: DateTime(2026, 11, 20),
      );
      expect(provider.snapshotById(s.id)!.isCompleted, isTrue);
    });

    test('reminders switch to the revised EMI', () async {
      final s = await emi();
      await provider.syncReminders();
      final before = Map.of(notifier.scheduled);
      expect(
        before.values.map((n) => n.notification.body).join(),
        contains('AED 1,000.00'),
      );
      await provider.recordRepayment(
        s,
        amountMinor: 150000,
        date: DateTime(2026, 11, 20),
      );
      await provider.syncReminders();
      // The same instalments, so the same IDs: replaced, not duplicated.
      final firstId = s.installments.first.id;
      expect(
        notifier.scheduled.values.where(
          (n) => n.notification.data['installmentId'] == firstId,
        ),
        isEmpty,
      );
      final bodies = notifier.scheduled.values
          .map((n) => n.notification.body)
          .toList();
      expect(bodies, isNotEmpty);
      expect(bodies.every((b) => b.contains('AED 954.55')), isTrue);
      expect(
        notifier.scheduled.keys.toSet().difference(before.keys.toSet()),
        isEmpty,
      );
    });
  });

  group('reminders', () {
    Set<int> ids() => notifier.scheduled.keys.toSet();

    test('scheduled for unpaid instalments under stable IDs', () async {
      final s = await once(due: DateTime(2026, 12, 10));
      await provider.syncReminders();
      expect(notifier.scheduled, hasLength(5));
      final first = notifier.scheduled.values.first;
      expect(first.notification.channel, NotificationChannel.loanReminders);
      expect(first.notification.data['loanId'], s.id);
      expect(
        ids(),
        contains(
          LoanReminderPlanner.stableId(
            s.id,
            s.installments.single.id,
            'me',
            -3,
          ),
        ),
      );
    });

    test(
      'a partial payment updates the text; full payment cancels all',
      () async {
        final s = await once(due: DateTime(2026, 12, 10));
        await provider.syncReminders();
        await provider.recordRepayment(
          s,
          amountMinor: 200000,
          date: DateTime(2026, 11, 20),
        );
        await provider.syncReminders();
        expect(notifier.scheduled, hasLength(5));
        expect(
          notifier.scheduled.values.first.notification.body,
          contains('AED 3,000.00 left'),
        );
        await provider.recordRepayment(
          provider.snapshotById(s.id)!,
          amountMinor: 300000,
          date: DateTime(2026, 11, 20),
        );
        await provider.syncReminders();
        expect(notifier.scheduled, isEmpty);
      },
    );

    test('pausing cancels, resuming schedules again', () async {
      final s = await once();
      await provider.syncReminders();
      await provider.pauseReminders(s.loan);
      await provider.syncReminders();
      expect(notifier.scheduled, isEmpty);
      await provider.resumeReminders(s.loan);
      await provider.syncReminders();
      expect(notifier.scheduled, hasLength(5));
    });

    test('deleting a loan cancels its reminders', () async {
      final s = await once();
      await provider.syncReminders();
      await provider.deleteLoan(s.loan);
      await provider.syncReminders();
      expect(notifier.scheduled, isEmpty);
    });

    test('a restart schedules the same reminders without duplicates', () async {
      await once();
      await provider.syncReminders();
      final before = Map.of(notifier.scheduled);
      provider.dispose();
      provider = newProvider();
      await provider.setContextForTesting(uid: 'me', name: 'Me');
      await provider.syncReminders();
      expect(notifier.scheduled.keys.toSet(), before.keys.toSet());
      expect(notifier.scheduled, hasLength(5));
    });

    test(
      'planning again after the time moves on drops past reminders',
      () async {
        await once(due: DateTime(2026, 12, 10));
        await provider.syncReminders();
        expect(notifier.scheduled, hasLength(5));
        now = DateTime(2026, 12, 11, 12);
        provider.refreshForNow();
        await provider.syncReminders();
        // Only the 3- and 7-days-after reminders are still ahead.
        expect(notifier.scheduled, hasLength(2));
      },
    );

    test('no reminders when notifications are denied or signed out', () async {
      await once();
      await provider.setContextForTesting(
        uid: 'me',
        name: 'Me',
        notificationsAllowed: false,
      );
      await provider.syncReminders();
      expect(notifier.scheduled, isEmpty);
      await provider.setContextForTesting(uid: 'me', name: 'Me');
      await provider.syncReminders();
      expect(notifier.scheduled, isNotEmpty);
      await provider.setContextForTesting();
      await provider.syncReminders();
      expect(notifier.scheduled, isEmpty);
    });
  });

  group('household permissions', () {
    const owner = ReminderMember(uid: 'owner', name: 'Owner', isOwner: true);
    const me = ReminderMember(uid: 'me', name: 'Me', isOwner: false);

    test('members cannot change recipients; the owner can', () async {
      await provider.setContextForTesting(
        uid: 'me',
        name: 'Me',
        householdId: 'h',
        householdOwnerUid: 'owner',
        members: const [owner, me],
      );
      final s = await emi(household: true);
      expect(provider.reminderSettingsOf(s.id).notifyUids, ['owner']);
      expect(provider.canEditReminders(s.loan), isFalse);
      expect(provider.canDelete(s.loan), isTrue); // recorded it
      await expectLater(
        provider.saveReminderSettings(
          s.loan,
          enabled: true,
          paused: false,
          offsets: const [0],
          notifyUids: const ['me'],
        ),
        throwsA(isA<LoanException>()),
      );
      await expectLater(
        provider.pauseReminders(s.loan),
        throwsA(isA<LoanException>()),
      );
      // Not selected: this member's phone shows nothing.
      await provider.syncReminders();
      expect(notifier.scheduled, isEmpty);

      // The owner (on the same data) selects this member.
      await provider.setContextForTesting(
        uid: 'owner',
        name: 'Owner',
        householdId: 'h',
        householdOwnerUid: 'owner',
        isHouseholdOwner: true,
        members: const [owner, me],
      );
      await expectLater(
        provider.saveReminderSettings(
          s.loan,
          enabled: true,
          paused: false,
          offsets: const [0],
          notifyUids: const ['stranger'],
        ),
        throwsA(isA<LoanException>()),
      );
      await provider.saveReminderSettings(
        s.loan,
        enabled: true,
        paused: false,
        offsets: const [0],
        notifyUids: const ['me'],
      );
      await provider.setContextForTesting(
        uid: 'me',
        name: 'Me',
        householdId: 'h',
        householdOwnerUid: 'owner',
        members: const [owner, me],
      );
      await provider.syncReminders();
      expect(notifier.scheduled, isNotEmpty);
    });

    test('members cannot delete loans recorded by someone else', () async {
      await provider.setContextForTesting(
        uid: 'owner',
        name: 'Owner',
        householdId: 'h',
        householdOwnerUid: 'owner',
        isHouseholdOwner: true,
        members: const [owner, me],
      );
      final s = await emi(household: true);
      await provider.setContextForTesting(
        uid: 'me',
        name: 'Me',
        householdId: 'h',
        householdOwnerUid: 'owner',
        members: const [owner, me],
      );
      expect(provider.canDelete(s.loan), isFalse);
      await expectLater(
        provider.deleteLoan(s.loan),
        throwsA(isA<LoanException>()),
      );
      // Recording repayments is open to every member.
      await provider.recordRepayment(
        provider.snapshotById(s.id)!,
        amountMinor: 1000,
        date: DateTime(2026, 11, 20),
      );
      expect(provider.snapshotById(s.id)!.receivedMinor, 1000);
    });
  });

  test(
    'filters split personal, household, active, overdue and completed',
    () async {
      await provider.setContextForTesting(
        uid: 'me',
        name: 'Me',
        householdId: 'h',
        householdOwnerUid: 'me',
        isHouseholdOwner: true,
      );
      await emi(household: true);
      final done = await once(principal: 1000);
      await provider.recordRepayment(
        done,
        amountMinor: 1000,
        date: DateTime(2026, 11, 20),
      );
      await once(due: DateTime(2026, 11, 5)); // overdue
      expect(provider.filtered(LoanFilter.all), hasLength(3));
      expect(provider.filtered(LoanFilter.household), hasLength(1));
      expect(provider.filtered(LoanFilter.personal), hasLength(2));
      expect(provider.filtered(LoanFilter.completed), hasLength(1));
      expect(provider.filtered(LoanFilter.active), hasLength(2));
      expect(provider.filtered(LoanFilter.overdue), hasLength(1));
      expect(provider.overdue(LoanFilter.all), hasLength(1));
      expect(provider.summaryOf(LoanFilter.all).overdueCount, 1);
    },
  );
}
