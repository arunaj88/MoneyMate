import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/services/file_service.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';

enum _ExportTarget { save, share }

/// UI flows for backup, restore and CSV export. File formats and database
/// work live in [BackupService]; this class only coordinates dialogs.
class DataManagement {
  DataManagement(this.context);

  final BuildContext context;

  Future<_ExportTarget?> _chooseTarget(String title) {
    return showModalBottomSheet<_ExportTarget>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt_rounded),
              title: const Text('Save to device'),
              subtitle: const Text('Choose a folder on this device'),
              onTap: () => Navigator.of(context).pop(_ExportTarget.save),
            ),
            ListTile(
              leading: const Icon(Icons.share_rounded),
              title: const Text('Share'),
              subtitle: const Text('Send to Files, Drive, email…'),
              onTap: () => Navigator.of(context).pop(_ExportTarget.share),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _export({
    required String title,
    required String fileName,
    required String extension,
    required Future<String> Function() build,
  }) async {
    final files = context.read<FileService>();
    final target = await _chooseTarget(title);
    if (target == null || !context.mounted) return;
    try {
      final content = await build();
      if (target == _ExportTarget.save) {
        final path = await files.saveToDevice(
          fileName: fileName,
          content: content,
          extension: extension,
        );
        if (path != null && context.mounted) {
          showAppSnackBar(context, 'Saved $fileName');
        }
      } else {
        await files.share(
          fileName: fileName,
          content: content,
          subject: fileName,
        );
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(context, 'Export failed: $e', isError: true);
      }
    }
  }

  Future<void> exportBackup() {
    final backup = context.read<BackupService>();
    final settings = context.read<SettingsProvider>();
    return _export(
      title: 'Export backup',
      fileName: BackupService.backupFileName(DateTime.now()),
      extension: 'json',
      build: () => backup.createBackupJson(settings: settings.toJson()),
    );
  }

  Future<void> exportCsv() {
    final backup = context.read<BackupService>();
    final settings = context.read<SettingsProvider>();
    return _export(
      title: 'Export transactions (CSV)',
      fileName: BackupService.csvFileName(DateTime.now()),
      extension: 'csv',
      build: () =>
          backup.createTransactionsCsv(currencyCode: settings.currencyCode),
    );
  }

  Future<void> restoreBackup() async {
    final files = context.read<FileService>();
    final backup = context.read<BackupService>();
    final settings = context.read<SettingsProvider>();
    final categories = context.read<CategoryProvider>();
    final transactions = context.read<TransactionProvider>();

    final String? text;
    try {
      text = await files.pickJsonFile();
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(context, 'Could not read the file', isError: true);
      }
      return;
    }
    if (text == null || !context.mounted) return;

    final BackupContents contents;
    try {
      contents = BackupService.parse(text);
    } on BackupFormatException catch (e) {
      await _showError('Invalid backup', e.message);
      return;
    }
    if (!context.mounted) return;

    final exported = contents.exportedAt == null
        ? 'an unknown date'
        : DateFormat('d MMM yyyy, HH:mm').format(contents.exportedAt!);
    final confirmed = await showConfirmDialog(
      context,
      title: 'Restore backup?',
      message:
          'Backup from $exported contains '
          '${contents.transactions.length} transactions, '
          '${contents.categories.length} categories and '
          '${contents.categoryBudgets.length} category budgets.\n\n'
          'All current data will be REPLACED. A safety copy of your current '
          'data is saved automatically before restoring.',
      confirmLabel: 'Replace & restore',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;

    try {
      // Safety copy so a mistaken restore can be undone.
      final current = await backup.createBackupJson(
        settings: settings.toJson(),
      );
      await files.writeInternal(
        folder: 'safety_backups',
        fileName:
            'before_restore_${BackupService.backupFileName(DateTime.now())}',
        content: current,
      );
      await backup.restore(contents);
      await settings.applyJson(contents.settings);
      await categories.load();
      await transactions.reloadAfterExternalChange();
      if (context.mounted) {
        showAppSnackBar(
          context,
          'Restored ${contents.transactions.length} transactions',
        );
      }
    } catch (e) {
      await _showError(
        'Restore failed',
        'Your existing data was not changed.\n\nDetails: $e',
      );
    }
  }

  Future<void> _showError(String title, String message) async {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
