import '../../models/scope_models.dart';

/// Application-wide constants.
class AppConstants {
  AppConstants._();

  static const String appName = 'MoneyMate';
  static const String appVersion = '1.0.0';
  static const String appTagline = 'Offline-first personal expense tracker';

  static const String databaseName = 'money_mate.db';
  static const int databaseVersion = 4;

  /// Version of the JSON backup format. Bump when the structure changes.
  static const int backupSchemaVersion = 1;
  static const String backupAppId = 'MoneyMate';

  /// App IDs from earlier releases that are still accepted when restoring.
  static const List<String> legacyBackupAppIds = ['ExpenseMate'];

  /// Number of recent transactions shown on the dashboard.
  static const int recentTransactionsLimit = 5;

  /// Number of past periods shown in budget history.
  static const int weeklyHistoryCount = 8;
  static const int monthlyHistoryCount = 6;

  /// Days of transactions kept in the on-device database once they are
  /// safely stored in the cloud. Older ones are read from Firestore on
  /// demand. Can be overridden through [SyncKeys.retentionDays].
  static const int defaultLocalRetentionDays = 90;

  /// Smallest retention period accepted from settings.
  static const int minLocalRetentionDays = 30;

  /// Budget alert thresholds, in percent of the target consumed.
  static const double alertThreshold = 80;
  static const double warningThreshold = 90;
  static const double exceededThreshold = 100;
}

/// Keys used for values persisted in SharedPreferences.
class PrefKeys {
  PrefKeys._();

  static const String themeMode = 'settings.themeMode';
  static const String currencyCode = 'settings.currencyCode';
  static const String firstDayOfWeek = 'settings.firstDayOfWeek';
  static const String budgetAlertsEnabled = 'settings.budgetAlertsEnabled';
  static const String categoryAlertsEnabled = 'settings.categoryAlertsEnabled';

  /// JSON profile of the signed-in user (UID, name, email, photo URL).
  static const String userProfile = 'auth.userProfile';

  /// Dashboard / transactions view: personal or household (shared).
  static const String viewScope = 'household.viewScope';

  /// Cached household membership of a user (suffixed with the UID), so
  /// shared transactions can be added offline.
  static const String householdCachePrefix = 'household.cache.';
}

/// Keys used for cloud sync state stored in the AppSettings table.
class SyncKeys {
  SyncKeys._();

  /// Firebase UID that this device's data is synchronised with.
  static const String ownerUid = 'sync.owner_uid';

  /// Pull position: last server timestamp (µs) and document ID applied.
  static const String pullCursorMicros = 'sync.pull_cursor_micros';
  static const String pullCursorDocId = 'sync.pull_cursor_doc_id';

  /// When the last full sync cycle finished (ms since epoch).
  static const String lastSyncedAt = 'sync.last_synced_at';

  /// Optional override of [AppConstants.defaultLocalRetentionDays].
  static const String retentionDays = 'sync.retention_days';

  /// Set once personal cloud documents written before v3 have been given
  /// their `scope` / `ownerUid` / `createdBy` fields.
  static const String personalBackfillDone = 'sync.personal_backfill_v3';

  /// The personal data reset (ms since epoch, server time) this device has
  /// applied; see `users/{uid}.personalResetAt` in Firestore.
  static const String personalResetAt = 'sync.personal_reset_at';

  /// Set (to the reset time, ms since epoch) when the user reset this
  /// device's local data with Reset App. While present, sync uploads new
  /// local changes but downloads nothing from the cloud, so the app stays
  /// fresh until the user chooses Restore My Cloud Data. Removed only after
  /// a restore succeeded.
  static const String restorePending = 'sync.restore_pending';

  /// Pull cursor keys for [scope]. Personal data keeps the original keys
  /// so existing installs do not download everything again.
  static String cursorMicros(DataScope scope) => scope.isPersonal
      ? pullCursorMicros
      : 'sync.${scope.key}.pull_cursor_micros';

  static String cursorDocId(DataScope scope) => scope.isPersonal
      ? pullCursorDocId
      : 'sync.${scope.key}.pull_cursor_doc_id';
}
