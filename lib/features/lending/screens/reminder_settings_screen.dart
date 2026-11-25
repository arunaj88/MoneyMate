import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/providers/loan_provider.dart';
import 'package:money_mate/providers/notification_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/state_views.dart';

/// When reminders for one loan are shown and, for a household loan, which
/// members get them. Only the household owner can change a household
/// loan's settings; everyone else sees them read-only.
class ReminderSettingsScreen extends StatefulWidget {
  const ReminderSettingsScreen({super.key, required this.loanId});

  final String loanId;

  @override
  State<ReminderSettingsScreen> createState() => _ReminderSettingsScreenState();
}

class _ReminderSettingsScreenState extends State<ReminderSettingsScreen> {
  late bool _enabled;
  late bool _paused;
  late Set<int> _offsets;
  late Set<String> _recipients;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<LoanProvider>().reminderSettingsOf(widget.loanId);
    _enabled = s.enabled;
    _paused = s.paused;
    _offsets = {...s.offsets};
    _recipients = {...s.notifyUids};
  }

  static String offsetLabel(int days) => switch (days) {
    0 => 'On the due date',
    -1 => '1 day before',
    1 => '1 day after',
    < 0 => '${-days} days before',
    _ => '$days days after',
  };

  Future<void> _save(Loan loan) async {
    setState(() => _saving = true);
    try {
      await context.read<LoanProvider>().saveReminderSettings(
        loan,
        enabled: _enabled,
        paused: _paused,
        offsets: _offsets.toList(),
        notifyUids: loan.isHousehold ? _recipients.toList() : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
      showAppSnackBar(context, 'Reminder settings saved');
    } on LoanException catch (e) {
      if (mounted) showAppSnackBar(context, e.message, isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loans = context.watch<LoanProvider>();
    final snapshot = loans.snapshotById(widget.loanId);
    if (snapshot == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reminders')),
        body: const EmptyState(
          icon: Icons.search_off_rounded,
          title: 'This lending record no longer exists',
        ),
      );
    }
    final loan = snapshot.loan;
    final editable = loans.canEditReminders(loan);
    final members = loans.householdMembers;
    final permission = context.select<NotificationProvider, bool>(
      (n) => !n.pushSupported || n.permission.isGranted,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            Spacing.xxl,
          ),
          children: [
            if (!editable)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: Text(
                  key: const Key('remindersReadOnlyNote'),
                  'The household owner decides when reminders for household '
                  'lending are sent and who gets them.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (!permission)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.md),
                child: Text(
                  'Notifications are turned off for MoneyMate on this '
                  'device, so reminders cannot appear here. You can allow '
                  'them in Settings → Notifications.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile(
                    key: const Key('remindersEnabledSwitch'),
                    secondary: const Icon(Icons.notifications_outlined),
                    title: const Text('Repayment reminders'),
                    subtitle: Text(
                      'For ${loan.borrowerName}, until everything is repaid',
                    ),
                    value: _enabled,
                    onChanged: editable
                        ? (v) => setState(() => _enabled = v)
                        : null,
                  ),
                  SwitchListTile(
                    key: const Key('remindersPausedSwitch'),
                    secondary: const Icon(Icons.notifications_paused_outlined),
                    title: const Text('Pause reminders'),
                    subtitle: const Text(
                      'Keeps your choices; no reminders until resumed',
                    ),
                    value: _paused,
                    onChanged: editable && _enabled
                        ? (v) => setState(() => _paused = v)
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Spacing.lg),
            Text('Remind me', style: theme.textTheme.titleSmall),
            const SizedBox(height: Spacing.sm),
            Wrap(
              spacing: Spacing.sm,
              runSpacing: Spacing.sm,
              children: [
                for (final o in LoanLimits.reminderOffsetChoices)
                  FilterChip(
                    key: Key('offset$o'),
                    label: Text(offsetLabel(o)),
                    selected: _offsets.contains(o),
                    onSelected: editable && _enabled
                        ? (on) => setState(
                            () => on ? _offsets.add(o) : _offsets.remove(o),
                          )
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              'At 9:00 on each of these days, for every unpaid instalment. '
              'Partly paid instalments show what is left.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (loan.isHousehold) ...[
              const SizedBox(height: Spacing.xl),
              SectionHeader(
                title: 'Who gets reminders',
                subtitle: editable
                    ? 'Chosen by you as the household owner. New members '
                          'are not added automatically.'
                    : 'Chosen by the household owner',
                trailing: editable && members.isNotEmpty
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            key: const Key('recipientsAll'),
                            onPressed: () => setState(
                              () => _recipients = {
                                for (final m in members) m.uid,
                              },
                            ),
                            child: const Text('All'),
                          ),
                          TextButton(
                            key: const Key('recipientsNone'),
                            onPressed: () => setState(() => _recipients = {}),
                            child: const Text('None'),
                          ),
                        ],
                      )
                    : null,
              ),
              const SizedBox(height: Spacing.sm),
              if (members.isEmpty)
                const EmptyState(
                  compact: true,
                  icon: Icons.groups_outlined,
                  title: 'Household members are loading',
                  message: 'Connect to the internet to see the members.',
                )
              else
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final m in members)
                        CheckboxListTile(
                          key: Key('recipient-${m.uid}'),
                          secondary: Icon(
                            m.isOwner
                                ? Icons.admin_panel_settings_outlined
                                : Icons.person_outline_rounded,
                          ),
                          title: Text(
                            m.uid == loans.uid ? '${m.name} (you)' : m.name,
                          ),
                          subtitle: Text(m.isOwner ? 'Owner' : 'Member'),
                          value: _recipients.contains(m.uid),
                          onChanged: editable
                              ? (v) => setState(
                                  () => v == true
                                      ? _recipients.add(m.uid)
                                      : _recipients.remove(m.uid),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: Spacing.xs),
              Text(
                "Reminders appear on each selected member's own phone, from "
                'the data it has synced; their notification settings apply.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (editable) ...[
              const SizedBox(height: Spacing.xl),
              FilledButton.icon(
                key: const Key('saveRemindersButton'),
                onPressed: _saving ? null : () => _save(loan),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
