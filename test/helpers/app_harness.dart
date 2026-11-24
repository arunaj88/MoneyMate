import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/app/app_dependencies.dart';
import 'package:money_mate/app/money_mate_app.dart';
import 'package:money_mate/core/services/data_reset_service.dart';
import 'package:money_mate/core/services/household_service.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Pumps the full app with in-memory repositories and a fake auth service
/// (signed in as [testUser] unless another user, or null, is given).
class TestHarness {
  TestHarness({
    List<TransactionModel>? transactions,
    AppUser? user = testUser,
    this.households,
    this.dataReset,
  }) : auth = FakeAuthService(signedIn: user),
       transactions = InMemoryTransactionRepository(initial: transactions),
       categories = InMemoryCategoryRepository(),
       budgets = InMemoryBudgetRepository(),
       appSettings = InMemoryAppSettingsRepository();

  final FakeAuthService auth;
  final InMemoryTransactionRepository transactions;
  final InMemoryCategoryRepository categories;
  final InMemoryBudgetRepository budgets;
  final InMemoryAppSettingsRepository appSettings;

  /// Household management; null leaves households unavailable.
  final HouseholdService? households;

  /// Reset App; null hides it.
  final DataResetService? dataReset;

  /// Pumps the app on a 390x844 phone by default; pass [logicalSize],
  /// [devicePixelRatio] and system [padding] (status bar, notch, home
  /// indicator) to emulate other devices.
  Future<void> pump(
    WidgetTester tester, {
    Size logicalSize = const Size(390, 844),
    double devicePixelRatio = 3,
    EdgeInsets padding = EdgeInsets.zero,
  }) async {
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.view.physicalSize = logicalSize * devicePixelRatio;
    final physicalPadding = FakeViewPadding(
      left: padding.left * devicePixelRatio,
      top: padding.top * devicePixelRatio,
      right: padding.right * devicePixelRatio,
      bottom: padding.bottom * devicePixelRatio,
    );
    tester.view.padding = physicalPadding;
    tester.view.viewPadding = physicalPadding;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MoneyMateApp(
        dependencies: AppDependencies(
          preferences: prefs,
          transactionRepository: transactions,
          categoryRepository: categories,
          budgetRepository: budgets,
          appSettingsRepository: appSettings,
          backupService: FakeBackupService(),
          authService: auth,
          householdService: households,
          dataResetService: dataReset,
        ),
        minSplashDuration: Duration.zero,
      ),
    );
    await tester.pumpAndSettle();
  }
}

Future<void> openTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}
