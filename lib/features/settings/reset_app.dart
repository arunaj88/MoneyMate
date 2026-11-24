import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/transaction_sync_service.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/reset_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';

/// Settings entry for Reset App (this device only). Hidden in builds
/// without cloud services.
class ResetAppTile extends StatelessWidget {
  const ResetAppTile({super.key});

  @override
  Widget build(BuildContext context) {
    final reset = context.watch<ResetProvider>();
    if (!reset.isAvailable) return const SizedBox.shrink();
    final error = Theme.of(context).colorScheme.error;
    return ListTile(
      key: const Key('resetAppTile'),
      leading: Icon(Icons.restart_alt_rounded, color: error),
      title: Text('Reset App', style: TextStyle(color: error)),
      subtitle: const Text(
        'Clear local app data and start fresh. Your cloud data will remain '
        'safe.',
      ),
      enabled: !reset.isRunning,
      onTap: () => ResetAppFlow(context).start(),
    );
  }
}

/// Settings entry for Restore My Cloud Data.
class RestoreCloudDataTile extends StatelessWidget {
  const RestoreCloudDataTile({super.key});

  @override
  Widget build(BuildContext context) {
    final reset = context.watch<ResetProvider>();
    if (!reset.isAvailable) return const SizedBox.shrink();
    return ListTile(
      key: const Key('restoreCloudDataTile'),
      leading: const Icon(Icons.cloud_download_outlined),
      title: const Text('Restore My Cloud Data'),
      subtitle: const Text(
        'Download your previously saved transactions and budgets from '
        'Firebase.',
      ),
      trailing: reset.restorePending
          ? Icon(
              Icons.circle,
              size: 10,
              color: Theme.of(context).colorScheme.primary,
              semanticLabel: 'Restore available',
            )
          : null,
      enabled: !reset.isRunning,
      onTap: () => RestoreCloudDataFlow(context).start(),
    );
  }
}

/// Shown on the dashboard after Reset App until the user restores.
class RestorePendingBanner extends StatelessWidget {
  const RestorePendingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final reset = context.watch<ResetProvider>();
    if (!reset.isAvailable || !reset.restorePending) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return AppCard(
      key: const Key('restorePendingBanner'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_done_outlined, color: scheme.primary),
          const SizedBox(width: Spacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('A fresh start', style: theme.textTheme.titleSmall),
                const SizedBox(height: Spacing.xs),
                Text(
                  'This device was reset. Your earlier transactions and '
                  'budgets are safe in the cloud. Restore them any time '
                  'from Settings.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Spacing.sm),
                TextButton.icon(
                  key: const Key('restoreBannerButton'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: reset.isRunning
                      ? null
                      : () => RestoreCloudDataFlow(context).start(),
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('Restore My Cloud Data'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

ResetTargets _targets(BuildContext context) => ResetTargets(
  auth: context.read<AuthProvider>(),
  household: context.read<HouseholdProvider>(),
  sync: context.read<SyncProvider>(),
  scope: context.read<TransactionScopeProvider>(),
  categories: context.read<CategoryProvider>(),
  transactions: context.read<TransactionProvider>(),
  budgets: context.read<BudgetProvider>(),
);

/// Confirmation, progress and result of Reset App.
class ResetAppFlow {
  ResetAppFlow(this.context);

  final BuildContext context;

  static const _app = AppConstants.appName;

  Future<void> start() async {
    if (context.read<ResetProvider>().isRunning) return;
    final sync = context.read<SyncProvider>();
    final unsynced = sync.pendingCount + sync.failedCount;
    final sure = await showDialog<bool>(
      context: context,
      builder: (_) => _ResetConfirmDialog(unsynced: unsynced),
    );
    if (sure != true || !context.mounted) return;
    await _run();
  }

  Future<void> _run() async {
    final reset = context.read<ResetProvider>();
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    final targets = _targets(context);

    while (true) {
      // Blocks the app (and the back button) until the reset finishes, so
      // nothing new is recorded half-way.
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => const _ProgressDialog(
          key: Key('resetProgressDialog'),
          title: 'Resetting local data...',
        ),
      );
      final ok = await reset.reset(targets);
      navigator.pop();
      if (ok) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                '$_app was reset on this device. Your cloud data is safe.',
              ),
            ),
          );
        return;
      }
      if (!context.mounted) return;
      final retry = await _showRetry(
        context,
        title: 'Reset did not finish',
        message: reset.error,
        retryKey: const Key('retryResetButton'),
      );
      if (retry != true || !context.mounted) return;
    }
  }
}

/// Confirmation, progress and result of Restore My Cloud Data.
class RestoreCloudDataFlow {
  RestoreCloudDataFlow(this.context);

  final BuildContext context;

  Future<void> start() async {
    final reset = context.read<ResetProvider>();
    if (reset.isRunning) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!context.read<AuthProvider>().isAuthenticated) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Sign in to restore your cloud data.')),
      );
      return;
    }
    final household = context.read<HouseholdProvider>();
    final retention = context.read<SyncProvider>().retentionDays;
    final days = retention > 0
        ? retention
        : AppConstants.defaultLocalRetentionDays;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.cloud_download_outlined),
        title: const Text('Restore your cloud data?'),
        content: Text(
          'Your transactions, budgets and categories saved in Firebase will '
          'be downloaded to this device. '
          '${household.hasHousehold ? 'Shared household data is included '
                    'while you are still a member. ' : ''}'
          'Records already on this device are kept and nothing is '
          'duplicated. Transactions older than $days days stay in the cloud '
          'and appear when you browse your history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirmRestoreButton'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (sure != true || !context.mounted) return;
    await _run();
  }

  Future<void> _run() async {
    final reset = context.read<ResetProvider>();
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    final targets = _targets(context);

    while (true) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) => const _ProgressDialog(
          key: Key('restoreProgressDialog'),
          title: 'Restoring your cloud data...',
          showDownloads: true,
        ),
      );
      final ok = await reset.restore(targets);
      navigator.pop();
      if (ok) {
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Your cloud data has been restored.')),
          );
        return;
      }
      if (!context.mounted) return;
      final retry = await _showRetry(
        context,
        title: 'Restore did not finish',
        message: reset.error,
        retryKey: const Key('retryRestoreButton'),
      );
      if (retry != true || !context.mounted) return;
    }
  }
}

Future<bool?> _showRetry(
  BuildContext context, {
  required String title,
  required String? message,
  required Key retryKey,
}) => showDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    scrollable: true,
    icon: Icon(
      Icons.error_outline_rounded,
      color: Theme.of(context).colorScheme.error,
    ),
    title: Text(title),
    content: Text(message ?? 'Something went wrong.'),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Close'),
      ),
      FilledButton(
        key: retryKey,
        onPressed: () => Navigator.of(context).pop(true),
        child: const Text('Retry'),
      ),
    ],
  ),
);

class _ResetConfirmDialog extends StatelessWidget {
  const _ResetConfirmDialog({required this.unsynced});

  /// Local changes not yet backed up; they are lost by a reset.
  final int unsynced;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      scrollable: true,
      icon: Icon(Icons.restart_alt_rounded, color: scheme.error),
      title: const Text('Reset ${AppConstants.appName} on this device?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Your locally stored transactions, budgets and cached data will '
            'be cleared. Your Firebase cloud data will not be deleted. You '
            'can restore your data later.',
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Only this device is reset. You stay signed in, and your '
            'household membership is not changed.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (unsynced > 0) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              key: const Key('resetUnsyncedWarning'),
              '$unsynced change${unsynced == 1 ? ' has' : 's have'} not '
              'been backed up to the cloud yet and will be lost.',
              style: TextStyle(color: scheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirmResetButton'),
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Reset App'),
        ),
      ],
    );
  }
}

class _ProgressDialog extends StatelessWidget {
  const _ProgressDialog({
    super.key,
    required this.title,
    this.showDownloads = false,
  });

  final String title;
  final bool showDownloads;

  @override
  Widget build(BuildContext context) {
    final reset = context.watch<ResetProvider>();
    final progress = reset.restoreProgress;
    final theme = Theme.of(context);
    final detail = showDownloads && progress != null
        ? '${progress.step == RestoreStep.household ? 'Household data' : 'Your data'}'
              ' · ${progress.downloaded} item${progress.downloaded == 1 ? '' : 's'} '
              'downloaded'
        : reset.stage.message;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: Spacing.sm),
            const CircularProgressIndicator(),
            const SizedBox(height: Spacing.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
