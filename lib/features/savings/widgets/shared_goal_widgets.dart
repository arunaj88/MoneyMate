import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/providers/savings_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/shared/widgets/app_card.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';
import 'package:money_mate/shared/widgets/user_avatar.dart';

/// Runs [action] and shows its outcome as a snack bar.
Future<bool> runSavingsAction(
  BuildContext context,
  Future<void> Function() action, {
  String? done,
}) async {
  try {
    await action();
    if (done != null && context.mounted) showAppSnackBar(context, done);
    return true;
  } on SavingsException catch (e) {
    if (context.mounted) showAppSnackBar(context, e.message, isError: true);
  } catch (e) {
    if (context.mounted) {
      showAppSnackBar(context, 'Something went wrong: $e', isError: true);
    }
  }
  return false;
}

/// Asks for a shared-goal invitation code, shows what it is for and joins.
class JoinWithCodeDialog extends StatefulWidget {
  const JoinWithCodeDialog({super.key});

  @override
  State<JoinWithCodeDialog> createState() => _JoinWithCodeDialogState();
}

class _JoinWithCodeDialogState extends State<JoinWithCodeDialog> {
  final _controller = TextEditingController();
  SharedGoalInvitation? _preview;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on SavingsException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() => _run(() async {
    final preview = await context.read<SavingsProvider>().previewCode(
      _controller.text,
    );
    if (mounted) setState(() => _preview = preview);
  });

  Future<void> _join() => _run(() async {
    final savings = context.read<SavingsProvider>();
    await savings.acceptInvitation(_preview!);
    if (!mounted) return;
    Navigator.of(context).pop();
    showAppSnackBar(context, 'You joined "${_preview!.goalName}"');
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;
    return AlertDialog(
      scrollable: true,
      title: const Text('Join a shared goal'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preview == null) ...[
            const Text('Enter the invitation code you received.'),
            const SizedBox(height: Spacing.md),
            TextField(
              key: const Key('joinCodeField'),
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Invitation code',
                hintText: 'XXXX-XXXX-XXXX-XXXX',
              ),
              onSubmitted: (_) => _check(),
            ),
          ] else ...[
            Text(preview.goalName, style: theme.textTheme.titleMedium),
            const SizedBox(height: Spacing.xs),
            Text(
              'Invited by ${preview.invitedByName ?? 'the goal owner'}. '
              'Members see the goal, its history and everyone\'s '
              'contributions.',
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: Spacing.sm),
            Text(
              _error!,
              key: const Key('joinCodeError'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('joinCodeButton'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: _busy ? null : (preview == null ? _check : _join),
          child: Text(preview == null ? 'Continue' : 'Join goal'),
        ),
      ],
    );
  }
}

/// Shows a new invitation's code with Copy and Share.
Future<void> showInvitationCode(
  BuildContext context,
  SharedGoalInvitation invitation,
) => showDialog<void>(
  context: context,
  builder: (context) {
    final theme = Theme.of(context);
    final code = invitation.formattedCode;
    final message =
        'Join my savings goal "${invitation.goalName}" on MoneyMate. Sign in, '
        'open Savings → Shared → Join with code and enter: $code '
        '(valid until '
        '${DateFormat('d MMM yyyy').format(invitation.expiresAt)}).';
    return AlertDialog(
      scrollable: true,
      title: const Text('Invitation ready'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            invitation.invitedEmail == null
                ? 'Anyone with this code can join once, using their own '
                      'MoneyMate account.'
                : 'Only ${invitation.invitedEmail} can accept it. They will '
                      'also see it in their Savings screen.',
          ),
          const SizedBox(height: Spacing.lg),
          Center(
            child: SelectableText(
              code,
              key: const Key('invitationCodeText'),
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Center(
            child: Text(
              'Valid for ${SavingsLimits.invitationDays} days · one use',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code));
            if (context.mounted) showAppSnackBar(context, 'Code copied');
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy'),
        ),
        TextButton.icon(
          onPressed: () => SharePlus.instance.share(
            ShareParams(text: message, subject: 'MoneyMate savings goal'),
          ),
          icon: const Icon(Icons.share_rounded),
          label: const Text('Share'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  },
);

/// Invitations addressed to the user, with Accept / Decline.
class ReceivedInvitationsCard extends StatelessWidget {
  const ReceivedInvitationsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final invitations = savings.receivedInvitations;
    if (invitations.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return AppCard(
      key: const Key('receivedInvitationsCard'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Invitations for you'),
          for (final i in invitations)
            Padding(
              padding: const EdgeInsets.only(top: Spacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(i.goalName, style: theme.textTheme.titleSmall),
                  Text(
                    'From ${i.invitedByName ?? 'a MoneyMate user'} · until '
                    '${DateFormat('d MMM').format(i.expiresAt)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: Spacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: Key('rejectInvitation-${i.code}'),
                        onPressed: () => runSavingsAction(
                          context,
                          () => savings.rejectInvitation(i),
                          done: 'Invitation declined',
                        ),
                        child: const Text('Decline'),
                      ),
                      const SizedBox(width: Spacing.sm),
                      FilledButton(
                        key: Key('acceptInvitation-${i.code}'),
                        onPressed: () => runSavingsAction(
                          context,
                          () => savings.acceptInvitation(i),
                          done: 'You joined "${i.goalName}"',
                        ),
                        child: const Text('Accept'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Who put how much into a household or shared goal.
class MemberContributionsCard extends StatelessWidget {
  const MemberContributionsCard({super.key, required this.goal});

  final SavingsGoal goal;

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final formatter = context.select<SettingsProvider, CurrencyFormatter>(
      (s) => s.formatter,
    );
    final theme = Theme.of(context);
    final rows = savings.contributionsOf(goal.id);
    if (rows.isEmpty) return const SizedBox.shrink();
    final total = rows.fold<int>(0, (s, r) => s + r.depositedMinor);
    return AppCard(
      key: const Key('memberContributionsCard'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Contributions by member',
            subtitle: goal.isShared
                ? 'Recorded by each member · not deducted from anyone\'s '
                      'balance'
                : 'Total contributed ${formatter.format(total)}',
          ),
          const SizedBox(height: Spacing.sm),
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: r.name == 'You'
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatter.format(r.netMinor),
                        key: Key('contribution-${r.uid}'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (r.withdrawnMinor > 0)
                        Text(
                          '${formatter.format(r.depositedMinor)} in · '
                          '${formatter.format(r.withdrawnMinor)} out',
                          style: theme.textTheme.labelSmall,
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Members, invitations and (for the owner) their management.
class SharedMembersCard extends StatelessWidget {
  const SharedMembersCard({super.key, required this.goal});

  final SavingsGoal goal;

  Future<void> _inviteByEmail(BuildContext context) async {
    final savings = context.read<SavingsProvider>();
    final email = await showDialog<String>(
      context: context,
      builder: (_) => const _EmailDialog(),
    );
    if (email == null || !context.mounted) return;
    SharedGoalInvitation? invitation;
    final ok = await runSavingsAction(context, () async {
      invitation = await savings.inviteByEmail(goal, email);
    });
    if (ok && invitation != null && context.mounted) {
      await showInvitationCode(context, invitation!);
    }
  }

  Future<void> _createCode(BuildContext context) async {
    final savings = context.read<SavingsProvider>();
    SharedGoalInvitation? invitation;
    final ok = await runSavingsAction(context, () async {
      invitation = await savings.createInviteCode(goal);
    });
    if (ok && invitation != null && context.mounted) {
      await showInvitationCode(context, invitation!);
    }
  }

  Future<void> _remove(BuildContext context, SharedGoalMember member) async {
    final savings = context.read<SavingsProvider>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove ${member.name}?',
      message:
          'They lose access to this goal straight away. Their past '
          'contributions stay in the history.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    await runSavingsAction(
      context,
      () => savings.removeMember(goal, member),
      done: '${member.name} was removed',
    );
  }

  @override
  Widget build(BuildContext context) {
    final savings = context.watch<SavingsProvider>();
    final theme = Theme.of(context);
    final owner = savings.isOwner(goal);
    final members = savings.membersOf(goal.id).where((m) => m.isActive);
    final now = DateTime.now();
    final pending = owner
        ? savings
              .sentInvitationsOf(goal.id)
              .where((i) => i.isOpenAt(now))
              .toList()
        : const <SharedGoalInvitation>[];

    return AppCard(
      key: const Key('sharedMembersCard'),
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.lg,
        Spacing.sm,
        Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: SectionHeader(
              title: 'Members',
              subtitle: owner
                  ? 'You own this goal'
                  : 'Shared with you by ${goal.createdByName ?? 'the owner'}',
            ),
          ),
          for (final m in members)
            ListTile(
              key: Key('sharedMember-${m.uid}'),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Spacing.sm,
              ),
              leading: UserAvatar(
                user: AppUser(
                  uid: m.uid,
                  email: m.email,
                  displayName: m.displayName,
                ),
                radius: 18,
              ),
              title: Text(
                m.uid == savings.uid ? '${m.name} (you)' : m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                m.isOwner
                    ? 'Owner · can withdraw'
                    : m.canWithdraw
                    ? 'Member · can withdraw'
                    : 'Member · contributes',
              ),
              trailing: owner && !m.isOwner
                  ? PopupMenuButton<String>(
                      key: Key('memberMenu-${m.uid}'),
                      onSelected: (action) {
                        if (action == 'remove') {
                          _remove(context, m);
                        } else {
                          runSavingsAction(
                            context,
                            () =>
                                savings.setCanWithdraw(goal, m, !m.canWithdraw),
                            done: 'Permissions updated',
                          );
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'withdraw',
                          child: Text(
                            m.canWithdraw
                                ? 'Stop allowing withdrawals'
                                : 'Allow withdrawals',
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove from goal'),
                        ),
                      ],
                    )
                  : null,
            ),
          if (pending.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Spacing.sm,
                Spacing.md,
                Spacing.sm,
                0,
              ),
              child: Text(
                'Pending invitations',
                style: theme.textTheme.labelLarge,
              ),
            ),
            for (final i in pending)
              ListTile(
                key: Key('pendingInvitation-${i.code}'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Spacing.sm,
                ),
                leading: const Icon(Icons.mail_outline_rounded),
                title: Text(i.invitedEmail ?? 'Code ${i.formattedCode}'),
                subtitle: Text(
                  'Until ${DateFormat('d MMM').format(i.expiresAt)}',
                ),
                trailing: TextButton(
                  onPressed: () => runSavingsAction(
                    context,
                    () => savings.revokeInvitation(goal, i),
                    done: 'Invitation revoked',
                  ),
                  child: const Text('Revoke'),
                ),
              ),
          ],
          if (owner)
            Padding(
              padding: const EdgeInsets.all(Spacing.sm),
              child: Wrap(
                spacing: Spacing.sm,
                runSpacing: Spacing.sm,
                children: [
                  FilledButton.tonalIcon(
                    key: const Key('inviteByEmailButton'),
                    onPressed: () => _inviteByEmail(context),
                    icon: const Icon(Icons.person_add_alt_rounded),
                    label: const Text('Invite by email'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('inviteCodeButton'),
                    onPressed: () => _createCode(context),
                    icon: const Icon(Icons.key_rounded),
                    label: const Text('Invitation code'),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Spacing.sm),
              child: TextButton.icon(
                key: const Key('leaveGoalButton'),
                onPressed: () async {
                  final confirmed = await showConfirmDialog(
                    context,
                    title: 'Leave "${goal.name}"?',
                    message:
                        'You will no longer see this goal. Your contributions '
                        'stay in its history.',
                    confirmLabel: 'Leave',
                    destructive: true,
                  );
                  if (!confirmed || !context.mounted) return;
                  final navigator = Navigator.of(context);
                  final ok = await runSavingsAction(
                    context,
                    () => savings.leaveGoal(goal),
                    done: 'You left the goal',
                  );
                  if (ok) navigator.pop();
                },
                icon: const Icon(Icons.logout_rounded),
                label: const Text('Leave goal'),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmailDialog extends StatefulWidget {
  const _EmailDialog();

  @override
  State<_EmailDialog> createState() => _EmailDialogState();
}

class _EmailDialogState extends State<_EmailDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Invite by email'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'They must sign in to MoneyMate with this email address to '
              'accept.',
            ),
            const SizedBox(height: Spacing.md),
            TextFormField(
              key: const Key('inviteEmailField'),
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email address'),
              validator: (v) =>
                  RegExp(
                    r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                  ).hasMatch(v?.trim() ?? '')
                  ? null
                  : 'Enter a valid email address',
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('sendInviteButton'),
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: _submit,
          child: const Text('Invite'),
        ),
      ],
    );
  }
}
