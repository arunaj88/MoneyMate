import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants/app_constants.dart';
import '../core/services/backup_service.dart';
import '../core/services/file_service.dart';
import '../core/services/photo_picker.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/system_ui.dart';
import '../features/auth/screens/splash_screen.dart';
import '../providers/auth_provider.dart';
import '../providers/budget_provider.dart';
import '../providers/category_provider.dart';
import '../providers/dashboard_provider.dart';
import '../providers/household_provider.dart';
import '../providers/notification_provider.dart';
import '../providers/recurring_provider.dart';
import '../providers/report_provider.dart';
import '../providers/reset_provider.dart';
import '../providers/savings_provider.dart';
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
          create: (_) => AuthProvider(
            deps.authService,
            deps.preferences,
            photoService: deps.photoPicker == null
                ? null
                : deps.profilePhotoService,
          ),
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
        Provider<PhotoPicker?>.value(value: deps.photoPicker),
        Provider<TransactionRepository>.value(
          value: deps.transactionRepository,
        ),
        ChangeNotifierProvider<SettingsProvider>(
          create: (_) => SettingsProvider(deps.preferences),
        ),
        ChangeNotifierProvider<CategoryProvider>(
          create: (_) => CategoryProvider(deps.categoryRepository)..load(),
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
            deps.transactionRepository,
            history: deps.historySource,
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
              SavingsProvider(deps.savingsRepository, cloud: deps.savingsCloud),
          update: (_, auth, transactions, savings) =>
              savings!..attach(auth, transactions),
        ),
        ChangeNotifierProxyProvider4<
          SettingsProvider,
          CategoryProvider,
          TransactionProvider,
          SavingsProvider,
          DashboardProvider
        >(
          create: (_) => DashboardProvider(deps.transactionRepository),
          update: (_, settings, categories, transactions, savings, dashboard) =>
              dashboard!..updateDependencies(
                settings,
                categories,
                transactions,
                savings,
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
            budgetRepository: deps.budgetRepository,
            transactionRepository: deps.transactionRepository,
            appSettingsRepository: deps.appSettingsRepository,
            history: deps.historySource,
            alertSink: context.read<NotificationProvider>(),
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
          create: (_) => SyncProvider(
            service: deps.syncService,
            connectivity: deps.connectivity,
          ),
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
            deps.recurringRepository,
            sink: context.read<NotificationProvider>(),
          ),
          update: (_, transactions, recurring) =>
              recurring!..attach(transactions),
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
