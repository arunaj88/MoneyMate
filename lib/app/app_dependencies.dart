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

/// The repositories and services backed by one account's on-device
/// database. Each signed-in account gets its own, so accounts sharing a
/// device never see each other's data.
class AccountData {
  const AccountData({
    required this.transactionRepository,
    required this.categoryRepository,
    required this.budgetRepository,
    required this.appSettingsRepository,
    required this.backupService,
    this.syncService,
    this.historySource,
    this.dataResetService,
    this.recurringRepository,
    this.savingsRepository,
  });

  /// Opens [uid]'s database and wires the SQLite-backed implementations.
  static Future<AccountData> open(
    String uid, {
    required AuthService authService,
    required CloudSavingsStore savingsCloud,
  }) async {
    final database = await AppDatabase.openForAccount(uid);
    final savings = SqliteSavingsRepository(database);
    final syncService = TransactionSyncService(
      local: SqliteLocalSyncStore(database),
      cloud: FirestoreTransactionStore(),
      settings: SqliteSettingsSyncStore(database),
      records: FirestoreRecordStore(),
      savingsLocal: savings,
      savingsCloud: savingsCloud,
    );
    return AccountData(
      transactionRepository: SqliteTransactionRepository(database),
      categoryRepository: SqliteCategoryRepository(database),
      budgetRepository: SqliteBudgetRepository(database),
      appSettingsRepository: SqliteAppSettingsRepository(database),
      backupService: SqliteBackupService(database),
      syncService: syncService,
      historySource: CloudHistoryLoader(syncService, authService),
      dataResetService: SyncDataResetService(syncService),
      recurringRepository: SqliteRecurringRepository(database),
      savingsRepository: savings,
    );
  }

  final TransactionRepository transactionRepository;
  final CategoryRepository categoryRepository;
  final BudgetRepository budgetRepository;
  final AppSettingsRepository appSettingsRepository;
  final BackupService backupService;

  /// Cloud sync; null disables it (used by widget tests).
  final TransactionSyncService? syncService;
  final TransactionHistorySource? historySource;

  /// Reset App (this device only) and Restore My Cloud Data; null hides
  /// them (builds without cloud).
  final DataResetService? dataResetService;

  /// Recurring transaction rules; null hides the Repeat option.
  final RecurringRepository? recurringRepository;

  /// Savings goals; null hides the savings feature.
  final SavingsRepository? savingsRepository;
}

/// Opens the data of the account with the given UID.
typedef AccountDataOpener = Future<AccountData> Function(String uid);

/// Long-lived services created once at start-up and injected through
/// MultiProvider. Tests construct this with in-memory fakes.
class AppDependencies {
  const AppDependencies({
    required this.preferences,
    required this.openAccount,
    required this.authService,
    this.fileService = const FileService(),
    this.connectivity,
    this.householdService,
    this.savingsCloud,
    this.profilePhotoService,
    this.photoPicker,
    this.pushMessaging,
    this.localNotifier = const NoopLocalNotifier(),
    this.notificationCloud,
  });

  /// Wires the Firebase- and SQLite-backed implementations. Account data
  /// is opened later, once it is known who signed in.
  static Future<AppDependencies> create() async {
    final prefs = await SharedPreferences.getInstance();
    // SQLite is the offline store; Firestore's own cache is not needed and
    // every sync read must come from the server.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );
    final authService = FirebaseAuthService();
    final localNotifier = SystemLocalNotifier.isSupported
        ? SystemLocalNotifier()
        : null;
    // Android channels exist before the first push arrives.
    unawaited(localNotifier?.prepare());
    final savingsCloud = FirestoreSavingsStore();
    return AppDependencies(
      preferences: prefs,
      openAccount: (uid) => AccountData.open(
        uid,
        authService: authService,
        savingsCloud: savingsCloud,
      ),
      authService: authService,
      connectivity: ConnectivityPlusMonitor(),
      householdService: FirebaseHouseholdService(),
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

  /// Opens a signed-in account's on-device data.
  final AccountDataOpener openAccount;
  final AuthService authService;
  final FileService fileService;
  final ConnectivityMonitor? connectivity;

  /// Household management; null disables households (widget tests).
  final HouseholdService? householdService;

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
