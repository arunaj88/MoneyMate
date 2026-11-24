import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants/app_constants.dart';
import '../core/services/backup_service.dart';
import '../core/services/file_service.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/system_ui.dart';
import '../features/auth/screens/splash_screen.dart';
import '../providers/auth_provider.dart';
import '../providers/budget_provider.dart';
import '../providers/category_provider.dart';
import '../providers/dashboard_provider.dart';
import '../providers/household_provider.dart';
import '../providers/report_provider.dart';
import '../providers/reset_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/sync_provider.dart';
import '../providers/transaction_provider.dart';
import '../providers/transaction_scope_provider.dart';
import '../repositories/transaction_repository.dart';
import '../shared/widgets/keyboard_dismiss.dart';
import 'app_dependencies.dart';
import 'auth_navigator.dart';

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

  @override
  Widget build(BuildContext context) {
    final deps = widget.dependencies;
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(
          create: (_) => AuthProvider(deps.authService, deps.preferences),
        ),
        ChangeNotifierProxyProvider<AuthProvider, HouseholdProvider>(
          lazy: false,
          create: (_) => HouseholdProvider(
            service: deps.householdService,
            preferences: deps.preferences,
          ),
          update: (_, auth, household) => household!..updateAuth(auth),
        ),
        ChangeNotifierProxyProvider<
          HouseholdProvider,
          TransactionScopeProvider
        >(
          create: (_) => TransactionScopeProvider(deps.preferences),
          update: (_, household, scope) => scope!..updateHousehold(household),
        ),
        Provider<BackupService>.value(value: deps.backupService),
        Provider<FileService>.value(value: deps.fileService),
        Provider<TransactionRepository>.value(
          value: deps.transactionRepository,
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(deps.preferences),
        ),
        ChangeNotifierProvider<CategoryProvider>(
          create: (_) => CategoryProvider(deps.categoryRepository)..load(),
        ),
        ChangeNotifierProxyProvider2<
          CategoryProvider,
          TransactionScopeProvider,
          TransactionProvider
        >(
          create: (_) => TransactionProvider(
            deps.transactionRepository,
            history: deps.historySource,
          )..load(),
          update: (_, categories, scope, transactions) => transactions!
            ..onScopeChanged(scope)
            ..onCategoriesChanged(categories),
        ),
        ChangeNotifierProxyProvider3<
          SettingsProvider,
          CategoryProvider,
          TransactionProvider,
          DashboardProvider
        >(
          create: (_) => DashboardProvider(deps.transactionRepository),
          update: (_, settings, categories, transactions, dashboard) =>
              dashboard!
                ..updateDependencies(settings, categories, transactions),
        ),
        ChangeNotifierProxyProvider4<
          SettingsProvider,
          CategoryProvider,
          TransactionProvider,
          HouseholdProvider,
          BudgetProvider
        >(
          create: (_) => BudgetProvider(
            budgetRepository: deps.budgetRepository,
            transactionRepository: deps.transactionRepository,
            appSettingsRepository: deps.appSettingsRepository,
            history: deps.historySource,
          ),
          update: (_, settings, categories, transactions, household, budget) =>
              budget!..updateDependencies(
                settings,
                categories,
                transactions,
                household,
              ),
        ),
        ChangeNotifierProxyProvider3<
          SettingsProvider,
          CategoryProvider,
          TransactionProvider,
          ReportProvider
        >(
          create: (_) => ReportProvider(
            deps.transactionRepository,
            history: deps.historySource,
          ),
          update: (_, settings, categories, transactions, report) =>
              report!..updateDependencies(settings, categories, transactions),
        ),
        ChangeNotifierProxyProvider5<
          AuthProvider,
          HouseholdProvider,
          CategoryProvider,
          TransactionProvider,
          BudgetProvider,
          SyncProvider
        >(
          // Not lazy: sync runs in the background from start-up.
          lazy: false,
          create: (_) => SyncProvider(
            service: deps.syncService,
            connectivity: deps.connectivity,
          ),
          update:
              (_, auth, household, categories, transactions, budgets, sync) =>
                  sync!..updateDependencies(
                    auth,
                    categories,
                    transactions,
                    household: household,
                    budgets: budgets,
                  ),
        ),
        ChangeNotifierProvider<ResetProvider>(
          create: (_) => ResetProvider(deps.dataResetService),
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
            navigatorKey: _navigatorKey,
            minSplashDuration: widget.minSplashDuration,
            child: SystemUiOverlay(
              child: DismissKeyboardOnTap(
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
          home: const SplashScreen(),
        ),
      ),
    );
  }
}
