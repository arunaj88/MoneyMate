import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/cloud_savings_store.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/repositories/savings_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_cloud_store.dart';

const hid = 'house-1';

/// One phone: its own database and sync service, sharing the cloud.
class Device {
  Device._(this.uid, this.db, this.savings, this.sync, this.provider);

  /// Each device gets its own database file (in-memory databases with the
  /// same path would be shared).
  static Future<Device> open(
    String uid,
    String path,
    InMemoryCloudStore cloud,
    InMemorySavingsCloudStore savingsCloud, {
    String? householdId,
  }) async {
    final db = await AppDatabase.openAtPath(databaseFactoryFfiNoIsolate, path);
    final savings = SqliteSavingsRepository(db);
    final sync = TransactionSyncService(
      local: SqliteLocalSyncStore(db),
      cloud: cloud,
      savingsLocal: savings,
      savingsCloud: savingsCloud,
    );
    final provider = SavingsProvider(savings, cloud: savingsCloud);
    await provider.setContextForTesting(
      uid: uid,
      name: 'User $uid',
      email: savingsCloud.emails[uid],
      householdId: householdId,
    );
    return Device._(uid, db, savings, sync, provider);
  }

  final String uid;
  final AppDatabase db;
  final SqliteSavingsRepository savings;
  final TransactionSyncService sync;
  final SavingsProvider provider;
  String? householdId;

  Future<SyncResult> syncNow() async {
    final result = await sync.synchronize(uid, householdId: householdId);
    await provider.load();
    return result;
  }

  Future<Map<String, int>> balances() async => {
    for (final g in await savings.getGoals()) g.id: g.savedMinor,
  };

  SavingsPartition get personal => SavingsPartition.personal(uid);
}

SavingsGoal goal(
  String id,
  DateTime at, {
  String name = 'Trip',
  SavingsOwnership ownership = SavingsOwnership.personal,
  String? householdId,
}) => SavingsGoal(
  id: id,
  name: name,
  purpose: SavingsPurpose.trip,
  targetMinor: 100000,
  createdAt: at,
  updatedAt: at,
  ownership: ownership,
  householdId: householdId,
);

SavingsEntry deposit(
  String id,
  String goalId,
  int amount,
  DateTime at, {
  String? by,
}) => SavingsEntry(
  id: id,
  goalId: goalId,
  type: SavingsEntryType.deposit,
  amountMinor: amount,
  date: at,
  createdAt: at,
  updatedAt: at,
  userUid: by,
);

void main() {
  sqfliteFfiInit();

  late InMemoryCloudStore cloud;
  late InMemorySavingsCloudStore savingsCloud;
  late Directory dir;
  final opened = <Device>[];
  final t0 = DateTime(2026, 11, 1, 9);

  setUp(() async {
    cloud = InMemoryCloudStore();
    savingsCloud = InMemorySavingsCloudStore()
      ..householdMembers[hid] = {'a', 'b'}
      ..emails.addAll({
        'a': 'a@example.com',
        'b': 'b@example.com',
        'c': 'c@example.com',
        'd': 'd@example.com',
      });
    dir = await Directory.systemTemp.createTemp('money_mate_savings_sync');
  });

  tearDown(() async {
    for (final d in opened) {
      d.provider.dispose();
      await d.db.close();
    }
    opened.clear();
    await dir.delete(recursive: true);
  });

  Future<Device> device(String uid, {String? householdId}) async {
    final d =
        await Device.open(
            uid,
            p.join(dir.path, '$uid-${opened.length}.db'),
            cloud,
            savingsCloud,
            householdId: householdId,
          )
          ..householdId = householdId;
    opened.add(d);
    return d;
  }

  String personalPath(String uid, SavingsCollection c) =>
      'users/$uid/${c.path}';

  // ================================================================ personal

  group('personal', () {
    test('goals and history reach another device', () async {
      final a = await device('a');
      final a2 = await device('a');
      await a.savings.insertGoal(goal('g', t0));
      await a.savings.addEntry(deposit('e1', 'g', 2500, t0));
      final up = await a.syncNow();
      expect(up.outcome, SyncOutcome.completed);
      expect(up.report.savingsUploaded, 2);

      final down = await a2.syncNow();
      expect(down.report.savingsDownloaded, 2);
      expect(down.report.localDataChanged, isTrue);
      expect(await a2.balances(), {'g': 2500});
      expect(
        await a2.savings.pendingRecords(a2.personal, SavingsCollection.goals),
        isEmpty,
      );
    });

    test('repeated syncs are idempotent: no duplicates anywhere', () async {
      final a = await device('a');
      final a2 = await device('a');
      await a.savings.insertGoal(goal('g', t0));
      await a.savings.addEntry(deposit('e1', 'g', 1000, t0));
      for (var i = 0; i < 3; i++) {
        await a.syncNow();
        await a2.syncNow();
      }
      expect(
        savingsCloud.docs(personalPath('a', SavingsCollection.entries)),
        hasLength(1),
      );
      expect(await a2.savings.getEntries('g'), hasLength(1));
      final writes = savingsCloud.writes;
      expect((await a.syncNow()).report.savingsUploaded, 0);
      expect(savingsCloud.writes, writes);
    });

    test('works offline and uploads once back online', () async {
      final a = await device('a');
      final a2 = await device('a');
      savingsCloud.offline = true;
      cloud.offline = true;
      await a.savings.insertGoal(goal('g', t0));
      await a.savings.addEntry(deposit('e1', 'g', 700, t0));
      expect((await a.syncNow()).outcome, SyncOutcome.offline);
      expect(await a.balances(), {'g': 700});

      savingsCloud.offline = false;
      cloud.offline = false;
      await a.syncNow();
      expect(
        await a.savings.pendingRecords(a.personal, SavingsCollection.entries),
        isEmpty,
      );
      await a2.syncNow();
      expect(await a2.balances(), {'g': 700});
    });

    test('a deleted goal disappears everywhere with its history', () async {
      final a = await device('a');
      final a2 = await device('a');
      await a.savings.insertGoal(goal('g', t0));
      await a.savings.addEntry(deposit('e1', 'g', 900, t0));
      await a.syncNow();
      await a2.syncNow();
      await a.savings.deleteGoal('g', t0.add(const Duration(hours: 1)));
      await a.syncNow();
      final cloudGoal = savingsCloud.doc(
        personalPath('a', SavingsCollection.goals),
        'g',
      );
      expect(cloudGoal!['deleted'], isTrue);
      await a2.syncNow();
      expect(await a2.balances(), isEmpty);
      expect(await a2.savings.getEntries('g'), isEmpty);
    });

    test('a local deletion is kept until the cloud confirms it', () async {
      final a = await device('a');
      await a.savings.insertGoal(goal('g', t0));
      await a.syncNow();
      savingsCloud.offline = true;
      cloud.offline = true;
      await a.savings.deleteGoal('g', t0.add(const Duration(hours: 1)));
      await a.syncNow();
      final pending = await a.savings.pendingRecords(
        a.personal,
        SavingsCollection.goals,
      );
      expect(pending.single.isTombstone, isTrue);
    });

    test('last writer wins for goal edits', () async {
      final a = await device('a');
      final a2 = await device('a');
      await a.savings.insertGoal(goal('g', t0));
      await a.syncNow();
      await a2.syncNow();
      final first = (await a.savings.getGoals()).single;
      final second = (await a2.savings.getGoals()).single;
      await a.savings.updateGoal(
        first.copyWith(
          name: 'Older edit',
          updatedAt: t0.add(const Duration(minutes: 1)),
        ),
      );
      await a2.savings.updateGoal(
        second.copyWith(
          name: 'Newer edit',
          updatedAt: t0.add(const Duration(minutes: 2)),
        ),
      );
      await a2.syncNow();
      await a.syncNow();
      await a2.syncNow();
      await a.syncNow();
      expect(
        {
          (await a.savings.getGoals()).single.name,
          (await a2.savings.getGoals()).single.name,
        },
        {'Newer edit'},
      );
    });

    test('refused access (rules not deployed) does not break sync', () async {
      final a = await device('a');
      savingsCloud.denied = true;
      await a.savings.insertGoal(goal('g', t0));
      final result = await a.syncNow();
      expect(result.outcome, SyncOutcome.completed);
      expect(result.report.savingsUnavailable, isTrue);
      expect(result.report.failed, 0);
      expect(
        await a.savings.pendingRecords(a.personal, SavingsCollection.goals),
        hasLength(1),
      );
    });

    test('Restore My Cloud Data brings savings back after Reset App', () async {
      final a = await device('a');
      await a.savings.insertGoal(goal('g', t0));
      await a.savings.addEntry(deposit('e1', 'g', 4200, t0));
      await a.syncNow();
      await a.sync.resetLocalData();
      await a.syncNow();
      expect(await a.balances(), isEmpty);
      final restored = await a.sync.restoreFromCloud('a');
      expect(restored.outcome, SyncOutcome.completed);
      expect(await a.balances(), {'g': 4200});
    });

    test(
      'savings history is never removed by the retention clean-up',
      () async {
        final a = await device('a');
        final old = DateTime.now().subtract(const Duration(days: 400));
        await a.savings.insertGoal(goal('g', old));
        await a.savings.addEntry(deposit('e1', 'g', 300, old));
        await a.syncNow();
        await a.syncNow();
        expect((await a.savings.getEntries('g')).single.id, 'e1');
      },
    );
  });

  // =============================================================== household

  group('household', () {
    const goalsPath = 'households/$hid/savingsGoals';

    test('members share goals; contributions are attributed', () async {
      final a = await device('a', householdId: hid);
      final b = await device('b', householdId: hid);
      final g = await a.provider.createGoal(
        ownership: SavingsOwnership.household,
        name: 'Family trip',
        purpose: SavingsPurpose.trip,
        targetMinor: 100000,
      );
      await a.provider.addMoney(g, amountMinor: 3000, date: DateTime.now());
      await a.syncNow();
      expect(savingsCloud.savedOn(goalsPath, g.id), 3000);

      await b.syncNow();
      final seen = b.provider.goalsOf(SavingsOwnership.household).single;
      expect(seen.savedMinor, 3000);
      expect(seen.householdId, hid);
      await b.provider.loadEntries(g.id);
      expect(b.provider.contributionsOf(g.id).single.name, 'User a');

      // Kept apart from personal savings and the personal balance.
      expect(b.provider.personalSavedMinor, 0);
      expect(b.provider.savedForScope(const ScopeFilter.personal()), 0);
      expect(b.provider.savedForScope(const ScopeFilter.shared(hid)), 3000);
    });

    test('concurrent offline contributions add up exactly once', () async {
      final a = await device('a', householdId: hid);
      final b = await device('b', householdId: hid);
      final g = await a.provider.createGoal(
        ownership: SavingsOwnership.household,
        name: 'Car',
        purpose: SavingsPurpose.vehicle,
        targetMinor: 100000,
      );
      await a.syncNow();
      await b.syncNow();

      savingsCloud.offline = true;
      cloud.offline = true;
      await a.provider.addMoney(
        a.provider.goalById(g.id)!,
        amountMinor: 100,
        date: DateTime.now(),
      );
      await b.provider.addMoney(
        b.provider.goalById(g.id)!,
        amountMinor: 200,
        date: DateTime.now(),
      );
      expect((await a.syncNow()).outcome, SyncOutcome.offline);
      savingsCloud.offline = false;
      cloud.offline = false;
      for (var i = 0; i < 2; i++) {
        await a.syncNow();
        await b.syncNow();
      }
      expect(savingsCloud.savedOn(goalsPath, g.id), 300);
      expect(await a.balances(), {g.id: 300});
      expect(await b.balances(), {g.id: 300});
    });

    test(
      'a retried upload after a lost response is not counted twice',
      () async {
        final a = await device('a', householdId: hid);
        await a.savings.insertGoal(
          goal(
            'g',
            t0,
            ownership: SavingsOwnership.household,
            householdId: hid,
          ),
        );
        await a.syncNow();
        final entry = deposit('e1', 'g', 500, t0, by: 'a');
        await a.savings.addEntry(entry);
        // The write reached the cloud, but the device never heard back.
        await savingsCloud.recordEntry(
          const SavingsPartition.household('a', hid),
          entry,
        );
        await a.syncNow();
        expect(savingsCloud.savedOn(goalsPath, 'g'), 500);
        expect((await a.savings.getEntries('g')).single.isPending, isFalse);
      },
    );

    test(
      'withdrawals check the latest balance and need a connection',
      () async {
        final a = await device('a', householdId: hid);
        final b = await device('b', householdId: hid);
        final g = await a.provider.createGoal(
          ownership: SavingsOwnership.household,
          name: 'Fund',
          purpose: SavingsPurpose.emergency,
          targetMinor: 100000,
        );
        await a.provider.addMoney(g, amountMinor: 600, date: DateTime.now());
        await a.syncNow();
        await b.syncNow();

        // B withdraws 400 first; A's device still believes 600 is there.
        await b.provider.withdrawMoney(
          b.provider.goalById(g.id)!,
          amountMinor: 400,
          date: DateTime.now(),
        );
        await expectLater(
          a.provider.withdrawMoney(
            a.provider.goalById(g.id)!,
            amountMinor: 400,
            date: DateTime.now(),
          ),
          throwsA(isA<SavingsException>()),
        );
        expect(savingsCloud.savedOn(goalsPath, g.id), 200);

        savingsCloud.offline = true;
        await expectLater(
          a.provider.withdrawMoney(
            a.provider.goalById(g.id)!,
            amountMinor: 100,
            date: DateTime.now(),
          ),
          throwsA(
            isA<SavingsException>().having(
              (e) => e.message,
              'message',
              contains('internet'),
            ),
          ),
        );
      },
    );

    test(
      'someone outside the household cannot read or write its savings',
      () async {
        final c = await device('c', householdId: hid);
        await c.savings.insertGoal(
          goal(
            'x',
            t0,
            ownership: SavingsOwnership.household,
            householdId: hid,
          ),
        );
        final result = await c.syncNow();
        expect(result.report.savingsUnavailable, isTrue);
        expect(savingsCloud.docs(goalsPath), isEmpty);
      },
    );

    test('leaving the household removes its goals from the device', () async {
      final a = await device('a', householdId: hid);
      await a.savings.insertGoal(
        goal('g', t0, ownership: SavingsOwnership.household, householdId: hid),
      );
      await a.savings.insertGoal(goal('mine', t0));
      await a.syncNow();
      await SqliteLocalSyncStore(a.db).releaseHousehold(hid, uid: 'a');
      expect((await a.balances()).keys, ['mine']);
    });
  });

  // ================================================================== shared

  group('shared goals', () {
    Future<(Device, Device, SavingsGoal)> ownerAndFriend() async {
      final a = await device('a');
      final b = await device('b');
      final g = await a.provider.createGoal(
        ownership: SavingsOwnership.shared,
        name: 'Friends trip',
        purpose: SavingsPurpose.trip,
        targetMinor: 100000,
      );
      await a.provider.inviteByEmail(g, 'b@example.com');
      await b.provider.refreshReceivedInvitations();
      expect(b.provider.receivedInvitations, hasLength(1));
      await b.provider.acceptInvitation(b.provider.receivedInvitations.single);
      await b.syncNow();
      return (a, b, g);
    }

    test('create, invite by email, accept and see each other', () async {
      final (a, b, g) = await ownerAndFriend();
      final mine = b.provider.goalsOf(SavingsOwnership.shared).single;
      expect(mine.id, g.id);
      expect(mine.memberCount, 2);
      expect(b.provider.isOwner(mine), isFalse);
      expect(b.provider.canManage(mine), isFalse);
      expect(b.provider.canContribute(mine), isTrue);
      expect(b.provider.canWithdraw(mine), isFalse);
      await a.syncNow();
      expect(a.provider.goalsOf(SavingsOwnership.shared).single.memberCount, 2);
      // Independent of households and of everyone's balance.
      expect(a.provider.goalsOf(SavingsOwnership.household), isEmpty);
      expect(b.provider.savedForScope(const ScopeFilter.personal()), 0);
    });

    test(
      'offline contributions are queued, uploaded once, attributed',
      () async {
        final (a, b, g) = await ownerAndFriend();
        savingsCloud.offline = true;
        cloud.offline = true;
        await b.provider.addMoney(
          b.provider.goalById(g.id)!,
          amountMinor: 2500,
          date: DateTime.now(),
        );
        expect(b.provider.goalById(g.id)!.pendingEntries, 1);
        savingsCloud.offline = false;
        cloud.offline = false;
        await b.syncNow();
        await b.syncNow();
        expect(savingsCloud.savedOn('sharedGoals', g.id), 2500);
        expect(b.provider.goalById(g.id)!.pendingEntries, 0);

        await a.syncNow();
        await a.provider.loadEntries(g.id);
        final rows = a.provider.contributionsOf(g.id);
        expect(rows.single.name, 'User b');
        expect(rows.single.netMinor, 2500);
        expect(a.provider.sharedSavedMinor, 2500);
        expect(b.provider.mySharedContributionMinor, 2500);
        // A recorded contribution never changes a personal balance.
        expect(a.provider.savedForScope(const ScopeFilter.personal()), 0);
      },
    );

    test('only permitted members withdraw; the owner can grant it', () async {
      final (a, b, g) = await ownerAndFriend();
      await a.provider.addMoney(
        a.provider.goalById(g.id)!,
        amountMinor: 1000,
        date: DateTime.now(),
      );
      await a.syncNow();
      await b.syncNow();
      await expectLater(
        b.provider.withdrawMoney(
          b.provider.goalById(g.id)!,
          amountMinor: 100,
          date: DateTime.now(),
        ),
        throwsA(isA<SavingsException>()),
      );
      // Members cannot manage the goal either.
      await expectLater(
        b.provider.pauseGoal(b.provider.goalById(g.id)!),
        throwsA(isA<SavingsException>()),
      );

      await a.provider.refreshShared(a.provider.goalById(g.id)!);
      final member = a.provider.membersOf(g.id).firstWhere((m) => m.uid == 'b');
      await a.provider.setCanWithdraw(a.provider.goalById(g.id)!, member, true);
      await b.syncNow();
      await b.provider.withdrawMoney(
        b.provider.goalById(g.id)!,
        amountMinor: 100,
        date: DateTime.now(),
      );
      expect(savingsCloud.savedOn('sharedGoals', g.id), 900);
    });

    test('a removed member loses access and the cached copy', () async {
      final (a, b, g) = await ownerAndFriend();
      await a.provider.refreshShared(a.provider.goalById(g.id)!);
      final member = a.provider.membersOf(g.id).firstWhere((m) => m.uid == 'b');
      await a.provider.removeMember(a.provider.goalById(g.id)!, member);

      final result = await b.syncNow();
      expect(result.report.sharedGoalsReleased, 1);
      expect(b.provider.goalsOf(SavingsOwnership.shared), isEmpty);
      await expectLater(
        savingsCloud.fetchSharedGoal('b', g.id),
        throwsA(isA<Exception>()),
      );
      expect(a.provider.goalById(g.id)!.memberCount, 1);
    });

    test('invitation codes: one use, right account, revocable', () async {
      final a = await device('a');
      final c = await device('c');
      final d = await device('d');
      final g = await a.provider.createGoal(
        ownership: SavingsOwnership.shared,
        name: 'Wedding',
        purpose: SavingsPurpose.wedding,
        targetMinor: 100000,
      );
      final open = await a.provider.createInviteCode(g);
      final preview = await c.provider.previewCode(open.formattedCode);
      await c.provider.acceptInvitation(preview);
      await expectLater(
        d.provider.previewCode(open.code),
        throwsA(isA<SavingsException>()),
      );

      // An email invitation cannot be used by another account.
      final forB = await a.provider.inviteByEmail(g, 'b@example.com');
      await expectLater(
        d.provider.previewCode(forB.code),
        throwsA(isA<SavingsException>()),
      );

      // Revoked codes stop working.
      final revoked = await a.provider.createInviteCode(g);
      await a.provider.revokeInvitation(g, revoked);
      await expectLater(
        d.provider.previewCode(revoked.code),
        throwsA(isA<SavingsException>()),
      );
      await expectLater(
        d.provider.previewCode('not a code'),
        throwsA(isA<SavingsException>()),
      );
    });

    test('declining an invitation removes it', () async {
      final a = await device('a');
      final b = await device('b');
      final g = await a.provider.createGoal(
        ownership: SavingsOwnership.shared,
        name: 'Event',
        purpose: SavingsPurpose.other,
        targetMinor: 5000,
      );
      await a.provider.inviteByEmail(g, 'b@example.com');
      await b.provider.refreshReceivedInvitations();
      await b.provider.rejectInvitation(b.provider.receivedInvitations.single);
      expect(b.provider.receivedInvitations, isEmpty);
      await b.provider.refreshReceivedInvitations();
      expect(b.provider.receivedInvitations, isEmpty);
    });

    test('the owner deletes the goal for everyone', () async {
      final (a, b, g) = await ownerAndFriend();
      await a.provider.deleteGoal(a.provider.goalById(g.id)!);
      expect(a.provider.goalsOf(SavingsOwnership.shared), isEmpty);
      await b.syncNow();
      expect(b.provider.goalsOf(SavingsOwnership.shared), isEmpty);
    });

    test('creating a shared goal needs a connection', () async {
      final a = await device('a');
      savingsCloud.offline = true;
      await expectLater(
        a.provider.createGoal(
          ownership: SavingsOwnership.shared,
          name: 'Trip',
          purpose: SavingsPurpose.trip,
          targetMinor: 100,
        ),
        throwsA(isA<SavingsException>()),
      );
      expect(a.provider.goals, isEmpty);
    });
  });
}
