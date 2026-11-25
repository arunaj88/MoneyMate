import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:provider/provider.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/constants/currencies.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/notification_provider.dart';
import 'package:money_mate/providers/recurring_provider.dart';
import 'package:money_mate/providers/reset_provider.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/features/household/widgets/household_widgets.dart';
import 'package:money_mate/features/lending/lending_actions.dart';
import 'package:money_mate/features/savings/savings_actions.dart';
import 'package:money_mate/features/settings/data_management.dart';
import 'package:money_mate/features/settings/profile_photo.dart';
import 'package:money_mate/features/settings/reset_app.dart';
import 'package:money_mate/features/settings/screens/category_management_screen.dart';
import 'package:money_mate/features/settings/screens/recurring_screen.dart';

/// App preferences, notifications, data management and app information.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _pickCurrency(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.75,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text(
                  'Currency',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              RadioGroup<String>(
                groupValue: settings.currencyCode,
                onChanged: (v) => Navigator.of(context).pop(v),
                child: Column(
                  children: [
                    for (final c in Currencies.all)
                      RadioListTile<String>(
                        value: c.code,
                        title: Text('${c.code} · ${c.name}'),
                        secondary: Text(c.symbol.trim()),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (code != null) await settings.setCurrency(code);
  }

  Future<void> _pickFirstDay(BuildContext context) async {
    final settings = context.read<SettingsProvider>();
    final day = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('First day of the week'),
        children: [
          RadioGroup<int>(
            groupValue: settings.firstDayOfWeek,
            onChanged: (v) => Navigator.of(context).pop(v),
            child: Column(
              children: [
                for (final d in [
                  DateTime.monday,
                  DateTime.saturday,
                  DateTime.sunday,
                ])
                  RadioListTile<int>(
                    value: d,
                    title: Text(PeriodUtils.weekdayName(d)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (day != null) await settings.setFirstDayOfWeek(day);
  }

  Future<void> _signOut(BuildContext context) async {
    final auth = context.read<AuthProvider>();
    if (auth.isBusy) return;
    final confirmed = await showConfirmDialog(
      context,
      title: 'Sign out?',
      message:
          'Your transactions, budgets and categories stay saved on this '
          'device and will be here when you sign in again.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed) return;
    // On success AuthNavigator clears the stack and shows the login screen.
    final ok = await auth.signOut();
    if (!ok && context.mounted && auth.error != null) {
      showAppSnackBar(context, auth.error!, isError: true);
    }
  }

  static String _photoStatus(AuthProvider auth) {
    if (auth.isRunning(AuthAction.updatePhoto)) {
      final progress = auth.photoProgress;
      return progress == null || progress == 0
          ? 'Uploading…'
          : 'Uploading… ${(progress * 100).round()}%';
    }
    if (auth.isRunning(AuthAction.removePhoto)) return 'Removing…';
    return 'Gallery or camera · syncs to all your devices';
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final auth = context.watch<AuthProvider>();
    final notifications = context.watch<NotificationProvider>();
    final user = auth.user;
    final canChangePhoto =
        auth.canChangePhoto && context.read<PhotoPicker?>() != null;
    final data = DataManagement(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Spacing.lg, 0, Spacing.lg, 100),
        children: [
          const _GroupLabel('Account'),
          _SettingsCard(
            children: [
              ListTile(
                key: const Key('accountTile'),
                contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                leading: const AccountAvatar(radius: 24),
                title: Text(
                  user?.name ?? 'Not signed in',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: user?.email == null
                    ? null
                    : Text(
                        user!.email!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                trailing: canChangePhoto
                    ? const Icon(Icons.chevron_right_rounded)
                    : null,
                onTap: canChangePhoto && !auth.isBusy
                    ? () => changeProfilePhoto(context)
                    : null,
              ),
              if (canChangePhoto)
                ListTile(
                  key: const Key('changePhotoTile'),
                  leading: const Icon(Icons.add_a_photo_outlined),
                  title: Text(
                    user?.hasPhoto ?? false
                        ? 'Change profile photo'
                        : 'Add a profile photo',
                  ),
                  subtitle: Text(_photoStatus(auth)),
                  enabled: !auth.isBusy,
                  onTap: () => changeProfilePhoto(context),
                ),
              ListTile(
                key: const Key('signOutTile'),
                leading: auth.isRunning(AuthAction.signOut)
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : Icon(
                        Icons.logout_rounded,
                        color: Theme.of(context).colorScheme.error,
                      ),
                title: Text(
                  'Sign out',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                enabled: !auth.isBusy,
                onTap: () => _signOut(context),
              ),
            ],
          ),
          const _GroupLabel('Household'),
          const _HouseholdTile(),
          const _GroupLabel('Cloud sync'),
          const _SyncCard(),
          const _GroupLabel('Preferences'),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.payments_outlined),
                title: const Text('Currency'),
                subtitle: Text(
                  '${settings.currency.code} · ${settings.currency.name}',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickCurrency(context),
              ),
              ListTile(
                leading: const Icon(Icons.today_outlined),
                title: const Text('First day of the week'),
                subtitle: Text(
                  '${PeriodUtils.weekdayName(settings.firstDayOfWeek)} · used for weekly budgets',
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _pickFirstDay(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.palette_outlined),
                        SizedBox(width: 16),
                        Text('Theme'),
                      ],
                    ),
                    const SizedBox(height: Spacing.md),
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<ThemeMode>(
                        key: const Key('themeSelector'),
                        segments: const [
                          ButtonSegment(
                            value: ThemeMode.system,
                            label: Text('System'),
                            icon: Icon(Icons.brightness_auto_rounded),
                          ),
                          ButtonSegment(
                            value: ThemeMode.light,
                            label: Text('Light'),
                            icon: Icon(Icons.light_mode_rounded),
                          ),
                          ButtonSegment(
                            value: ThemeMode.dark,
                            label: Text('Dark'),
                            icon: Icon(Icons.dark_mode_rounded),
                          ),
                        ],
                        selected: {settings.themeMode},
                        onSelectionChanged: (s) =>
                            settings.setThemeMode(s.first),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const _GroupLabel('Notifications'),
          _SettingsCard(
            children: [
              if (notifications.pushSupported &&
                  auth.isAuthenticated &&
                  !notifications.permission.isGranted)
                const _NotificationPermissionTile(),
              SwitchListTile(
                key: const Key('budgetAlertsSwitch'),
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('Budget alerts'),
                subtitle: const Text(
                  'Weekly and monthly targets at 80%, 90% and 100%',
                ),
                value: settings.budgetAlertsEnabled,
                onChanged: settings.setBudgetAlertsEnabled,
              ),
              SwitchListTile(
                secondary: const Icon(Icons.donut_small_outlined),
                title: const Text('Category budget alerts'),
                subtitle: const Text('Alerts for individual category limits'),
                value: settings.categoryAlertsEnabled,
                onChanged: settings.setCategoryAlertsEnabled,
              ),
              if (context.select<RecurringProvider, bool>((r) => r.isAvailable))
                SwitchListTile(
                  key: const Key('recurringNotificationsSwitch'),
                  secondary: const Icon(Icons.event_repeat_rounded),
                  title: const Text('Recurring transactions'),
                  subtitle: const Text(
                    'When salary, rent and other repeats are added',
                  ),
                  value: settings.recurringNotifications,
                  onChanged: settings.setRecurringNotifications,
                ),
              if (notifications.pushSupported && auth.isAuthenticated) ...[
                SwitchListTile(
                  key: const Key('householdActivitySwitch'),
                  secondary: const Icon(Icons.groups_outlined),
                  title: const Text('Household activity'),
                  subtitle: const Text(
                    'Shared transactions by others, and members joining '
                    'or leaving',
                  ),
                  value: settings.householdActivityNotifications,
                  onChanged: settings.setHouseholdActivityNotifications,
                ),
                SwitchListTile(
                  key: const Key('householdBudgetSwitch'),
                  secondary: const Icon(Icons.account_balance_wallet_outlined),
                  title: const Text('Household budget alerts'),
                  subtitle: const Text(
                    'When a shared budget reaches 80%, 90% or 100% after '
                    "someone else's spending",
                  ),
                  value: settings.householdBudgetNotifications,
                  onChanged: settings.setHouseholdBudgetNotifications,
                ),
                SwitchListTile(
                  key: const Key('savingsNotificationsSwitch'),
                  secondary: const Icon(Icons.savings_outlined),
                  title: const Text('Savings goal updates'),
                  subtitle: const Text(
                    'Contributions to household and shared goals, and goals '
                    'reaching their target',
                  ),
                  value: settings.savingsNotifications,
                  onChanged: settings.setSavingsNotifications,
                ),
              ],
            ],
          ),
          const _GroupLabel('Categories'),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.category_outlined),
                title: const Text('Manage categories'),
                subtitle: const Text('Add, rename or remove custom categories'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const CategoryManagementScreen(),
                  ),
                ),
              ),
              if (context.select<SavingsProvider, bool>((s) => s.isAvailable))
                ListTile(
                  key: const Key('savingsTile'),
                  leading: const Icon(Icons.savings_outlined),
                  title: const Text('Savings goals'),
                  subtitle: const Text('Trips, emergency fund, gold and more'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openSavingsScreen(context),
                ),
              if (context.select<LoanProvider, bool>((l) => l.isAvailable))
                ListTile(
                  key: const Key('lendingTile'),
                  leading: const Icon(Icons.handshake_outlined),
                  title: const Text('Money lent'),
                  subtitle: const Text(
                    'Loans you gave, repayments and reminders',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openLendingScreen(context),
                ),
              if (context.select<RecurringProvider, bool>((r) => r.isAvailable))
                ListTile(
                  key: const Key('recurringTile'),
                  leading: const Icon(Icons.repeat_rounded),
                  title: const Text('Recurring transactions'),
                  subtitle: const Text('Salary, rent and other repeats'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RecurringScreen(),
                    ),
                  ),
                ),
            ],
          ),
          const _GroupLabel('Data'),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.backup_outlined),
                title: const Text('Back up data'),
                subtitle: const Text('Export everything to a JSON file'),
                onTap: data.exportBackup,
              ),
              ListTile(
                leading: const Icon(Icons.settings_backup_restore_rounded),
                title: const Text('Restore from backup'),
                subtitle: const Text('Replace current data with a backup file'),
                onTap: data.restoreBackup,
              ),
              ListTile(
                leading: const Icon(Icons.table_chart_outlined),
                title: const Text('Export transactions (CSV)'),
                subtitle: const Text('Open in Excel, Sheets or Numbers'),
                onTap: data.exportCsv,
              ),
            ],
          ),
          if (context.watch<ResetProvider>().isAvailable) ...[
            const SizedBox(height: Spacing.md),
            const _SettingsCard(
              children: [RestoreCloudDataTile(), ResetAppTile()],
            ),
          ],
          const _GroupLabel('About'),
          _SettingsCard(
            children: [
              ListTile(
                leading: const Icon(Icons.info_outline_rounded),
                title: const Text(AppConstants.appName),
                subtitle: const Text('Version ${AppConstants.appVersion}'),
                onTap: () => showAboutDialog(
                  context: context,
                  applicationName: AppConstants.appName,
                  applicationVersion: AppConstants.appVersion,
                  applicationIcon: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.account_balance_wallet_rounded,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                  children: const [
                    Text(
                      'A private, offline-first expense tracker. Everything '
                      'works without a connection; your transactions are '
                      'backed up to your own cloud account when online.',
                    ),
                  ],
                ),
              ),
              const ListTile(
                leading: Icon(Icons.lock_outline_rounded),
                title: Text('Privacy'),
                subtitle: Text(
                  'Personal transactions, budgets and categories sync only to '
                  'your own account. Shared household records are visible to '
                  'the household\'s members only. App settings stay on this '
                  'device.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Entry to household management, with the current household and role.
class _HouseholdTile extends StatelessWidget {
  const _HouseholdTile();

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final info = household.household;
    final String title;
    final String subtitle;
    if (!household.isAvailable) {
      title = 'Households';
      subtitle = 'Not available in this build';
    } else if (info == null) {
      title = 'Create or join a household';
      subtitle = 'Share expenses and budgets with your partner';
    } else {
      title = info.name.isEmpty ? 'Your household' : info.name;
      subtitle =
          '${household.role?.label ?? 'Member'} · '
          '${household.members.length} '
          '${household.members.length == 1 ? 'member' : 'members'}';
    }
    return _SettingsCard(
      children: [
        ListTile(
          key: const Key('householdTile'),
          leading: Icon(
            info == null ? Icons.add_home_outlined : Icons.home_rounded,
          ),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right_rounded),
          enabled: household.isAvailable,
          onTap: () => openHouseholdScreen(context),
        ),
      ],
    );
  }
}

/// Sync status, pending changes and the local retention period.
class _SyncCard extends StatelessWidget {
  const _SyncCard();

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncProvider>();
    final theme = Theme.of(context);
    if (sync.phase == SyncPhase.unavailable) {
      return const _SettingsCard(
        children: [
          ListTile(
            leading: Icon(Icons.cloud_off_outlined),
            title: Text('Cloud sync is not available'),
          ),
        ],
      );
    }

    final (IconData icon, String title) = switch (sync.phase) {
      SyncPhase.signedOut => (Icons.cloud_off_outlined, 'Signed out'),
      SyncPhase.accountMismatch => (Icons.sync_disabled_rounded, 'Sync paused'),
      _ => switch (sync.statusLabel) {
        SyncStatusLabel.syncing => (Icons.sync_rounded, 'Syncing…'),
        SyncStatusLabel.offline => (Icons.cloud_off_outlined, 'Offline'),
        SyncStatusLabel.failed => (Icons.sync_problem_rounded, 'Failed'),
        SyncStatusLabel.pending => (Icons.cloud_upload_outlined, 'Pending'),
        SyncStatusLabel.synced => (Icons.cloud_done_outlined, 'Synced'),
      },
    };
    final last = sync.lastSyncedAt;
    final details = <String>[
      if (sync.message != null) sync.message!,
      if (sync.pendingCount > 0) '${sync.pendingCount} change(s) to upload',
      if (sync.failedCount > 0) '${sync.failedCount} failed, will retry',
      last == null
          ? 'Not synced yet'
          : 'Last successful sync ${DateFormat('d MMM, HH:mm').format(last)}',
    ];
    final canSync =
        !sync.isSyncing &&
        sync.phase != SyncPhase.signedOut &&
        sync.phase != SyncPhase.accountMismatch;

    return _SettingsCard(
      children: [
        ListTile(
          key: const Key('syncStatusTile'),
          leading: sync.isSyncing
              ? const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : Icon(
                  icon,
                  color: sync.phase == SyncPhase.error
                      ? theme.colorScheme.error
                      : null,
                ),
          title: Text(title),
          subtitle: Text(details.join('\n')),
          trailing: TextButton(
            onPressed: canSync ? sync.syncNow : null,
            child: const Text('Sync now'),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.phone_android_rounded),
          title: const Text('Stored on this device'),
          subtitle: Text(
            'The latest ${sync.retentionDays > 0 ? sync.retentionDays : 90} '
            'days of transactions. Older ones are removed from the device '
            'only after they are verified in the cloud.',
          ),
        ),
      ],
    );
  }
}

/// Shown while MoneyMate may not show notifications: asks, or sends the
/// user to the system settings once Android stops asking.
class _NotificationPermissionTile extends StatelessWidget {
  const _NotificationPermissionTile();

  Future<void> _allow(BuildContext context) async {
    final notifications = context.read<NotificationProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final wasDenied = notifications.permission == NotificationPermission.denied;
    final result = await notifications.requestPermission();
    if (result.isGranted) return;
    if (wasDenied) {
      // The system no longer shows its prompt: only Settings can allow it.
      await openAppSettings();
      return;
    }
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Notifications stay off. You can allow them later in the '
          'system settings.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      key: const Key('notificationPermissionTile'),
      leading: Icon(Icons.notifications_off_outlined, color: scheme.error),
      title: const Text('Notifications are off'),
      subtitle: const Text(
        'Allow them to get budget alerts and household updates',
      ),
      trailing: FilledButton.tonal(
        onPressed: () => _allow(context),
        child: const Text('Allow'),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.xs,
        Spacing.xl,
        Spacing.xs,
        Spacing.sm,
      ),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 1.1,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const Divider(indent: 56),
            children[i],
          ],
        ],
      ),
    );
  }
}
