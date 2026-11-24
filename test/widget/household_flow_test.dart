import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/models/transaction_model.dart';

import '../helpers/app_harness.dart';
import '../helpers/fake_household_service.dart';
import '../helpers/fakes.dart';

void main() {
  final today = DateTime.now();

  Future<void> openAddForm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('addTransactionFab')));
    await tester.pumpAndSettle();
  }

  Finder scopeSegment(String label) => find.descendant(
    of: find.byKey(const Key('viewScopeSelector')),
    matching: find.text(label),
  );

  bool sharedSegmentEnabled(WidgetTester tester) {
    final selector = tester.widget<SegmentedButton<TransactionScope>>(
      find.byKey(const Key('scopeSelector')),
    );
    return selector.segments
        .firstWhere((s) => s.value == TransactionScope.shared)
        .enabled;
  }

  testWidgets('without a household, shared transactions are offered via '
      'create or join', (tester) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    await TestHarness(households: households).pump(tester);

    // No household: no scope switch on the dashboard.
    expect(find.byKey(const Key('viewScopeSelector')), findsNothing);
    // Sync is disabled in widget tests, so no sync status is shown.
    expect(find.byKey(const Key('syncStatusChip')), findsNothing);

    await openAddForm(tester);
    expect(find.byKey(const Key('scopeSelector')), findsOneWidget);
    expect(sharedSegmentEnabled(tester), isFalse);

    await tester.tap(find.byKey(const Key('createOrJoinHousehold')));
    await tester.pumpAndSettle();
    expect(find.text('Create a household'), findsOneWidget);
    expect(find.text('Join a household'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('householdNameField')),
      'Khan family',
    );
    await tester.tap(find.byKey(const Key('createHouseholdButton')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('householdName')), findsOneWidget);
    expect(find.text('Khan family'), findsOneWidget);
    expect(find.text('Sam Lee (you)'), findsOneWidget);
    expect(households.calls, ['create']);

    // Back on the form the shared option is now available.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(sharedSegmentEnabled(tester), isTrue);
  });

  testWidgets('a shared transaction records its creator and follows the '
      'dashboard filter', (tester) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    await households.createHousehold('Khan family');
    final harness = TestHarness(
      households: households,
      transactions: [
        tx(id: 'p', amountMinor: 1000, date: today, note: 'Personal lunch'),
      ],
    );
    await harness.pump(tester);

    expect(find.byKey(const Key('viewScopeSelector')), findsOneWidget);

    await openAddForm(tester);
    await tester.tap(find.text('Shared household'));
    await tester.pumpAndSettle();
    expect(find.text('Visible to everyone in Khan family'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('amountField')), '45');
    await tester.tap(find.text('Groceries'));
    await tester.ensureVisible(find.byKey(const Key('saveTransactionButton')));
    await tester.tap(find.byKey(const Key('saveTransactionButton')));
    await tester.pumpAndSettle();

    final saved = harness.transactions.items.firstWhere((t) => t.id != 'p');
    expect(saved.scope, TransactionScope.shared);
    expect(saved.householdId, 'house-1');
    expect(saved.createdBy, testUser.uid);
    expect(saved.createdByName, 'Sam Lee');

    // Personal view (the default) does not show it, and no combined view
    // is offered.
    expect(find.byKey(ValueKey('shared-${saved.id}')), findsNothing);
    expect(find.text('Combined'), findsNothing);
    expect(find.textContaining('Personal lunch'), findsOneWidget);

    await tester.tap(scopeSegment('Household'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('shared-${saved.id}')), findsOneWidget);
    expect(find.text('Shared · You'), findsOneWidget);
    expect(find.text('Household balance'), findsOneWidget);
    expect(find.text('Household budget progress'), findsOneWidget);
    // The personal transaction is not part of the household view.
    expect(find.textContaining('Personal lunch'), findsNothing);
    expect(find.text('Combined'), findsNothing);

    await tester.tap(scopeSegment('Personal'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('shared-${saved.id}')), findsNothing);
    expect(find.text('Total balance'), findsOneWidget);
  });

  testWidgets('creating a household on a slow network shows progress and '
      'ignores repeated taps', (tester) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    await TestHarness(households: households).pump(tester);
    await openAddForm(tester);
    await tester.tap(find.byKey(const Key('createOrJoinHousehold')));
    await tester.pumpAndSettle();

    households.gate = Completer<void>();
    await tester.enterText(
      find.byKey(const Key('householdNameField')),
      'Khan family',
    );
    await tester.tap(find.byKey(const Key('createHouseholdButton')));
    await tester.pump();

    expect(find.text('Creating household…'), findsOneWidget);
    expect(find.byKey(const Key('householdProgress')), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('createHouseholdButton')),
    );
    expect(button.onPressed, isNull);
    await tester.tap(
      find.byKey(const Key('createHouseholdButton')),
      warnIfMissed: false,
    );
    await tester.pump();

    households.gate!.complete();
    await tester.pumpAndSettle();
    expect(households.calls, ['create']);
    expect(find.byKey(const Key('householdProgress')), findsNothing);
    expect(find.byKey(const Key('householdName')), findsOneWidget);
    expect(
      find.text('Household created. Invite your partner next.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed create stops the loader and explains why', (
    tester,
  ) async {
    final households = FakeHouseholdService(uid: testUser.uid)..offline = true;
    await TestHarness(households: households).pump(tester);
    await openAddForm(tester);
    await tester.tap(find.byKey(const Key('createOrJoinHousehold')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('householdNameField')),
      'Khan family',
    );
    await tester.tap(find.byKey(const Key('createHouseholdButton')));
    await tester.pumpAndSettle();

    expect(
      find.text('You are offline. Connect to the internet and try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('householdProgress')), findsNothing);
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('createHouseholdButton')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('deleting a household confirms, shows progress and returns '
      'the dashboard to personal data', (tester) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    await households.createHousehold('Khan family');
    await TestHarness(households: households).pump(tester);
    expect(find.byKey(const Key('viewScopeSelector')), findsOneWidget);

    await openTab(tester, 'Settings');
    await tester.ensureVisible(find.byKey(const Key('householdTile')));
    await tester.tap(find.byKey(const Key('householdTile')));
    await tester.pumpAndSettle();

    // A failed attempt first: the tile becomes usable again.
    households.offline = true;
    await tester.ensureVisible(find.byKey(const Key('deleteHouseholdTile')));
    await tester.tap(find.byKey(const Key('deleteHouseholdTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(
      find.text('You are offline. Connect to the internet and try again.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('deleteHouseholdProgress')), findsNothing);
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('deleteHouseholdTile')))
          .enabled,
      isTrue,
    );

    // Cancelling the confirmation sends nothing.
    households.offline = false;
    await tester.tap(find.byKey(const Key('deleteHouseholdTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(households.calls.where((c) => c == 'delete'), hasLength(1));

    households.gate = Completer<void>();
    await tester.tap(find.byKey(const Key('deleteHouseholdTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    expect(find.text('Deleting household…'), findsOneWidget);
    expect(find.byKey(const Key('deleteHouseholdProgress')), findsOneWidget);
    expect(find.byKey(const Key('householdProgress')), findsOneWidget);
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('deleteHouseholdTile')))
          .enabled,
      isFalse,
    );
    // Further taps are ignored while it runs.
    await tester.tap(
      find.byKey(const Key('deleteHouseholdTile')),
      warnIfMissed: false,
    );
    await tester.pump();

    households.gate!.complete();
    await tester.pumpAndSettle();
    expect(households.calls.where((c) => c == 'delete'), hasLength(2));
    expect(find.text('Household deleted'), findsOneWidget);
    expect(find.text('Create a household'), findsOneWidget);
    expect(find.byKey(const Key('householdProgress')), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await openTab(tester, 'Dashboard');
    expect(find.byKey(const Key('viewScopeSelector')), findsNothing);
  });

  testWidgets('households are unavailable without cloud services', (
    tester,
  ) async {
    await TestHarness().pump(tester);
    await openAddForm(tester);
    expect(sharedSegmentEnabled(tester), isFalse);
    await tester.tap(find.byKey(const Key('createOrJoinHousehold')));
    await tester.pumpAndSettle();
    expect(find.text('Households are not available'), findsOneWidget);
  });
}
