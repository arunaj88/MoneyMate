import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/services/file_service.dart';
import 'package:money_mate/core/services/transactions_workbook.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/category_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';

enum _ExportTarget { save, share }

/// UI flows for backup, restore and the transactions spreadsheet export.
/// File formats and database work live in [BackupService]; this class only
/// coordinates dialogs.
class DataManagement {
  DataManagement(this.context);

  final BuildContext context;

  Future<void> _export({
    required String title,
    required String fileName,
    required String extension,
    required String mimeType,
    required Future<List<int>> Function() build,
  }) async {
    final target = await showModalBottomSheet<_ExportTarget>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetTitle(title),
            ..._targetTiles((t) => Navigator.of(context).pop(t)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (target == null || !context.mounted) return;
    await _deliver(
      target: target,
      fileName: fileName,
      extension: extension,
      mimeType: mimeType,
      build: build,
    );
  }

  Future<void> _deliver({
    required _ExportTarget target,
    required String fileName,
    required String extension,
    required String mimeType,
    required Future<List<int>> Function() build,
  }) async {
    final files = context.read<FileService>();
    try {
      final bytes = Uint8List.fromList(await build());
      if (target == _ExportTarget.save) {
        final path = await files.saveToDevice(
          fileName: fileName,
          bytes: bytes,
          extension: extension,
        );
        if (path != null && context.mounted) {
          showAppSnackBar(context, 'Saved $fileName');
        }
      } else {
        await files.shareBytes(
          fileName: fileName,
          bytes: bytes,
          mimeType: mimeType,
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
      mimeType: 'application/json',
      build: () async => utf8.encode(
        await backup.createBackupJson(settings: settings.toJson()),
      ),
    );
  }

  /// Asks which transactions to export (personal, or the household's
  /// shared ones when the user has a household) and where to send them.
  Future<void> exportTransactions() async {
    final backup = context.read<BackupService>();
    final settings = context.read<SettingsProvider>();
    final scope = context.read<TransactionScopeProvider>();
    final householdId = scope.householdId;
    final householdName = scope.householdName?.trim();

    final choice = await showModalBottomSheet<(ViewScope, _ExportTarget)>(
      context: context,
      builder: (context) => _TransactionsExportSheet(
        initialView: scope.view,
        householdName: householdId == null
            ? null
            : (householdName == null || householdName.isEmpty)
            ? 'your household'
            : householdName,
      ),
    );
    if (choice == null || !context.mounted) return;
    final (view, target) = choice;
    await _deliver(
      target: target,
      fileName: TransactionsWorkbook.fileName(DateTime.now(), view: view),
      extension: 'xlsx',
      mimeType: TransactionsWorkbook.mimeType,
      build: () => backup.createTransactionsWorkbook(
        view: view,
        householdId: householdId,
        householdName: householdName,
        currencyCode: settings.currencyCode,
      ),
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

List<Widget> _targetTiles(ValueChanged<_ExportTarget> onSelected) => [
  ListTile(
    key: const Key('exportSaveTile'),
    leading: const Icon(Icons.save_alt_rounded),
    title: const Text('Save to device'),
    subtitle: const Text('Choose a folder on this device'),
    onTap: () => onSelected(_ExportTarget.save),
  ),
  ListTile(
    key: const Key('exportShareTile'),
    leading: const Icon(Icons.share_rounded),
    title: const Text('Share'),
    subtitle: const Text('Send to Files, Drive, email…'),
    onTap: () => onSelected(_ExportTarget.share),
  ),
];

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
    );
  }
}

/// Bottom sheet for the transactions export: which transactions go in the
/// file, then where it goes. Pops with the chosen view and target.
class _TransactionsExportSheet extends StatefulWidget {
  const _TransactionsExportSheet({
    required this.initialView,
    required this.householdName,
  });

  final ViewScope initialView;

  /// Null when the user has no household: only personal transactions can
  /// be exported then.
  final String? householdName;

  @override
  State<_TransactionsExportSheet> createState() =>
      _TransactionsExportSheetState();
}

class _TransactionsExportSheetState extends State<_TransactionsExportSheet> {
  late ViewScope _view = widget.householdName == null
      ? ViewScope.personal
      : widget.initialView;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final householdName = widget.householdName;
    final hint = switch (_view) {
      ViewScope.personal when householdName == null =>
        'Your personal transactions.',
      ViewScope.personal =>
        'Only your personal transactions. Shared household ones are not '
            'included.',
      ViewScope.shared =>
        'Only the shared transactions of $householdName, with who added '
            'each one. Your personal ones are not included.',
    };
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SheetTitle('Export transactions (Excel)'),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, Spacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (householdName != null) ...[
                  SegmentedButton<ViewScope>(
                    key: const Key('exportScopeSelector'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(
                        value: ViewScope.personal,
                        label: Text('Personal'),
                        icon: Icon(Icons.person_outline_rounded),
                      ),
                      ButtonSegment(
                        value: ViewScope.shared,
                        label: Text('Household'),
                        icon: Icon(Icons.group_outlined),
                      ),
                    ],
                    selected: {_view},
                    onSelectionChanged: (s) => setState(() => _view = s.first),
                  ),
                  const SizedBox(height: Spacing.sm),
                ],
                Text(
                  hint,
                  key: const Key('exportScopeHint'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          ..._targetTiles(
            (target) => Navigator.of(context).pop((_view, target)),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
