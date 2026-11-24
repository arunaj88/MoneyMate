import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/data_reset_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/models/sync_models.dart';

import '../helpers/app_harness.dart';
import '../helpers/fake_household_service.dart';
import '../helpers/fakes.dart';

class _FakeReset implements DataResetService {
  Completer<void>? gate;
  bool deviceError = false;
  bool offline = false;
  bool pending = false;
  int deviceCalls = 0;
  int restoreCalls = 0;
  String? restoredHousehold;

  @override
  Future<void> clearDevice() async {
    deviceCalls++;
    if (gate != null) await gate!.future;
    if (deviceError) throw StateError('disk I/O error');
    pending = true;
  }

  @override
  Future<bool> isRestorePending() async => pending;

  @override
  Future<SyncResult> restoreCloudData(
    String uid, {
    String? householdId,
    RestoreProgressCallback? onProgress,
  }) async {
    restoreCalls++;
    restoredHousehold = householdId;
    onProgress?.call(const RestoreProgress(RestoreStep.personal, 0));
    if (gate != null) await gate!.future;
    if (offline) return SyncResult(SyncOutcome.offline, SyncReport());
    onProgress?.call(const RestoreProgress(RestoreStep.personal, 12));
    pending = false;
    return SyncResult(SyncOutcome.completed, SyncReport()..restored = true);
  }
}

void main() {
  Future<void> openTile(WidgetTester tester, Key key) async {
    await openTab(tester, 'Settings');
    await tester.scrollUntilVisible(
      find.byKey(key),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.byKey(key));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
  }

  testWidgets('hidden without cloud services', (tester) async {
    await TestHarness().pump(tester);
    await openTab(tester, 'Settings');
    expect(find.byKey(const Key('resetAppTile')), findsNothing);
    expect(find.byKey(const Key('restoreCloudDataTile')), findsNothing);
  });

  testWidgets('reset: confirmation, progress, success and fresh dashboard', (
    tester,
  ) async {
    final reset = _FakeReset()..gate = Completer<void>();
    await TestHarness(dataReset: reset).pump(tester);
    expect(find.byKey(const Key('restorePendingBanner')), findsNothing);

    await openTile(tester, const Key('resetAppTile'));
    expect(
      find.text(
        'Clear local app data and start fresh. Your cloud data will remain '
        'safe.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reset MoneyMate on this device?'), findsOneWidget);
    expect(
      find.text(
        'Your locally stored transactions, budgets and cached data will be '
        'cleared. Your Firebase cloud data will not be deleted. You can '
        'restore your data later.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('resetUnsyncedWarning')), findsNothing);

    // Cancel does nothing.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(reset.deviceCalls, 0);

    await tester.tap(find.byKey(const Key('resetAppTile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmResetButton')));
    await tester.pump();

    expect(find.byKey(const Key('resetProgressDialog')), findsOneWidget);
    expect(find.text('Resetting local data...'), findsOneWidget);
    // The tiles underneath cannot start a second run.
    expect(
      tester.widget<ListTile>(find.byKey(const Key('resetAppTile'))).enabled,
      isFalse,
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('restoreCloudDataTile')))
          .enabled,
      isFalse,
    );

    reset.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('resetProgressDialog')), findsNothing);
    expect(find.textContaining('Your cloud data is safe'), findsOneWidget);
    expect(find.textContaining('deleted'), findsNothing);
    expect(reset.deviceCalls, 1);
    expect(reset.restoreCalls, 0);

    await openTab(tester, 'Dashboard');
    expect(find.byKey(const Key('restorePendingBanner')), findsOneWidget);
    expect(find.text('No transactions yet'), findsOneWidget);
  });

  testWidgets('a reset failure is explained and can be retried', (
    tester,
  ) async {
    final reset = _FakeReset()..deviceError = true;
    await TestHarness(dataReset: reset).pump(tester);
    await openTile(tester, const Key('resetAppTile'));
    await tester.tap(find.byKey(const Key('confirmResetButton')));
    await tester.pumpAndSettle();

    expect(find.text('Reset did not finish'), findsOneWidget);
    expect(find.textContaining('Nothing was changed'), findsOneWidget);

    reset.deviceError = false;
    await tester.tap(find.byKey(const Key('retryResetButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your cloud data is safe'), findsOneWidget);
    expect(reset.deviceCalls, 2);
  });

  testWidgets('restore: confirmation, progress, then success', (tester) async {
    final households = FakeHouseholdService(uid: testUser.uid);
    households.codes['K7QM2XRP9D'] = const Household(
      id: 'house-2',
      name: 'Sara & Sam',
      ownerUid: 'uid-sara',
    );
    await households.acceptInvitation('K7QM2XRP9D');
    final reset = _FakeReset()
      ..pending = true
      ..gate = Completer<void>();
    await TestHarness(households: households, dataReset: reset).pump(tester);
    expect(find.byKey(const Key('restorePendingBanner')), findsOneWidget);

    await openTile(tester, const Key('restoreCloudDataTile'));
    expect(
      find.text(
        'Download your previously saved transactions and budgets from '
        'Firebase.',
      ),
      findsOneWidget,
    );
    expect(find.text('Restore your cloud data?'), findsOneWidget);
    expect(find.textContaining('Shared household data'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmRestoreButton')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('restoreProgressDialog')), findsOneWidget);
    expect(find.text('Your data · 0 items downloaded'), findsOneWidget);

    reset.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Your cloud data has been restored.'), findsOneWidget);
    expect(reset.restoreCalls, 1);
    expect(reset.restoredHousehold, 'house-2');

    await openTab(tester, 'Dashboard');
    expect(find.byKey(const Key('restorePendingBanner')), findsNothing);
  });

  testWidgets('an offline restore stays pending and can be retried', (
    tester,
  ) async {
    final reset = _FakeReset()
      ..pending = true
      ..offline = true;
    await TestHarness(dataReset: reset).pump(tester);
    await tester.tap(find.byKey(const Key('restoreBannerButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmRestoreButton')));
    await tester.pumpAndSettle();

    expect(find.text('Restore did not finish'), findsOneWidget);
    expect(find.textContaining('offline'), findsOneWidget);
    expect(reset.pending, isTrue);

    reset.offline = false;
    await tester.tap(find.byKey(const Key('retryRestoreButton')));
    await tester.pumpAndSettle();
    expect(find.text('Your cloud data has been restored.'), findsOneWidget);
    expect(reset.restoreCalls, 2);
    expect(find.byKey(const Key('restorePendingBanner')), findsNothing);
  });
}
