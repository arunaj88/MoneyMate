import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:money_mate/core/database/app_database.dart';
import 'package:money_mate/core/services/auth_service.dart';
import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/services/cloud_savings_store.dart';
import 'package:money_mate/core/services/cloud_history_loader.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/core/services/connectivity_monitor.dart';
import 'package:money_mate/core/services/data_reset_service.dart';
import 'package:money_mate/core/services/file_service.dart';
import 'package:money_mate/core/services/household_service.dart';
import 'package:money_mate/core/services/notification_cloud.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/repositories/app_settings_repository.dart';
import 'package:money_mate/repositories/budget_repository.dart';
import 'package:money_mate/repositories/category_repository.dart';
import 'package:money_mate/repositories/recurring_repository.dart';
import 'package:money_mate/repositories/savings_repository.dart';
import 'package:money_mate/repositories/settings_sync_repository.dart';
import 'package:money_mate/repositories/sync_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';

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
    this.savingsRepository,
    this.savingsCloud,
    this.profilePhotoService,
    this.photoPicker,
    this.pushMessaging,
    this.localNotifier = const NoopLocalNotifier(),
    this.notificationCloud,
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
    final savings = SqliteSavingsRepository(database);
    final savingsCloud = FirestoreSavingsStore();
    final localNotifier = SystemLocalNotifier.isSupported
        ? SystemLocalNotifier()
        : null;
    // Android channels exist before the first push arrives.
    unawaited(localNotifier?.prepare());
    final syncService = TransactionSyncService(
      local: SqliteLocalSyncStore(database),
      cloud: FirestoreTransactionStore(),
      settings: SqliteSettingsSyncStore(database),
      records: FirestoreRecordStore(),
      savingsLocal: savings,
      savingsCloud: savingsCloud,
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
      savingsRepository: savings,
      savingsCloud: savingsCloud,
      profilePhotoService: FirebaseProfilePhotoService(),
      photoPicker: ImagePickerPhotoPicker(),
      pushMessaging: FirebasePushMessaging.isSupported
          ? FirebasePushMessaging()
          : null,
      localNotifier: localNotifier ?? const NoopLocalNotifier(),
      notificationCloud: FirestoreNotificationCloud(),
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

  /// Savings goals; null hides the savings feature.
  final SavingsRepository? savingsRepository;

  /// Household and shared savings in the cloud; null keeps savings
  /// personal-only (widget tests).
  final CloudSavingsStore? savingsCloud;

  /// Profile photo storage; null hides "Change photo".
  final ProfilePhotoService? profilePhotoService;

  /// Gallery / camera picker for the profile photo; null hides
  /// "Change photo".
  final PhotoPicker? photoPicker;

  /// Push notifications (FCM); null where unsupported (desktop, tests).
  final PushMessaging? pushMessaging;

  /// System notifications on this device.
  final LocalNotifier localNotifier;

  /// Push registrations and household budget alerts in the cloud.
  final NotificationCloud? notificationCloud;
}
