import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/data_reset_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/shared/widgets/transaction_tile.dart';

import '../helpers/app_harness.dart';
import '../helpers/fake_household_service.dart';
import '../helpers/fakes.dart';

/// A device to lay the app out on: logical size, system insets and the
/// user's font scale.
class _Device {
  const _Device(
    this.name,
    this.size, {
    this.padding = EdgeInsets.zero,
    this.textScale = 1.0,
    this.keyboard = 0,
  });

  final String name;
  final Size size;
  final EdgeInsets padding;
  final double textScale;

  /// Height of the on-screen keyboard while a form field is in use.
  final double keyboard;
}

const _devices = [
  // Small Android phone (e.g. 4" / 320dp wide), large font.
  _Device(
    'small Android 320x568 @1.3x text',
    Size(320, 568),
    padding: EdgeInsets.only(top: 24, bottom: 16),
    textScale: 1.3,
    keyboard: 230,
  ),
  _Device(
    'Android 360x640 @2.0x text',
    Size(360, 640),
    padding: EdgeInsets.only(top: 24, bottom: 48), // three-button nav bar
    textScale: 2.0,
    keyboard: 260,
  ),
  _Device(
    'iPhone SE 375x667',
    Size(375, 667),
    padding: EdgeInsets.only(top: 20),
    keyboard: 260,
  ),
  _Device(
    'iPhone 15 Pro 393x852 (Dynamic Island) @1.3x text',
    Size(393, 852),
    padding: EdgeInsets.only(top: 59, bottom: 34),
    textScale: 1.3,
    keyboard: 336,
  ),
  _Device(
    'iPhone Pro Max 430x932',
    Size(430, 932),
    padding: EdgeInsets.only(top: 59, bottom: 34),
    keyboard: 346,
  ),
  _Device(
    'Android landscape 640x360',
    Size(640, 360),
    padding: EdgeInsets.only(top: 24, right: 48),
    keyboard: 180,
  ),
  _Device(
    'iPhone landscape 852x393 (notch sides)',
    Size(852, 393),
    padding: EdgeInsets.only(left: 59, right: 59, bottom: 21),
    keyboard: 200,
  ),
  _Device(
    'Tablet 800x1280 @1.5x text',
    Size(800, 1280),
    padding: EdgeInsets.only(top: 24, bottom: 48),
    textScale: 1.5,
    keyboard: 400,
  ),
];

class _Reset implements DataResetService {
  @override
  Future<void> clearDevice() async {}

  @override
  Future<bool> isRestorePending() async => true;

  @override
  Future<SyncResult> restoreCloudData(
    String uid, {
    String? householdId,
    RestoreProgressCallback? onProgress,
  }) async => SyncResult(SyncOutcome.completed, SyncReport());
}

void main() {
  final today = DateTime.now();

  /// Large amounts and long notes: the worst case for every row.
  List<TransactionModel> stressData() => [
    tx(
      id: 'salary',
      amountMinor: 987654321,
      date: today,
      type: TransactionType.income,
      categoryId: 'inc_salary',
      note: 'Monthly salary including the yearly performance bonus payment',
    ),
    for (var i = 0; i < 6; i++)
      tx(
        id: 'exp$i',
        amountMinor: 12345678 + i * 1000,
        date: today.subtract(Duration(days: i)),
        categoryId: i.isEven ? 'exp_food' : 'exp_transport',
        note: 'A rather long description that will not fit on one line',
      ),
    tx(
      id: 'shared',
      amountMinor: 45678900,
      date: today,
      householdId: 'house-1',
      createdBy: 'uid-2',
    ),
  ];

  Future<FakeHouseholdService> household() async {
    final service = FakeHouseholdService(uid: testUser.uid);
    await service.createHousehold('The Very Long Household Name Family');
    service.members = [
      ...service.members,
      const HouseholdMember(
        uid: 'uid-2',
        role: HouseholdRole.member,
        status: MembershipStatus.active,
        displayName: 'Alexandra Catherine Montgomery-Smith',
        email: 'alexandra.catherine.montgomery.smith@example.com',
      ),
    ];
    return service;
  }

  for (final device in _devices) {
    testWidgets('every screen lays out without errors on ${device.name}', (
      tester,
    ) async {
      final errors = <String>[];
      var where = 'start-up';
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        final text = details.exceptionAsString().split('\n').first;
        // The overflowing widget and its nearest ancestors, to locate it.
        final source = RegExp(
          r'(\w+:file:///\S+)',
        ).firstMatch(details.toString())?.group(1);
        errors.add('[$where] $text ${source ?? ''}');
        if (text.contains('overflowed')) {
          // ignore: avoid_print
          print('OVERFLOW DETAIL [$where] $details END DETAIL');
        }
      };

      tester.platformDispatcher.textScaleFactorTestValue = device.textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      Future<void> settle() => tester.pumpAndSettle();

      Future<void> keyboard(bool open) async {
        final dpr = tester.view.devicePixelRatio;
        tester.view.viewInsets = open
            ? FakeViewPadding(bottom: device.keyboard * dpr)
            : FakeViewPadding.zero;
        await settle();
      }

      /// Where a finger can drag the current screen's list: the left margin,
      /// clear of charts and buttons, inside the safe area.
      Offset dragPoint() => Offset(
        device.padding.left + 10,
        device.padding.top + (device.size.height - device.padding.vertical) / 2,
      );

      Future<void> swipe(double dy, int times) async {
        for (var i = 0; i < times; i++) {
          await tester.dragFrom(dragPoint(), Offset(0, dy));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await settle();
      }

      /// Scrolls the visible list to the bottom and back to the top, so
      /// every row is laid out at least once.
      Future<void> scrollThrough() async {
        await swipe(-400, 30);
        await swipe(400, 30);
      }

      Future<void> tapVisible(Finder finder) async {
        // Lazy lists build only what is on screen: scroll until it exists.
        for (final dy in [-200.0, 200.0]) {
          for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
            await swipe(dy, 1);
          }
        }
        await tester.ensureVisible(finder.first);
        await settle();
        await tester.tap(finder.first, warnIfMissed: false);
        await settle();
      }

      Future<void> back() async {
        final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
        nav.pop();
        await settle();
      }

      try {
        final households = await household();
        await TestHarness(
          transactions: stressData(),
          households: households,
          dataReset: _Reset(),
        ).pump(tester, logicalSize: device.size, padding: device.padding);

        // Dashboard: personal, then household.
        where = 'dashboard';
        await scrollThrough();
        where = 'dashboard (household)';
        final householdSegment = find.descendant(
          of: find.byKey(const Key('viewScopeSelector')),
          matching: find.text('Household'),
        );
        if (householdSegment.evaluate().isNotEmpty) {
          await tapVisible(householdSegment);
          await scrollThrough();
        }

        // Transactions, with the keyboard open on the search field.
        where = 'transactions';
        await openTab(tester, 'Transactions');
        await scrollThrough();
        where = 'transactions (keyboard)';
        await tester.tap(find.byKey(const Key('transactionSearchField')));
        await keyboard(true);
        await keyboard(false);
        FocusManager.instance.primaryFocus?.unfocus();
        await settle();

        // Add form: keyboard, validation errors, scrolled to the button.
        where = 'add transaction';
        await openTab(tester, 'Dashboard');
        await tester.tap(find.byKey(const Key('addTransactionFab')));
        await settle();
        await keyboard(true);
        await tapVisible(find.byKey(const Key('saveTransactionButton')));
        await keyboard(false);
        where = 'date picker';
        await tapVisible(find.text('Date'));
        await back();
        where = 'add transaction';
        await back();

        // Edit form.
        where = 'edit transaction';
        await openTab(tester, 'Transactions');
        await tapVisible(find.byType(TransactionTile));
        await keyboard(true);
        await scrollThrough();
        await keyboard(false);
        where = 'delete dialog';
        await tapVisible(find.byTooltip('Delete'));
        await tapVisible(find.text('Cancel'));
        await back();

        // Budget: target dialog and category budget sheet with keyboard.
        where = 'budget';
        await openTab(tester, 'Budget');
        await scrollThrough();
        where = 'budget target dialog';
        await tapVisible(find.byKey(const Key('setTarget-weekly')));
        await keyboard(true);
        await tapVisible(find.text('Save'));
        await keyboard(false);
        await tapVisible(find.text('Cancel'));
        where = 'category budget sheet';
        await tapVisible(find.byKey(const Key('addCategoryBudget-weekly')));
        await keyboard(true);
        await keyboard(false);
        await back();
        where = 'budget (monthly)';
        await scrollThrough();
        await tapVisible(
          find.descendant(
            of: find.byKey(const Key('budgetPeriodSelector')),
            matching: find.text('Monthly'),
          ),
        );
        await scrollThrough();

        // Reports.
        where = 'reports';
        await openTab(tester, 'Reports');
        await scrollThrough();

        // Settings and everything reached from it.
        where = 'settings';
        await openTab(tester, 'Settings');
        await scrollThrough();
        where = 'currency sheet';
        await tapVisible(find.text('Currency'));
        await back();
        where = 'first day dialog';
        await tapVisible(find.text('First day of the week'));
        await back();
        where = 'reset dialog';
        await tapVisible(find.byKey(const Key('resetAppTile')));
        await tapVisible(find.text('Cancel'));
        where = 'restore dialog';
        await tapVisible(find.byKey(const Key('restoreCloudDataTile')));
        await tapVisible(find.text('Cancel'));
        where = 'sign out dialog';
        await tapVisible(find.byKey(const Key('signOutTile')));
        await tapVisible(find.text('Cancel'));

        where = 'categories';
        await tapVisible(find.text('Manage categories'));
        await scrollThrough();
        where = 'category editor';
        await tapVisible(find.text('New category'));
        await keyboard(true);
        await keyboard(false);
        await back();
        await back();

        where = 'household';
        await tapVisible(find.byKey(const Key('householdTile')));
        await scrollThrough();
        where = 'invite sheet';
        await tapVisible(find.byKey(const Key('inviteMemberButton')));
        await keyboard(true);
        await keyboard(false);
        await back();
        where = 'rename dialog';
        await tapVisible(find.byKey(const Key('renameHouseholdTile')));
        await keyboard(true);
        await keyboard(false);
        await tapVisible(find.text('Cancel'));
        await back();
      } catch (error, stack) {
        final message = error.toString().split('\n').first;
        final line = stack
            .toString()
            .split('\n')
            .firstWhere(
              (l) => l.contains('responsive_layout_test'),
              orElse: () => '',
            );
        errors.add('[$where] step failed: $message $line');
        // ignore: avoid_print
        print('STEP STACK [$where]\n$stack');
        final texts = find
            .byType(Text)
            .hitTestable()
            .evaluate()
            .map((e) => (e.widget as Text).data)
            .whereType<String>()
            .take(30)
            .join(' | ');
        // ignore: avoid_print
        print('VISIBLE TEXT [$where] $texts');
      } finally {
        FlutterError.onError = previous;
      }
      expect(errors, isEmpty, reason: errors.toSet().join('\n'));
    });
  }
}
