import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/cloud_loan_store.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/repositories/loan_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fakes.dart';
import '../helpers/loan_builders.dart';

LoanReminderSettings defaults(String loanId) =>
    LoanReminderSettings(loanId: loanId, updatedAt: DateTime(2026, 12, 1));

void main() {
  sqfliteFfiInit();

  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('money_mate_loans');
    path = p.join(dir.path, 'test.db');
  });

  tearDown(() => dir.delete(recursive: true));

  Future<AppDatabase> open() =>
      AppDatabase.openAtPath(databaseFactoryFfiNoIsolate, path);

  group('migration', () {
    test('v6 → v7 adds the lending tables and keeps existing data', () async {
      final v6 = await AppDatabase.openAtPath(
        databaseFactoryFfiNoIsolate,
        path,
        version: 6,
      );
      final old = tx(id: 'keep', amountMinor: 500, date: DateTime(2026, 11, 1));
      await v6.db.insert(Tables.transactions, {
        ...old.toMap(),
        'sync_status': 'synced',
      });
      await v6.close();

      final v7 = await open();
      expect(await v7.db.getVersion(), AppConstants.databaseVersion);
      final rows = await v7.db.query(Tables.transactions);
      expect(rows.single['id'], 'keep');
      expect(rows.single['sync_status'], 'synced');
      for (final table in [
        Tables.loans,
        Tables.loanInstallments,
        Tables.loanRepayments,
        Tables.loanReminders,
      ]) {
        expect(await v7.db.query(table), isEmpty, reason: table);
      }
      // Usable straight away.
      await SqliteLoanRepository(
        v7,
      ).insertLoan(monthlyLoan(), defaults('loan'));
      expect(await SqliteLoanRepository(v7).getLoans(), hasLength(1));
      await v7.close();
    });

    test('v7 → v8 keeps loans flat and adds the payment records', () async {
      final v7 = await AppDatabase.openAtPath(
        databaseFactoryFfiNoIsolate,
        path,
        version: 7,
      );
      final old = oneTimeLoan(id: 'old');
      final row = old.toMap()
        ..remove('interest_method')
        ..remove('original_installment_minor')
        ..remove('original_term_months');
      await v7.db.insert(Tables.loans, row);
      final inst = old.schedule.single.toMap()..remove('interest_minor');
      await v7.db.insert(Tables.loanInstallments, inst);
      await v7.close();

      final v8 = await open();
      final repo = SqliteLoanRepository(v8);
      final loan = (await repo.getLoans()).single;
      expect(loan.interestMethod, InterestMethod.flat);
      expect(loan.schedule.single.interestMinor, isNull);
      expect(
        loan.schedule.single.expectedMinor,
        old.schedule.single.expectedMinor,
      );
      // Repayments can carry their allocation now.
      final allocation = RepaymentAllocation(
        extraPrincipalMinor: 500,
        principalBeforeMinor: 1000,
        principalAfterMinor: 400,
        remainingInstallments: 0,
        recalculatedAt: DateTime(2026, 11, 2),
      );
      await repo.addRepayment(
        LoanRepayment(
          id: 'r',
          loanId: 'old',
          amountMinor: 100,
          date: DateTime(2026, 11, 2),
          createdAt: DateTime(2026, 11, 2),
          updatedAt: DateTime(2026, 11, 2),
          allocation: allocation,
        ),
      );
      expect((await repo.getRepayments()).single.allocation, allocation);
      await v8.close();
    });

    test('a fresh install has the lending tables too', () async {
      final db = await AppDatabase.openInMemory(databaseFactoryFfiNoIsolate);
      final repo = SqliteLoanRepository(db);
      await repo.insertLoan(oneTimeLoan(), defaults('once'));
      expect(await repo.getLoans(), hasLength(1));
      await db.close();
    });
  });

  group('persistence', () {
    late AppDatabase db;
    late SqliteLoanRepository repo;

    setUp(() async {
      db = await open();
      repo = SqliteLoanRepository(db);
    });

    tearDown(() => db.close());

    test('loans keep their schedule, settings and derived totals', () async {
      final loan = monthlyLoan(
        months: 12,
        rateBp: 1200,
        method: InterestMethod.reducing,
      );
      await repo.insertLoan(
        loan,
        LoanReminderSettings(
          loanId: loan.id,
          offsets: const [-1, 0],
          updatedAt: DateTime(2026, 12, 1),
        ),
      );
      await repo.addRepayment(pay(loan.id, aed(1500), DateTime(2027, 1, 1)));

      final stored = (await repo.getLoans()).single;
      expect(stored.borrowerName, 'John');
      expect(stored.interestMinor, loan.interestMinor);
      expect(stored.interestMethod, InterestMethod.reducing);
      expect(stored.originalInstallmentMinor, loan.originalInstallmentMinor);
      expect(stored.originalTermMonths, 12);
      // Each instalment keeps its interest part.
      expect(
        [for (final i in stored.schedule) i.interestMinor],
        [for (final i in loan.schedule) i.interestMinor],
      );
      expect(stored.schedule, loan.schedule);
      expect(stored.receivedMinor, aed(1500));
      expect(stored.pendingRepayments, 1);
      expect(stored.isPersonal, isTrue);
      final settings = await repo.getReminderSettings();
      expect(settings[loan.id]!.offsets, [-1, 0]);
      final repayments = await repo.getRepayments();
      expect(repayments.single.amountMinor, aed(1500));
      expect(repayments.single.isPending, isTrue);
    });

    test('several loans of the same borrower stay separate records', () async {
      await repo.insertLoan(oneTimeLoan(id: 'a'), defaults('a'));
      await repo.insertLoan(oneTimeLoan(id: 'b'), defaults('b'));
      final loans = await repo.getLoans();
      expect(loans.map((l) => l.id).toSet(), {'a', 'b'});
    });

    test(
      'a repayment above the outstanding amount is refused atomically',
      () async {
        final loan = oneTimeLoan(principal: aed(1000));
        await repo.insertLoan(loan, defaults(loan.id));
        await repo.addRepayment(pay(loan.id, aed(800), DateTime(2026, 11, 2)));
        await expectLater(
          repo.addRepayment(pay(loan.id, aed(300), DateTime(2026, 11, 3))),
          throwsA(isA<LoanException>()),
        );
        expect(await repo.getRepayments(), hasLength(1));
        // A repayment the cloud already accepted is stored regardless.
        await repo.addRepayment(
          pay(loan.id, aed(300), DateTime(2026, 11, 3), id: 'cloud'),
          synced: true,
        );
        expect(await repo.getRepayments(), hasLength(2));
      },
    );

    test('repayments for a missing loan are refused', () async {
      await expectLater(
        repo.addRepayment(pay('nope', 100, DateTime(2026, 11, 3))),
        throwsA(isA<LoanException>()),
      );
    });

    test('editing replaces the schedule but never the history', () async {
      final loan = monthlyLoan();
      await repo.insertLoan(loan, defaults(loan.id));
      await repo.addRepayment(pay(loan.id, aed(1000), DateTime(2027, 1, 1)));
      await repo.updateLoan(
        loan.copyWith(
          borrowerName: 'John Smith',
          schedule: loan.schedule.take(3).toList(),
          updatedAt: DateTime(2027, 1, 2),
        ),
      );
      final stored = (await repo.getLoans()).single;
      expect(stored.borrowerName, 'John Smith');
      expect(stored.schedule, hasLength(3));
      expect((await repo.getRepayments()).single.amountMinor, aed(1000));
    });

    test('voids keep the repayment in the history', () async {
      final loan = oneTimeLoan();
      await repo.insertLoan(loan, defaults(loan.id));
      final r = pay(loan.id, aed(100), DateTime(2026, 11, 2));
      await repo.addRepayment(r);
      await repo.applyVoid(
        LoanRepayment(
          id: r.id,
          loanId: r.loanId,
          amountMinor: r.amountMinor,
          date: r.date,
          createdAt: r.createdAt,
          updatedAt: DateTime(2026, 11, 3),
          voided: true,
          voidedBy: 'me',
          voidedAt: DateTime(2026, 11, 3),
          voidReason: 'typo',
        ),
      );
      final stored = (await repo.getRepayments()).single;
      expect(stored.voided, isTrue);
      expect(stored.voidReason, 'typo');
      expect((await repo.getLoans()).single.receivedMinor, 0);
    });

    test(
      'deleting removes everything locally and queues a tombstone',
      () async {
        final loan = oneTimeLoan();
        await repo.insertLoan(loan, defaults(loan.id));
        await repo.addRepayment(pay(loan.id, aed(100), DateTime(2026, 11, 2)));
        await repo.deleteLoan(loan.id, DateTime(2026, 11, 5));
        expect(await repo.getLoans(), isEmpty);
        expect(await repo.getRepayments(), isEmpty);
        expect(await repo.getReminderSettings(), isEmpty);
        expect(await db.db.query(Tables.loanInstallments), isEmpty);
        final pending = await repo.pendingLoans(
          const CloudPartition.personal('me'),
        );
        expect(pending.single.isTombstone, isTrue);
        expect(pending.single.id, loan.id);
      },
    );

    test(
      'pending changes are per scope and confirmed only if unchanged',
      () async {
        await repo.insertLoan(oneTimeLoan(id: 'mine'), defaults('mine'));
        await repo.insertLoan(
          oneTimeLoan(id: 'ours', householdId: 'house'),
          defaults('ours'),
        );
        const personal = CloudPartition.personal('me');
        final household = CloudPartition.household('me', 'house');
        final mine = await repo.pendingLoans(personal);
        expect(mine.map((r) => r.id), ['mine']);
        expect((await repo.pendingLoans(household)).map((r) => r.id), ['ours']);
        expect((await repo.pendingReminders(household)).map((r) => r.id), [
          'ours',
        ]);

        // Edited after the upload was built: stays pending.
        final loan = (await repo.getLoans()).firstWhere((l) => l.id == 'mine');
        await repo.updateLoan(loan.copyWith(updatedAt: DateTime(2027)));
        await repo.confirmUploaded(personal, LoanCollection.loans, mine);
        expect(await repo.pendingLoans(personal), hasLength(1));
        final again = await repo.pendingLoans(personal);
        await repo.confirmUploaded(personal, LoanCollection.loans, again);
        expect(await repo.pendingLoans(personal), isEmpty);
      },
    );

    test('cloud copies: newer wins, older or equal never overwrites', () async {
      final loan = oneTimeLoan();
      const personal = CloudPartition.personal('me');
      await repo.insertLoan(loan, defaults(loan.id));
      final older = CloudRecord(
        id: loan.id,
        data: loan.copyWith(borrowerName: 'Old').toCloudMap(),
        updatedAtMs: loan.updatedAt.millisecondsSinceEpoch - 1,
      );
      expect(
        await repo.applyRemote(personal, LoanCollection.loans, older),
        isFalse,
      );
      final newer = CloudRecord(
        id: loan.id,
        data: loan.copyWith(borrowerName: 'Newer').toCloudMap(),
        updatedAtMs: loan.updatedAt.millisecondsSinceEpoch + 1000,
      );
      expect(
        await repo.applyRemote(personal, LoanCollection.loans, newer),
        isTrue,
      );
      expect((await repo.getLoans()).single.borrowerName, 'Newer');
      // A household document never lands in the personal scope.
      expect(
        await repo.applyRemote(
          CloudPartition.household('me', 'house'),
          LoanCollection.loans,
          CloudRecord(
            id: loan.id,
            data: loan.toCloudMap(),
            updatedAtMs: newer.updatedAtMs + 1,
          ),
        ),
        isFalse,
      );
    });
  });

  group('clean-up rules', () {
    test('releasing a household removes only its lending', () async {
      final db = await open();
      final repo = SqliteLoanRepository(db);
      await repo.insertLoan(oneTimeLoan(id: 'mine'), defaults('mine'));
      await repo.insertLoan(
        oneTimeLoan(id: 'ours', householdId: 'house'),
        defaults('ours'),
      );
      await repo.addRepayment(pay('ours', 100, DateTime(2026, 11, 2)));
      await SqliteLocalSyncStore(db).releaseHousehold('house', uid: 'me');
      expect((await repo.getLoans()).map((l) => l.id), ['mine']);
      expect(await repo.getRepayments(), isEmpty);
      expect((await repo.getReminderSettings()).keys, ['mine']);
      await db.close();
    });

    test('Reset App clears lending on this device only', () async {
      final db = await open();
      final repo = SqliteLoanRepository(db);
      await repo.insertLoan(oneTimeLoan(), defaults('once'));
      await db.db.insert(Tables.appSettings, {
        'key': SyncKeys.personalLoansCursor('loans', 'micros'),
        'value': '1',
      });
      await SqliteLocalSyncStore(db).clearLocalData(resetAt: DateTime(2027));
      expect(await repo.getLoans(), isEmpty);
      expect(
        await db.db.query(
          Tables.appSettings,
          where: 'key LIKE ?',
          whereArgs: ['${SyncKeys.personalLoansPrefix}%'],
        ),
        isEmpty,
      );
      await db.close();
    });

    test('the 90-day transaction clean-up never selects lending', () async {
      final db = await open();
      final repo = SqliteLoanRepository(db);
      // Lent and repaid long ago, everything synced.
      final loan = oneTimeLoan(
        lent: DateTime(2020, 1, 1),
        due: DateTime(2020, 6, 1),
      );
      await repo.insertLoan(loan, defaults(loan.id));
      await repo.addRepayment(
        pay(loan.id, loan.totalOwedMinor, DateTime(2020, 5, 1)),
        synced: true,
      );
      final local = SqliteLocalSyncStore(db);
      final candidates = await local.archiveCandidates(
        DateTime(2026, 11, 1),
        limit: 100,
      );
      expect(candidates, isEmpty);
      expect(await repo.getLoans(), hasLength(1));
      expect(await repo.getRepayments(), hasLength(1));
      await db.close();
    });
  });
}
