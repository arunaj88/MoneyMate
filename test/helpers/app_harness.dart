import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/app/app_dependencies.dart';
import 'package:money_mate/app/money_mate_app.dart';
import 'package:money_mate/core/services/data_reset_service.dart';
import 'package:money_mate/core/services/file_service.dart';
import 'package:money_mate/core/services/household_service.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_loans.dart';
import 'fakes.dart';

/// Pumps the full app with in-memory repositories and a fake auth service
/// (signed in as [testUser] unless another user, or null, is given).
class TestHarness {
  TestHarness({
    List<TransactionModel>? transactions,
    AppUser? user = testUser,
    this.households,
    this.dataReset,
    bool withSavings = false,
    bool withLoans = false,
    this.photos,
    this.photoPicker,
    this.localNotifier,
    this.fileService,
  }) : savings = withSavings ? InMemorySavingsRepository() : null,
       loans = withLoans ? InMemoryLoanRepository() : null,
       auth = FakeAuthService(signedIn: user),
       transactions = InMemoryTransactionRepository(initial: transactions),
       categories = InMemoryCategoryRepository(),
       budgets = InMemoryBudgetRepository(),
       appSettings = InMemoryAppSettingsRepository() {
    recurring = InMemoryRecurringRepository(this.transactions);
  }

  final FakeAuthService auth;
  final InMemoryTransactionRepository transactions;
  final InMemoryCategoryRepository categories;
  final InMemoryBudgetRepository budgets;
  final InMemoryAppSettingsRepository appSettings;
  late final InMemoryRecurringRepository recurring;

  /// Savings goals; null (the default) leaves the feature hidden.
  final InMemorySavingsRepository? savings;

  /// Money lent; null (the default) leaves the feature hidden.
  final InMemoryLoanRepository? loans;

  /// Household management; null leaves households unavailable.
  final HouseholdService? households;

  /// Reset App; null hides it.
  final DataResetService? dataReset;

  /// Profile photo storage and picker; both are needed for "Change photo".
  final ProfilePhotoService? photos;
  final PhotoPicker? photoPicker;

  /// On-device notifications (and their taps); none by default.
  final LocalNotifier? localNotifier;

  /// Device files and the share sheet; the real service by default.
  final FileService? fileService;

  /// While set, opening an account's data waits for it (like a slow
  /// database open).
  Completer<void>? accountGate;

  /// On-device data per account UID, like the per-account databases.
  final Map<String, AccountData> _accounts = {};

  /// UIDs whose data the app opened, in order.
  List<String> get openedAccounts => List.unmodifiable(_accounts.keys);

  /// The repositories above belong to the first account that signs in.
  AccountData _firstAccount() => AccountData(
    transactionRepository: transactions,
    categoryRepository: categories,
    budgetRepository: budgets,
    appSettingsRepository: appSettings,
    backupService: FakeBackupService(),
    dataResetService: dataReset,
    recurringRepository: recurring,
    savingsRepository: savings,
    loanRepository: loans,
  );

  /// Every other account starts with an empty device database.
  AccountData _emptyAccount() {
    final transactions = InMemoryTransactionRepository();
    return AccountData(
      transactionRepository: transactions,
      categoryRepository: InMemoryCategoryRepository(),
      budgetRepository: InMemoryBudgetRepository(),
      appSettingsRepository: InMemoryAppSettingsRepository(),
      backupService: FakeBackupService(),
      dataResetService: dataReset,
      recurringRepository: InMemoryRecurringRepository(transactions),
      savingsRepository: savings == null ? null : InMemorySavingsRepository(),
      loanRepository: loans == null ? null : InMemoryLoanRepository(),
    );
  }

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
          openAccount: (uid) async {
            if (accountGate != null) await accountGate!.future;
            return _accounts.putIfAbsent(
              uid,
              () => _accounts.isEmpty ? _firstAccount() : _emptyAccount(),
            );
          },
          authService: auth,
          householdService: households,
          profilePhotoService: photos,
          photoPicker: photoPicker,
          localNotifier: localNotifier ?? const NoopLocalNotifier(),
          fileService: fileService ?? const FileService(),
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
