import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/repositories/loan_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_cloud_store.dart';
import '../helpers/fake_loans.dart';
import '../helpers/fake_notifications.dart';

const hid = 'house-1';

/// One phone: its own database, sync service and provider, sharing the
/// cloud with the others.
class Device {
  Device._(
    this.uid,
    this.db,
    this.repo,
    this.sync,
    this.provider,
    this.notifier,
  );

  static Future<Device> open(
    String uid,
    String path,
    InMemoryCloudStore cloud,
    InMemoryLoanCloud loanCloud, {
    String? householdId,
    required DateTime Function() clock,
  }) async {
    final db = await AppDatabase.openAtPath(databaseFactoryFfiNoIsolate, path);
    final repo = SqliteLoanRepository(db);
    final sync = TransactionSyncService(
      local: SqliteLocalSyncStore(db),
      cloud: cloud,
      loansLocal: repo,
      loansCloud: loanCloud,
      clock: clock,
    );
    final notifier = RecordingLocalNotifier();
    final provider = LoanProvider(
      repo,
      cloud: loanCloud,
      notifier: notifier,
      clock: clock,
      reminderDebounce: Duration.zero,
    );
    final owner = householdId == null
        ? null
        : loanCloud.householdOwners[householdId];
    await provider.setContextForTesting(
      uid: uid,
      name: 'User $uid',
      householdId: householdId,
      householdOwnerUid: owner,
      isHouseholdOwner: owner == uid,
      members: [
        for (final m in loanCloud.householdMembers[householdId] ?? <String>{})
          ReminderMember(uid: m, name: 'User $m', isOwner: m == owner),
      ],
    );
    final device = Device._(uid, db, repo, sync, provider, notifier)
      ..householdId = householdId;
    return device;
  }

  final String uid;
  final AppDatabase db;
  final SqliteLoanRepository repo;
  final TransactionSyncService sync;
  final LoanProvider provider;
  final RecordingLocalNotifier notifier;
  String? householdId;

  Future<SyncResult> syncNow() async {
    final result = await sync.synchronize(uid, householdId: householdId);
    await provider.load();
    return result;
  }

  LoanSnapshot only() => provider.loans.single;
}

void main() {
  sqfliteFfiInit();

  late InMemoryCloudStore cloud;
  late InMemoryLoanCloud loanCloud;
  late Directory dir;
  final opened = <Device>[];
  var now = DateTime(2026, 11, 20, 10);
  DateTime clock() => now;

  setUp(() async {
    now = DateTime(2026, 11, 20, 10);
    cloud = InMemoryCloudStore();
    loanCloud = InMemoryLoanCloud()
      ..householdOwners[hid] = 'a'
      ..householdMembers[hid] = {'a', 'b'};
    dir = await Directory.systemTemp.createTemp('money_mate_loan_sync');
  });

  tearDown(() async {
    for (final d in opened) {
      d.provider.dispose();
      await d.db.close();
    }
    opened.clear();
    await dir.delete(recursive: true);
  });

  Future<Device> device(String uid, {String? householdId, String? name}) async {
    final d = await Device.open(
      uid,
      p.join(dir.path, '${name ?? uid}.db'),
      cloud,
      loanCloud,
      householdId: householdId,
      clock: clock,
    );
    opened.add(d);
    return d;
  }

  Future<LoanSnapshot> lend(
    Device d, {
    int amount = 1200000,
    bool household = false,
    String name = 'John',
  }) async {
    final loan = await d.provider.createLoan(
      borrowerName: name,
      principalMinor: amount,
      lentDate: DateTime(2026, 11, 1),
      repaymentType: LoanRepaymentType.monthly,
      installmentMinor: 100000,
      firstDueDate: DateTime(2026, 12, 1),
      household: household,
    );
    return d.provider.snapshotById(loan.id)!;
  }

  test('created and repaid offline, uploaded once back online', () async {
    final a = await device('a');
    loanCloud.offline = true;
    cloud.offline = true;
    final loan = await lend(a);
    await a.provider.recordRepayment(
      loan,
      amountMinor: 150000,
      date: DateTime(2026, 11, 15),
    );
    final offline = await a.syncNow();
    expect(offline.outcome, SyncOutcome.offline);
    expect(loanCloud.docs, isEmpty);
    expect(a.only().loan.pendingRepayments, 1);
    expect(a.only().receivedMinor, 150000);

    loanCloud.offline = false;
    cloud.offline = false;
    final online = await a.syncNow();
    expect(online.outcome, SyncOutcome.completed);
    const personal = CloudPartition.personal('a');
    final doc = loanCloud.loanDoc(personal, loan.id)!;
    expect(doc['totalOwedMinor'], 1200000);
    expect(doc['receivedMinor'], 150000);
    expect((doc['schedule']! as List), hasLength(12));
    expect(loanCloud.repaymentWrites, 1);
    expect(loanCloud.reminderDoc(personal, loan.id), isNotNull);
    expect(a.only().loan.pendingRepayments, 0);
    expect(await a.repo.pendingLoans(personal), isEmpty);
  });

  test('syncing again never duplicates a repayment', () async {
    final a = await device('a');
    final loan = await lend(a);
    await a.provider.recordRepayment(
      loan,
      amountMinor: 100000,
      date: DateTime(2026, 11, 15),
    );
    await a.syncNow();
    await a.syncNow();
    await a.syncNow();
    expect(loanCloud.repaymentWrites, 1);
    // A lost response: the repayment is still pending locally but already
    // in the cloud; the retry is only confirmed.
    final r = a.provider.repaymentsOf(loan.id).single;
    await a.repo.markRepayment(r.id, RepaymentSyncState.pending);
    await a.syncNow();
    expect(loanCloud.repaymentWrites, 1);
    expect(a.provider.repaymentsOf(loan.id).single.isPending, isFalse);
    // Another device of the same user gets exactly one.
    final a2 = await device('a', name: 'a-tablet');
    await a2.syncNow();
    expect(a2.provider.repaymentsOf(loan.id), hasLength(1));
    expect(a2.only().receivedMinor, 100000);
  });

  test('personal lending never reaches another account', () async {
    final a = await device('a');
    await lend(a);
    await a.syncNow();
    final b = await device('b');
    await b.syncNow();
    expect(b.provider.loans, isEmpty);
    expect(
      loanCloud.docs.entries
          .where((e) => e.value.isNotEmpty)
          .every((e) => e.key.startsWith('users/a/')),
      isTrue,
    );
  });

  test(
    'household lending is shared with members and repaid by either',
    () async {
      final a = await device('a', householdId: hid);
      final b = await device('b', householdId: hid);
      final loan = await lend(a, household: true);
      expect(loan.loan.householdId, hid);
      await a.syncNow();
      await b.syncNow();
      final seen = b.only();
      expect(seen.loan.createdBy, 'a');
      expect(seen.loan.schedule, loan.loan.schedule);

      await b.provider.recordRepayment(
        seen,
        amountMinor: 300000,
        date: DateTime(2026, 11, 18),
      );
      await b.syncNow();
      await a.syncNow();
      expect(a.only().receivedMinor, 300000);
      final repayment = a.provider.repaymentsOf(loan.id).single;
      expect(repayment.userUid, 'b');
      // Household lending never shows in the personal figures.
      expect(a.provider.filtered(LoanFilter.personal), isEmpty);
    },
  );

  test('concurrent repayments can never exceed what is owed', () async {
    final a = await device('a', householdId: hid);
    final b = await device('b', householdId: hid);
    final loan = await lend(a, household: true, amount: 100000);
    await a.syncNow();
    await b.syncNow();
    // Both record the full amount while offline.
    await a.provider.recordRepayment(
      a.only(),
      amountMinor: 100000,
      date: DateTime(2026, 11, 18),
    );
    await b.provider.recordRepayment(
      b.only(),
      amountMinor: 100000,
      date: DateTime(2026, 11, 18),
    );
    await a.syncNow();
    final result = await b.syncNow();
    expect(result.report.repaymentsRejected, 1);
    final cloudLoan = loanCloud.loanDoc(
      CloudPartition.household('b', hid),
      loan.id,
    )!;
    expect(cloudLoan['receivedMinor'], 100000);
    // B keeps its record, marked as not recorded, and sees A's repayment.
    final mine = b.provider
        .repaymentsOf(loan.id)
        .firstWhere((r) => r.userUid == 'b');
    expect(mine.isRejected, isTrue);
    expect(b.only().receivedMinor, 100000);
    expect(b.only().isCompleted, isTrue);
  });

  test('conflicting edits: the newest change wins everywhere', () async {
    final a = await device('a', householdId: hid);
    final b = await device('b', householdId: hid);
    final created = await lend(a, household: true);
    await a.syncNow();
    await b.syncNow();

    Future<void> rename(Device d, String name) => d.provider.updateLoan(
      d.only(),
      borrowerName: name,
      principalMinor: created.loan.principalMinor,
      lentDate: created.loan.lentDate,
      repaymentType: created.loan.repaymentType,
      installmentMinor: created.loan.installmentMinor,
      firstDueDate: created.loan.firstDueDate,
      dueDay: created.loan.dueDay,
    );
    now = DateTime(2026, 11, 20, 11);
    await rename(a, 'John A');
    now = DateTime(2026, 11, 20, 12);
    await rename(b, 'John B');
    await b.syncNow();
    await a.syncNow();
    await b.syncNow();
    expect(a.only().loan.borrowerName, 'John B');
    expect(b.only().loan.borrowerName, 'John B');
  });

  test('only the owner changes household reminder recipients', () async {
    final a = await device('a', householdId: hid);
    final b = await device('b', householdId: hid);
    final created = await lend(b, household: true);
    // A member's loan reminds the owner by default.
    expect(b.provider.reminderSettingsOf(created.id).notifyUids, ['a']);
    await b.syncNow();
    await a.syncNow();
    expect(
      loanCloud.reminderDoc(CloudPartition.household('a', hid), created.id),
      isNotNull,
    );

    await expectLater(
      b.provider.saveReminderSettings(
        b.only().loan,
        enabled: true,
        paused: false,
        offsets: const [0],
        notifyUids: const ['b'],
      ),
      throwsA(isA<LoanException>()),
    );

    await a.provider.saveReminderSettings(
      a.only().loan,
      enabled: true,
      paused: false,
      offsets: const [-3, 0],
      notifyUids: const ['a', 'b'],
    );
    await a.syncNow();
    await b.syncNow();
    expect(b.provider.reminderSettingsOf(created.id).notifyUids, ['a', 'b']);
    // Now B's own phone schedules B's reminders.
    await b.provider.syncReminders();
    expect(b.notifier.scheduled, isNotEmpty);
    expect(
      b.notifier.scheduled.values.every(
        (s) => s.notification.channel == NotificationChannel.loanReminders,
      ),
      isTrue,
    );
  });

  test('a removed member loses the household lending and reminders', () async {
    final a = await device('a', householdId: hid);
    final b = await device('b', householdId: hid);
    await lend(a, household: true);
    final settingsLoan = a.only().loan;
    await a.provider.saveReminderSettings(
      settingsLoan,
      enabled: true,
      paused: false,
      offsets: const [0],
      notifyUids: const ['a', 'b'],
    );
    await a.syncNow();
    await b.syncNow();
    await b.provider.syncReminders();
    expect(b.notifier.scheduled, isNotEmpty);

    loanCloud.householdMembers[hid] = {'a'};
    final denied = await b.syncNow();
    expect(denied.report.loansUnavailable, isTrue);
    // The household provider confirms the membership ended and releases it.
    await b.sync.releaseHousehold(hid, uid: 'b');
    await b.provider.setContextForTesting(uid: 'b', name: 'User b');
    await b.provider.syncReminders();
    expect(b.provider.loans, isEmpty);
    expect(b.notifier.scheduled, isEmpty);
  });

  test(
    'restore after Reset App downloads lending again without duplicates',
    () async {
      final a = await device('a');
      final loan = await lend(a);
      await a.provider.recordRepayment(
        loan,
        amountMinor: 100000,
        date: DateTime(2026, 11, 15),
      );
      await a.syncNow();
      await a.sync.resetLocalData();
      await a.provider.load();
      expect(a.provider.loans, isEmpty);
      final restored = await a.sync.restoreFromCloud('a');
      await a.provider.load();
      expect(restored.outcome, SyncOutcome.completed);
      expect(a.only().receivedMinor, 100000);
      expect(a.provider.repaymentsOf(loan.id), hasLength(1));
      expect(loanCloud.repaymentWrites, 1);
    },
  );

  test('an offline extra payment revises the EMI on every device', () async {
    final a = await device('a', householdId: hid);
    final b = await device('b', householdId: hid);
    final loan = await lend(a, household: true);
    await a.syncNow();
    await b.syncNow();

    loanCloud.offline = true;
    cloud.offline = true;
    final r = await a.provider.recordRepayment(
      a.only(),
      amountMinor: 150000,
      date: DateTime(2026, 11, 18),
    );
    // Revised on this phone straight away, offline.
    expect(a.only().currentEmiMinor, 95455);
    expect(a.only().outstandingPrincipalMinor, 1050000);
    loanCloud.offline = false;
    cloud.offline = false;
    await a.syncNow();
    await a.syncNow();
    expect(loanCloud.repaymentWrites, 1);
    final stored = loanCloud.repaymentDoc(
      CloudPartition.household('a', hid),
      r.id,
    )!;
    expect((stored['allocation']! as Map)['extraPrincipalMinor'], 50000);

    // The other member's phone derives the same schedule from the same
    // repayment; the loan document itself was not rewritten.
    await b.syncNow();
    final seen = b.only();
    expect(seen.currentEmiMinor, 95455);
    expect(seen.outstandingPrincipalMinor, 1050000);
    expect(
      [for (final i in seen.installments) i.expectedMinor],
      [for (final i in a.only().installments) i.expectedMinor],
    );
    expect(b.provider.repaymentById(r.id)!.allocation!.revisedEmiMinor, 95455);
    expect(loan.loan.schedule, hasLength(12));
  });

  test('a voided repayment is voided on every device', () async {
    final a = await device('a', householdId: hid);
    final b = await device('b', householdId: hid);
    final loan = await lend(a, household: true);
    final r = await a.provider.recordRepayment(
      loan,
      amountMinor: 200000,
      date: DateTime(2026, 11, 15),
    );
    // Not uploaded yet: cannot be voided.
    await expectLater(
      a.provider.voidRepayment(a.provider.repaymentById(r.id)!),
      throwsA(isA<LoanException>()),
    );
    await a.syncNow();
    await a.provider.voidRepayment(
      a.provider.repaymentById(r.id)!,
      reason: 'Entered twice',
    );
    expect(a.only().receivedMinor, 0);
    final doc = loanCloud.loanDoc(CloudPartition.household('a', hid), loan.id)!;
    expect(doc['receivedMinor'], 0);
    await b.syncNow();
    final seen = b.provider.repaymentById(r.id)!;
    expect(seen.voided, isTrue);
    expect(seen.voidReason, 'Entered twice');
    expect(b.only().receivedMinor, 0);
  });
}
