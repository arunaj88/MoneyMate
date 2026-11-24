import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/household_service.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_household_service.dart';
import '../helpers/fakes.dart';

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FakeHouseholdService service;
  late AuthProvider auth;
  late HouseholdProvider household;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    service = FakeHouseholdService(uid: testUser.uid);
    auth = AuthProvider(FakeAuthService(signedIn: testUser), prefs);
    await settle();
    household = HouseholdProvider(service: service, preferences: prefs);
    household.updateAuth(auth);
    await settle();
  });

  tearDown(() {
    household.dispose();
    auth.dispose();
  });

  group('household membership', () {
    test('a user without a household cannot share', () async {
      expect(household.hasHousehold, isFalse);
      expect(household.phase, HouseholdPhase.ready);
      final scope = TransactionScopeProvider(prefs)..updateHousehold(household);
      await scope.setView(ViewScope.shared);
      expect(scope.canShare, isFalse);
      expect(scope.view, ViewScope.personal);
      expect(scope.filter, const ScopeFilter.personal());
    });

    test('creating a household makes the user its owner', () async {
      expect(await household.createHousehold('  Khan family '), isTrue);
      await settle();
      expect(household.householdId, 'house-1');
      expect(household.household!.name, 'Khan family');
      expect(household.isOwner, isTrue);
      expect(household.role, HouseholdRole.owner);
      expect(household.members.single.uid, testUser.uid);
    });

    test('names are validated before calling the server', () async {
      expect(await household.createHousehold('   '), isFalse);
      expect(household.error, 'Enter a household name.');
      expect(service.calls, isEmpty);
    });

    test('joining with an invitation code', () async {
      service.codes['K7QM2XRP9D'] = const Household(
        id: 'house-2',
        name: 'Sara & Sam',
        ownerUid: 'uid-sara',
      );
      final preview = await household.previewInvitation('k7qm2-xrp9d');
      expect(preview!.householdName, 'Sara & Sam');
      expect(await household.acceptInvitation('K7QM2-XRP9D'), isTrue);
      await settle();
      expect(household.householdId, 'house-2');
      expect(household.isOwner, isFalse);
      expect(household.role, HouseholdRole.member);
      expect(household.memberName('uid-sara'), 'Sara Khan');
      expect(service.calls, ['preview:K7QM2XRP9D', 'accept:K7QM2XRP9D']);
    });

    test('a used or unknown code shows the server message', () async {
      expect(await household.acceptInvitation('ABCDEFGHJK'), isFalse);
      expect(household.error, 'This invitation has already been used.');
      expect(household.hasHousehold, isFalse);
    });

    test('short codes are rejected without a request', () async {
      expect(await household.acceptInvitation('ABC'), isFalse);
      expect(household.error, contains('full invitation code'));
      expect(service.calls, isEmpty);
    });

    test('the household is cached for offline use', () async {
      await household.createHousehold('Home');
      await settle();

      final offline = FakeHouseholdService(uid: testUser.uid)..offline = true;
      // The server has not answered yet: the cached household is used.
      offline.membershipIds = ['house-1'];
      final again = HouseholdProvider(service: offline, preferences: prefs)
        ..updateAuth(auth);
      expect(again.householdId, 'house-1');
      expect(again.household!.name, 'Home');
      again.dispose();
    });
  });

  group('access loss', () {
    test('removal confirmed by the server releases the household', () async {
      await household.createHousehold('Home');
      await settle();
      final token = household.releaseToken;

      service.removeCurrentUser();
      await settle();

      expect(household.hasHousehold, isFalse);
      expect(household.releasedHouseholdId, 'house-1');
      expect(household.releaseToken, token + 1);
      expect(household.takeNotice(), contains('no longer have access'));
    });

    test(
      'a refused read is only acted on when the server confirms it',
      () async {
        await household.createHousehold('Home');
        await settle();
        final token = household.releaseToken;

        service.offline = true;
        await household.confirmAccess('house-1');
        expect(household.hasHousehold, isTrue, reason: 'offline: keep data');
        expect(household.releaseToken, token);

        service.offline = false;
        await household.confirmAccess('house-1');
        expect(household.hasHousehold, isTrue, reason: 'still a member');

        service.membershipIds = [];
        await household.confirmAccess('house-1');
        expect(household.hasHousehold, isFalse);
        expect(household.releaseToken, token + 1);
      },
    );

    test('leaving releases the household without an access notice', () async {
      service.codes['K7QM2XRP9D'] = const Household(
        id: 'house-2',
        name: 'Sara & Sam',
        ownerUid: 'uid-sara',
      );
      await household.acceptInvitation('K7QM2XRP9D');
      await settle();

      expect(await household.leaveHousehold(), isTrue);
      expect(household.hasHousehold, isFalse);
      expect(household.releasedHouseholdId, 'house-2');
      expect(household.takeNotice(), isNull);
    });

    test('signing out clears the household from memory', () async {
      await household.createHousehold('Home');
      await settle();
      await auth.signOut();
      await settle();
      household.updateAuth(auth);
      await settle();
      expect(household.hasHousehold, isFalse);
      expect(household.phase, HouseholdPhase.signedOut);
    });
  });

  group('transaction scope', () {
    late InMemoryTransactionRepository repo;
    late TransactionProvider transactions;
    late TransactionScopeProvider scope;

    setUp(() async {
      repo = InMemoryTransactionRepository(
        initial: [
          tx(id: 'p', amountMinor: 100, date: DateTime(2026, 11, 20)),
          tx(
            id: 's',
            amountMinor: 250,
            date: DateTime(2026, 11, 21),
            householdId: 'house-1',
            createdBy: 'uid-sara',
          ),
        ],
      );
      transactions = TransactionProvider(repo);
      await transactions.load();
      scope = TransactionScopeProvider(prefs);
    });

    test(
      'shared transactions need a household and record their creator',
      () async {
        expect(
          () => transactions.addTransaction(
            type: TransactionType.expense,
            amountMinor: 500,
            categoryId: 'exp_food',
            date: DateTime(2026, 11, 22),
            scope: TransactionScope.shared,
            createdBy: testUser.uid,
          ),
          throwsArgumentError,
        );

        final t = await transactions.addTransaction(
          type: TransactionType.expense,
          amountMinor: 500,
          categoryId: 'exp_food',
          date: DateTime(2026, 11, 22),
          scope: TransactionScope.shared,
          householdId: 'house-1',
          createdBy: testUser.uid,
          createdByName: 'Sam Lee',
        );
        expect(t.isShared, isTrue);
        expect(t.householdId, 'house-1');
        expect(t.createdBy, testUser.uid);
        expect(t.updatedBy, testUser.uid);
      },
    );

    test('personal transactions never carry a household', () async {
      final t = await transactions.addTransaction(
        type: TransactionType.expense,
        amountMinor: 500,
        categoryId: 'exp_food',
        date: DateTime(2026, 11, 22),
        householdId: 'house-1',
      );
      expect(t.isPersonal, isTrue);
      expect(t.householdId, isNull);
    });

    test('the list shows personal or household records, never both', () async {
      await household.createHousehold('Home');
      await settle();
      scope.updateHousehold(household);
      await settle();

      List<String> ids() => transactions.transactions.map((t) => t.id).toList();

      transactions.onScopeChanged(scope);
      await settle();
      expect(ids(), ['p']);
      expect(transactions.filteredExpenseMinor, 100);

      await scope.setView(ViewScope.shared);
      transactions.onScopeChanged(scope);
      await settle();
      expect(ids(), ['s']);
      expect(transactions.filteredExpenseMinor, 250);

      await scope.setView(ViewScope.personal);
      transactions.onScopeChanged(scope);
      await settle();
      expect(ids(), ['p']);
    });

    test(
      'a saved "combined" view from an older version opens personal',
      () async {
        await prefs.setString(PrefKeys.viewScope, 'combined');
        final restored = TransactionScopeProvider(prefs);
        await household.createHousehold('Home');
        await settle();
        restored.updateHousehold(household);
        await settle();
        expect(restored.view, ViewScope.personal);
        expect(restored.filter, const ScopeFilter.personal());
        expect(ViewScope.values.map((v) => v.label), ['Personal', 'Household']);
        restored.dispose();
      },
    );
  });

  group('request state', () {
    test('a slow create shows progress until it finishes', () async {
      service.gate = Completer<void>();
      final result = household.createHousehold('Home');
      expect(household.isBusy, isTrue);
      expect(household.isRunning(HouseholdAction.create), isTrue);
      expect(household.pendingAction?.progressLabel, 'Creating household…');

      service.gate!.complete();
      expect(await result, isTrue);
      expect(household.isBusy, isFalse);
      expect(household.hasHousehold, isTrue);
    });

    test('repeated taps while a request runs reach the server once', () async {
      service.gate = Completer<void>();
      final first = household.createHousehold('Home');
      expect(await household.createHousehold('Home'), isFalse);
      expect(await household.deleteHousehold(), isFalse);
      service.gate!.complete();
      expect(await first, isTrue);
      expect(service.calls, ['create']);
    });

    test('a failed request clears the progress and explains why', () async {
      service
        ..offline = true
        ..gate = Completer<void>();
      final result = household.createHousehold('Home');
      expect(household.isBusy, isTrue);
      service.gate!.complete();
      expect(await result, isFalse);
      expect(household.isBusy, isFalse);
      expect(household.error, contains('offline'));
      expect(household.hasHousehold, isFalse);

      // The next attempt works once the connection is back.
      service.offline = false;
      expect(await household.createHousehold('Home'), isTrue);
      expect(household.error, isNull);
    });

    test(
      'a slow delete shows progress and then releases the household',
      () async {
        await household.createHousehold('Home');
        await settle();
        final token = household.releaseToken;
        service.gate = Completer<void>();
        final result = household.deleteHousehold();
        expect(household.isRunning(HouseholdAction.delete), isTrue);
        expect(household.hasHousehold, isTrue);

        service.gate!.complete();
        expect(await result, isTrue);
        await settle();
        expect(household.isBusy, isFalse);
        expect(household.hasHousehold, isFalse);
        expect(household.releaseToken, token + 1);
        // Deleting is voluntary: no "access ended" notice.
        expect(household.notice, isNull);
      },
    );

    test(
      'a failed delete keeps the household and clears the progress',
      () async {
        await household.createHousehold('Home');
        await settle();
        service.offline = true;
        expect(await household.deleteHousehold(), isFalse);
        expect(household.isBusy, isFalse);
        expect(household.hasHousehold, isTrue);
        expect(household.error, isNotNull);
      },
    );

    test('member requests report which member they are about', () async {
      await household.createHousehold('Home');
      await settle();
      service.gate = Completer<void>();
      final result = household.removeMember('uid-sara');
      expect(
        household.isRunning(HouseholdAction.removeMember, target: 'uid-sara'),
        isTrue,
      );
      expect(
        household.isRunning(HouseholdAction.removeMember, target: 'uid-x'),
        isFalse,
      );
      service.gate!.complete();
      expect(await result, isTrue);
      expect(household.isBusy, isFalse);
    });

    test(
      'leaving stops when preparation fails, without calling the server',
      () async {
        service.codes['K7QM2XRP9D'] = const Household(
          id: 'house-2',
          name: 'Sara & Sam',
          ownerUid: 'uid-sara',
        );
        await household.acceptInvitation('K7QM2XRP9D');
        await settle();
        var prepared = false;
        final ok = await household.leaveHousehold(
          prepare: () async {
            prepared = true;
            expect(household.isRunning(HouseholdAction.leave), isTrue);
            throw const HouseholdException(
              '2 shared change(s) are not uploaded.',
            );
          },
        );
        expect(prepared, isTrue);
        expect(ok, isFalse);
        expect(household.isBusy, isFalse);
        expect(household.error, '2 shared change(s) are not uploaded.');
        expect(service.calls, isNot(contains('leave')));
        expect(household.hasHousehold, isTrue);
      },
    );
  });
}
