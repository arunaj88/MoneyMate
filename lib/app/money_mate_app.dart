import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/services/file_service.dart';
import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/theme/system_ui.dart';
import 'package:money_mate/features/auth/screens/splash_screen.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/dashboard_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/notification_provider.dart';
import 'package:money_mate/providers/recurring_provider.dart';
import 'package:money_mate/providers/report_provider.dart';
import 'package:money_mate/providers/reset_provider.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/repositories/transaction_repository.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/keyboard_dismiss.dart';
import 'package:money_mate/app/account_session.dart';
import 'package:money_mate/app/app_dependencies.dart';
import 'package:money_mate/app/auth_navigator.dart';

/// Root widget: dependency injection, theming and navigation.
class MoneyMateApp extends StatefulWidget {
  const MoneyMateApp({
    super.key,
    required this.dependencies,
    this.minSplashDuration = const Duration(milliseconds: 900),
  });

  final AppDependencies dependencies;

  /// Shortest time the splash screen stays visible, so it does not flash.
  final Duration minSplashDuration;

  @override
  State<MoneyMateApp> createState() => _MoneyMateAppState();
}

class _MoneyMateAppState extends State<MoneyMateApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  void _showOpenFailed() {
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    showAppSnackBar(context, AccountSession.openFailedMessage, isError: true);
  }

  @override
  Widget build(BuildContext context) {
    final deps = widget.dependencies;
    // App-wide state only. Everything stored in an account's database is
    // provided per account, around the navigator (see _AccountScope).
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(
            deps.authService,
            deps.preferences,
            photoService: deps.photoPicker == null
                ? null
                : deps.profilePhotoService,
          ),
        ),
        ChangeNotifierProvider<AccountSession>(
          lazy: false,
          create: (context) => AccountSession(
            context.read<AuthProvider>(),
            deps.openAccount,
            onOpenFailed: _showOpenFailed,
          ),
        ),
        Provider<FileService>.value(value: deps.fileService),
        Provider<PhotoPicker?>.value(value: deps.photoPicker),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(deps.preferences),
        ),
      ],
      child: Selector<SettingsProvider, ThemeMode>(
        selector: (_, s) => s.themeMode,
        builder: (context, themeMode, _) => MaterialApp(
          navigatorKey: _navigatorKey,
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeMode,
          // Edge-to-edge, transparent system bars on every screen.
          builder: (context, child) => AuthNavigator(
            auth: context.read<AuthProvider>(),
            session: context.read<AccountSession>(),
            navigatorKey: _navigatorKey,
            minSplashDuration: widget.minSplashDuration,
            child: _AccountScope(
              dependencies: deps,
              child: SystemUiOverlay(
                child: DismissKeyboardOnTap(
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          home: const SplashScreen(),
        ),
      ),
    );
  }
}

/// Provides the open account's data to every screen.
///
/// The providers are keyed by the account, so when another account signs in
/// they are all disposed and created again from that account's database:
/// nothing cached in memory carries over. The navigator below keeps its
/// state (it has a global key), and [AuthNavigator] shows the home screen
/// only once the new account's data is ready.
class _AccountScope extends StatelessWidget {
  const _AccountScope({required this.dependencies, required this.child});

  final AppDependencies dependencies;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AccountSession>();
    final data = session.data;
    if (data == null) return child;
    return MultiProvider(
      key: ValueKey(session.uid),
      providers: _accountProviders(dependencies, data),
      child: child,
    );
  }
}

List<SingleChildWidget> _accountProviders(
  AppDependencies deps,
  AccountData data,
) => [
  ChangeNotifierProxyProvider<AuthProvider, HouseholdProvider>(
    lazy: false,
    create: (_) => HouseholdProvider(
      service: deps.householdService,
      preferences: deps.preferences,
    ),
    update: (_, auth, household) => household!..updateAuth(auth),
  ),
  ChangeNotifierProxyProvider<HouseholdProvider, TransactionScopeProvider>(
    create: (_) => TransactionScopeProvider(deps.preferences),
    update: (_, household, scope) => scope!..updateHousehold(household),
  ),
  Provider<BackupService>.value(value: data.backupService),
  Provider<TransactionRepository>.value(value: data.transactionRepository),
  ChangeNotifierProvider<CategoryProvider>(
    create: (_) => CategoryProvider(data.categoryRepository)..load(),
  ),
  ChangeNotifierProxyProvider3<
    AuthProvider,
    SettingsProvider,
    CategoryProvider,
    NotificationProvider
  >(
    // Not lazy: registers for pushes and shows them from start-up.
    lazy: false,
    create: (_) => NotificationProvider(
      preferences: deps.preferences,
      push: deps.pushMessaging,
      local: deps.localNotifier,
      cloud: deps.notificationCloud,
    ),
    update: (_, auth, settings, categories, notifications) =>
        notifications!..attach(auth, settings, categories),
  ),
  ChangeNotifierProxyProvider2<
    CategoryProvider,
    TransactionScopeProvider,
    TransactionProvider
  >(
    create: (_) => TransactionProvider(
      data.transactionRepository,
      history: data.historySource,
    )..load(),
    update: (_, categories, scope, transactions) => transactions!
      ..onScopeChanged(scope)
      ..onCategoriesChanged(categories),
  ),
  ChangeNotifierProxyProvider2<
    AuthProvider,
    TransactionProvider,
    SavingsProvider
  >(
    create: (_) =>
        SavingsProvider(data.savingsRepository, cloud: deps.savingsCloud),
    update: (_, auth, transactions, savings) =>
        savings!..attach(auth, transactions),
  ),
  ChangeNotifierProxyProvider5<
    AuthProvider,
    TransactionProvider,
    HouseholdProvider,
    SettingsProvider,
    NotificationProvider,
    LoanProvider
  >(
    // Not lazy: repayment reminders are planned from start-up.
    lazy: false,
    create: (_) => LoanProvider(
      data.loanRepository,
      cloud: deps.loansCloud,
      notifier: deps.localNotifier,
    ),
    update:
        (_, auth, transactions, household, settings, notifications, loans) =>
            loans!..attach(
              auth: auth,
              transactions: transactions,
              household: household,
              settings: settings,
              notifications: notifications,
            ),
  ),
  ChangeNotifierProxyProvider5<
    SettingsProvider,
    CategoryProvider,
    TransactionProvider,
    SavingsProvider,
    LoanProvider,
    DashboardProvider
  >(
    create: (_) => DashboardProvider(data.transactionRepository),
    update:
        (_, settings, categories, transactions, savings, loans, dashboard) =>
            dashboard!..updateDependencies(
              settings,
              categories,
              transactions,
              savings,
              loans,
            ),
  ),
  ChangeNotifierProxyProvider4<
    SettingsProvider,
    CategoryProvider,
    TransactionProvider,
    HouseholdProvider,
    BudgetProvider
  >(
    create: (context) => BudgetProvider(
      budgetRepository: data.budgetRepository,
      transactionRepository: data.transactionRepository,
      appSettingsRepository: data.appSettingsRepository,
      history: data.historySource,
      alertSink: context.read<NotificationProvider>(),
    ),
    update: (_, settings, categories, transactions, household, budget) =>
        budget!
          ..updateDependencies(settings, categories, transactions, household),
  ),
  ChangeNotifierProxyProvider3<
    SettingsProvider,
    CategoryProvider,
    TransactionProvider,
    ReportProvider
  >(
    create: (_) =>
        ReportProvider(data.transactionRepository, history: data.historySource),
    update: (_, settings, categories, transactions, report) =>
        report!..updateDependencies(settings, categories, transactions),
  ),
  ChangeNotifierProxyProvider6<
    AuthProvider,
    HouseholdProvider,
    CategoryProvider,
    TransactionProvider,
    BudgetProvider,
    SavingsProvider,
    SyncProvider
  >(
    // Not lazy: sync runs in the background from start-up.
    lazy: false,
    create: (context) =>
        SyncProvider(service: data.syncService, connectivity: deps.connectivity)
          ..watchLoans(context.read<LoanProvider>()),
    update:
        (
          _,
          auth,
          household,
          categories,
          transactions,
          budgets,
          savings,
          sync,
        ) => sync!
          ..updateDependencies(
            auth,
            categories,
            transactions,
            household: household,
            budgets: budgets,
            savings: savings,
          ),
  ),
  ChangeNotifierProxyProvider<TransactionProvider, RecurringProvider>(
    // Not lazy: due occurrences are added at start-up.
    lazy: false,
    create: (context) => RecurringProvider(
      data.recurringRepository,
      sink: context.read<NotificationProvider>(),
    ),
    update: (_, transactions, recurring) => recurring!..attach(transactions),
  ),
  ChangeNotifierProvider<ResetProvider>(
    create: (_) => ResetProvider(data.dataResetService),
  ),
];
