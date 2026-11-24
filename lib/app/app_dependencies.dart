import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/database/app_database.dart';
import '../core/services/auth_service.dart';
import '../core/services/backup_service.dart';
import '../core/services/cloud_history_loader.dart';
import '../core/services/cloud_transaction_store.dart';
import '../core/services/connectivity_monitor.dart';
import '../core/services/data_reset_service.dart';
import '../core/services/file_service.dart';
import '../core/services/household_service.dart';
import '../core/services/transaction_sync_service.dart';
import '../repositories/app_settings_repository.dart';
import '../repositories/budget_repository.dart';
import '../repositories/category_repository.dart';
import '../repositories/recurring_repository.dart';
import '../repositories/settings_sync_repository.dart';
import '../repositories/sync_repository.dart';
import '../repositories/transaction_repository.dart';

/// Long-lived services created once at start-up and injected through
/// MultiProvider. Tests construct this with in-memory fakes.
class AppDependencies {
  const AppDependencies({
    required this.preferences,
    required this.transactionRepository,
    required this.categoryRepository,
    required this.budgetRepository,
    required this.appSettingsRepository,
    required this.backupService,
    required this.authService,
    this.fileService = const FileService(),
    this.syncService,
    this.historySource,
    this.connectivity,
    this.householdService,
    this.dataResetService,
    this.recurringRepository,
  });

  /// Opens the database and wires the SQLite-backed implementations.
  static Future<AppDependencies> create() async {
    final database = await AppDatabase.open();
    final prefs = await SharedPreferences.getInstance();
    // SQLite is the offline store; Firestore's own cache is not needed and
    // every sync read must come from the server.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );
    final authService = FirebaseAuthService();
    final syncService = TransactionSyncService(
      local: SqliteLocalSyncStore(database),
      cloud: FirestoreTransactionStore(),
      settings: SqliteSettingsSyncStore(database),
      records: FirestoreRecordStore(),
    );
    return AppDependencies(
      preferences: prefs,
      transactionRepository: SqliteTransactionRepository(database),
      categoryRepository: SqliteCategoryRepository(database),
      budgetRepository: SqliteBudgetRepository(database),
      appSettingsRepository: SqliteAppSettingsRepository(database),
      backupService: SqliteBackupService(database),
      authService: authService,
      syncService: syncService,
      historySource: CloudHistoryLoader(syncService, authService),
      connectivity: ConnectivityPlusMonitor(),
      householdService: FirebaseHouseholdService(),
      dataResetService: SyncDataResetService(syncService),
      recurringRepository: SqliteRecurringRepository(database),
    );
  }

  final SharedPreferences preferences;
  final TransactionRepository transactionRepository;
  final CategoryRepository categoryRepository;
  final BudgetRepository budgetRepository;
  final AppSettingsRepository appSettingsRepository;
  final BackupService backupService;
  final AuthService authService;
  final FileService fileService;

  /// Cloud sync; null disables it (used by widget tests).
  final TransactionSyncService? syncService;
  final TransactionHistorySource? historySource;
  final ConnectivityMonitor? connectivity;

  /// Household management; null disables households (widget tests).
  final HouseholdService? householdService;

  /// Reset App (this device only) and Restore My Cloud Data; null hides
  /// them (builds without cloud).
  final DataResetService? dataResetService;

  /// Recurring transaction rules; null hides the Repeat option.
  final RecurringRepository? recurringRepository;
}
