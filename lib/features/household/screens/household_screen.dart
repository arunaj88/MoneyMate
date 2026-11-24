import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/app_user.dart';
import '../../../models/household_models.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/household_provider.dart';
import '../../../providers/sync_provider.dart';
import '../../../shared/widgets/app_card.dart';
import '../../../shared/widgets/dialogs.dart';
import '../../../shared/widgets/state_views.dart';
import '../../../shared/widgets/user_avatar.dart';

/// Household management: create or join a household, members, invitations
/// and household settings.
class HouseholdScreen extends StatelessWidget {
  const HouseholdScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final Widget body;
    if (!household.isAvailable) {
      body = const Center(
        child: EmptyState(
          icon: Icons.cloud_off_rounded,
          title: 'Households are not available',
          message: 'Shared households need cloud sync, which is turned off.',
        ),
      );
    } else if (household.phase == HouseholdPhase.signedOut) {
      body = const Center(
        child: EmptyState(
          icon: Icons.lock_outline_rounded,
          title: 'Sign in to use households',
        ),
      );
    } else if (household.phase == HouseholdPhase.loading) {
      body = const LoadingView();
    } else if (!household.hasHousehold) {
      body = const _NoHousehold();
    } else {
      body = const _HouseholdDetails();
    }
    final pending = household.pendingAction;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Household'),
        bottom: pending == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  key: const Key('householdProgress'),
                  minHeight: 3,
                  semanticsLabel: pending.progressLabel,
                ),
              ),
      ),
      body: SafeArea(top: false, child: body),
    );
  }
}

/// Shows the result of a household request. Takes the messenger captured
/// before the request started, so the message still appears when the user
/// left the screen while it was running.
void _showResult(
  ScaffoldMessengerState messenger,
  String message, {
  bool isError = false,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(messenger.context).colorScheme.error
            : null,
      ),
    );
}

void _showError(ScaffoldMessengerState messenger, HouseholdProvider household) {
  final error = household.error;
  if (error != null) _showResult(messenger, error, isError: true);
}

// --------------------------------------------------------------- no household

class _NoHousehold extends StatefulWidget {
  const _NoHousehold();

  @override
  State<_NoHousehold> createState() => _NoHouseholdState();
}

class _NoHouseholdState extends State<_NoHousehold> {
  final _name = TextEditingController();
  final _code = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final household = context.read<HouseholdProvider>();
    // Repeated taps (or Enter in the field) while a request runs are ignored.
    if (household.isBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    FocusScope.of(context).unfocus();
    final ok = await household.createHousehold(_name.text);
    if (ok) {
      // The screen switches to the new household's details by itself.
      _showResult(messenger, 'Household created. Invite your partner next.');
    } else {
      _showError(messenger, household);
    }
  }

  Future<void> _join() async {
    final household = context.read<HouseholdProvider>();
    if (household.isBusy) return;
    final messenger = ScaffoldMessenger.of(context);
    FocusScope.of(context).unfocus();
    final preview = await household.previewInvitation(_code.text);
    if (!mounted) return;
    if (preview == null) {
      _showError(messenger, household);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _InvitationAcceptDialog(preview: preview),
    );
    if (confirmed != true || !mounted) return;
    final ok = await household.acceptInvitation(_code.text);
    if (ok) {
      _showResult(messenger, 'You joined ${preview.householdName}.');
    } else {
      _showError(messenger, household);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final household = context.watch<HouseholdProvider>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.sm,
        Spacing.lg,
        Spacing.xxl,
      ),
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.family_restroom_rounded,
                size: 40,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: Spacing.md),
              Text(
                'Share household expenses',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: Spacing.sm),
              Text(
                'Create a household and invite your partner. Shared '
                'transactions and budgets sync between your devices. Your '
                'personal transactions and budgets stay private and are '
                'never shared.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                title: 'Create a household',
                subtitle: 'You become its owner',
              ),
              const SizedBox(height: Spacing.md),
              TextField(
                key: const Key('householdNameField'),
                controller: _name,
                maxLength: 40,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Household name',
                  hintText: 'e.g. The Khan family',
                  prefixIcon: Icon(Icons.home_outlined),
                ),
                onSubmitted: (_) => _create(),
              ),
              const SizedBox(height: Spacing.sm),
              FilledButton.icon(
                key: const Key('createHouseholdButton'),
                onPressed: household.isBusy ? null : _create,
                icon: household.isRunning(HouseholdAction.create)
                    ? const _ButtonSpinner()
                    : const Icon(Icons.add_home_rounded),
                label: Text(
                  household.isRunning(HouseholdAction.create)
                      ? 'Creating household…'
                      : 'Create household',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionHeader(
                title: 'Join a household',
                subtitle: 'Enter the invitation code you received',
              ),
              const SizedBox(height: Spacing.md),
              TextField(
                key: const Key('invitationCodeField'),
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9 -]')),
                  LengthLimitingTextInputFormatter(14),
                ],
                decoration: const InputDecoration(
                  labelText: 'Invitation code',
                  hintText: 'XXXXX-XXXXX',
                  prefixIcon: Icon(Icons.vpn_key_outlined),
                ),
                onSubmitted: (_) => _join(),
              ),
              const SizedBox(height: Spacing.sm),
              OutlinedButton.icon(
                key: const Key('joinHouseholdButton'),
                onPressed: household.isBusy ? null : _join,
                icon: household.isRunning(HouseholdAction.join)
                    ? const _ButtonSpinner()
                    : const Icon(Icons.login_rounded),
                label: Text(
                  household.isRunning(HouseholdAction.join)
                      ? 'Joining household…'
                      : 'Join household',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Invitation acceptance: shows where the code leads before joining.
class _InvitationAcceptDialog extends StatelessWidget {
  const _InvitationAcceptDialog({required this.preview});

  final InvitationPreview preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.mark_email_read_outlined),
      title: Text('Join ${preview.householdName}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (preview.invitedByName != null)
            Text('Invited by ${preview.invitedByName}.'),
          const SizedBox(height: Spacing.sm),
          Text(
            'Members can see, add, edit and delete shared transactions and '
            'shared budgets. Your personal transactions and budgets stay '
            'private.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Code valid until '
            '${DateFormat('d MMM yyyy, HH:mm').format(preview.expiresAt)}.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('acceptInvitationButton'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Join'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------- household details

class _HouseholdDetails extends StatelessWidget {
  const _HouseholdDetails();

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final info = household.household!;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.sm,
        Spacing.lg,
        Spacing.xxl,
      ),
      children: [
        AppCard(
          child: Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.home_rounded,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: Spacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      info.name.isEmpty ? 'Loading…' : info.name,
                      key: const Key('householdName'),
                      style: theme.textTheme.titleLarge,
                    ),
                    Text(
                      '${household.role?.label ?? 'Member'} · '
                      '${household.members.length} '
                      '${household.members.length == 1 ? 'member' : 'members'}'
                      '${household.phase == HouseholdPhase.cached ? ' · offline' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Spacing.lg),
        const _MembersCard(),
        if (household.isOwner) ...[
          const SizedBox(height: Spacing.lg),
          const _InvitationsCard(),
        ],
        const SizedBox(height: Spacing.lg),
        const _SettingsCard(),
      ],
    );
  }
}

class _MembersCard extends StatelessWidget {
  const _MembersCard();

  Future<void> _remove(BuildContext context, HouseholdMember member) async {
    final household = context.read<HouseholdProvider>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Remove ${member.name}?',
      message:
          '${member.name} will lose access to shared transactions and '
          'budgets. The shared history stays in the household. Their '
          'personal data is not affected.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await household.removeMember(member.uid);
    ok
        ? _showResult(messenger, '${member.name} was removed')
        : _showError(messenger, household);
  }

  Future<void> _transfer(BuildContext context, HouseholdMember member) async {
    final household = context.read<HouseholdProvider>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Make ${member.name} the owner?',
      message:
          'Only the owner can invite and remove members, change household '
          'settings or delete the household. You will become a member.',
      confirmLabel: 'Transfer',
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await household.transferOwnership(member.uid);
    ok
        ? _showResult(messenger, '${member.name} is now the owner')
        : _showError(messenger, household);
  }

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final me = context.select<AuthProvider, AppUser?>((a) => a.user);
    final theme = Theme.of(context);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
        Spacing.sm,
        Spacing.lg,
        Spacing.sm,
        Spacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: Spacing.sm),
            child: SectionHeader(title: 'Members'),
          ),
          const SizedBox(height: Spacing.sm),
          for (final m in household.members)
            ListTile(
              key: ValueKey('member-${m.uid}'),
              // Your own row follows your account at once; the member
              // document catches up when the server refreshes it.
              leading: UserAvatar(
                user: m.uid == household.uid && me?.uid == m.uid
                    ? me!
                    : m.profile,
                radius: 20,
              ),
              title: Text(
                m.uid == household.uid ? '${m.name} (you)' : m.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (m.email != null) m.email!,
                  '${m.role.label} · ${m.status.label}',
                ].join('\n'),
                style: theme.textTheme.bodySmall,
              ),
              isThreeLine: m.email != null,
              trailing:
                  household.isRunning(
                        HouseholdAction.removeMember,
                        target: m.uid,
                      ) ||
                      household.isRunning(
                        HouseholdAction.transfer,
                        target: m.uid,
                      )
                  ? _TileSpinner(key: ValueKey('memberProgress-${m.uid}'))
                  : household.isOwner && m.uid != household.uid
                  ? PopupMenuButton<String>(
                      key: ValueKey('memberMenu-${m.uid}'),
                      tooltip: 'Member options',
                      enabled: !household.isBusy,
                      onSelected: (action) => action == 'remove'
                          ? _remove(context, m)
                          : _transfer(context, m),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'transfer',
                          child: Text('Make owner'),
                        ),
                        PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove from household'),
                        ),
                      ],
                    )
                  : _RoleChip(role: m.role),
            ),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip({required this.role});

  final HouseholdRole role;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = role == HouseholdRole.owner
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        role.label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _InvitationsCard extends StatelessWidget {
  const _InvitationsCard();

  Future<void> _invite(BuildContext context) async {
    final code = await showModalBottomSheet<InvitationCode>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: const _InviteSheet(),
      ),
    );
    if (code == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _InvitationCodeDialog(code: code),
    );
  }

  Future<void> _revoke(
    BuildContext context,
    HouseholdInvitation invitation,
  ) async {
    final household = context.read<HouseholdProvider>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Revoke invitation?',
      message: 'The code will stop working immediately.',
      confirmLabel: 'Revoke',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await household.revokeInvitation(invitation.id);
    ok
        ? _showResult(messenger, 'Invitation revoked')
        : _showError(messenger, household);
  }

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final theme = Theme.of(context);
    final now = DateTime.now();
    final date = DateFormat('d MMM, HH:mm');
    return AppCard(
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
              title: 'Invitations',
              subtitle: 'One-time codes, valid for 7 days',
              trailing: FilledButton.tonalIcon(
                key: const Key('inviteMemberButton'),
                onPressed: household.isBusy ? null : () => _invite(context),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Invite'),
              ),
            ),
          ),
          if (household.invitations.isEmpty)
            const EmptyState(
              icon: Icons.mail_outline_rounded,
              title: 'No invitations yet',
              compact: true,
            )
          else
            for (final inv in household.invitations)
              Builder(
                builder: (context) {
                  final status = inv.statusAt(now);
                  final details = <String>[
                    status.label,
                    if (inv.invitedEmail != null) 'for ${inv.invitedEmail}',
                    switch (status) {
                      InvitationStatus.pending =>
                        'expires ${date.format(inv.expiresAt)}',
                      InvitationStatus.accepted =>
                        'joined: ${inv.acceptedByName ?? 'a member'}',
                      InvitationStatus.expired =>
                        'expired ${date.format(inv.expiresAt)}',
                      InvitationStatus.revoked => 'no longer valid',
                    },
                  ];
                  return ListTile(
                    key: ValueKey('invitation-${inv.id}'),
                    leading: Icon(switch (status) {
                      InvitationStatus.pending => Icons.schedule_rounded,
                      InvitationStatus.accepted => Icons.check_circle_rounded,
                      InvitationStatus.expired => Icons.timer_off_outlined,
                      InvitationStatus.revoked => Icons.block_rounded,
                    }),
                    title: Text(
                      inv.code == null
                          ? 'Invitation'
                          : formatInvitationCode(inv.code!),
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                        letterSpacing: 1.2,
                      ),
                    ),
                    subtitle: Text(details.join(' · ')),
                    trailing: status == InvitationStatus.pending
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (inv.code != null)
                                IconButton(
                                  tooltip: 'Copy code',
                                  icon: const Icon(Icons.copy_rounded),
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(
                                        text: formatInvitationCode(inv.code!),
                                      ),
                                    );
                                    if (context.mounted) {
                                      showAppSnackBar(context, 'Code copied');
                                    }
                                  },
                                ),
                              if (household.isRunning(
                                HouseholdAction.revoke,
                                target: inv.id,
                              ))
                                const Padding(
                                  padding: EdgeInsets.all(Spacing.md),
                                  child: _ButtonSpinner(),
                                )
                              else
                                IconButton(
                                  tooltip: 'Revoke',
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: household.isBusy
                                      ? null
                                      : () => _revoke(context, inv),
                                ),
                            ],
                          )
                        : null,
                  );
                },
              ),
        ],
      ),
    );
  }
}

class _InviteSheet extends StatefulWidget {
  const _InviteSheet();

  @override
  State<_InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends State<_InviteSheet> {
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final household = context.read<HouseholdProvider>();
    if (household.isBusy) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final code = await household.createInvitation(email: _email.text);
    if (!mounted) return;
    if (code == null) {
      _showError(messenger, household);
      return;
    }
    navigator.pop(code);
  }

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final theme = Theme.of(context);
    // Scrolls when the keyboard leaves too little room (landscape, small
    // phones), so the create button stays reachable.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Spacing.lg,
          Spacing.sm,
          Spacing.lg,
          Spacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Invite a member', style: theme.textTheme.titleLarge),
            const SizedBox(height: Spacing.sm),
            Text(
              'You get a one-time code that is valid for 7 days. The person '
              'signs in with their own account and enters it under '
              'Household → Join.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: Spacing.lg),
            TextField(
              key: const Key('inviteEmailField'),
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Their email (optional)',
                helperText: 'When set, only this account can use the code',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
            ),
            const SizedBox(height: Spacing.lg),
            FilledButton.icon(
              key: const Key('createInvitationButton'),
              onPressed: household.isBusy ? null : _create,
              icon: household.isRunning(HouseholdAction.invite)
                  ? const _ButtonSpinner()
                  : const Icon(Icons.vpn_key_rounded),
              label: const Text('Create invitation code'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InvitationCodeDialog extends StatelessWidget {
  const _InvitationCodeDialog({required this.code});

  final InvitationCode code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final householdName =
        context.read<HouseholdProvider>().household?.name ?? 'my household';
    final message =
        'Join "$householdName" on MoneyMate: open Settings → Household → '
        'Join and enter the code ${code.formatted} (valid until '
        '${DateFormat('d MMM yyyy').format(code.expiresAt)}).';
    return AlertDialog(
      scrollable: true,
      title: const Text('Invitation code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectableText(
            code.formatted,
            key: const Key('invitationCodeText'),
            style: theme.textTheme.headlineMedium?.copyWith(
              letterSpacing: 2,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Text(
            'Valid until ${DateFormat('d MMM yyyy, HH:mm').format(code.expiresAt)}. '
            'It works once.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: code.formatted));
            if (context.mounted) showAppSnackBar(context, 'Code copied');
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Copy'),
        ),
        TextButton.icon(
          onPressed: () => SharePlus.instance.share(
            ShareParams(text: message, subject: 'MoneyMate invitation'),
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
  }
}

// ------------------------------------------------------------------ settings

class _SettingsCard extends StatelessWidget {
  const _SettingsCard();

  Future<void> _rename(BuildContext context) async {
    final household = context.read<HouseholdProvider>();
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          _RenameHouseholdDialog(initialName: household.household?.name ?? ''),
    );
    if (name == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await household.renameHousehold(name);
    ok
        ? _showResult(messenger, 'Household renamed')
        : _showError(messenger, household);
  }

  Future<void> _leave(BuildContext context) async {
    final household = context.read<HouseholdProvider>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Leave ${household.household?.name ?? 'household'}?',
      message:
          'Shared transactions and budgets will be removed from your '
          'devices. They stay in the household for the other members. Your '
          'personal data is not affected.',
      confirmLabel: 'Leave',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final id = household.householdId;
    if (id == null) return;
    final sync = context.read<SyncProvider>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // Uploading pending shared changes is part of the same busy state.
    final ok = await household.leaveHousehold(
      prepare: () => sync.flushHousehold(id),
    );
    if (ok) {
      _showResult(messenger, 'You left the household');
      if (context.mounted) navigator.maybePop();
    } else {
      _showError(messenger, household);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final household = context.read<HouseholdProvider>();
    if (household.isBusy) return;
    if (household.members.length > 1) {
      showAppSnackBar(
        context,
        'Remove the other members (or transfer ownership and leave) before '
        'deleting the household.',
        isError: true,
      );
      return;
    }
    final confirmed = await showConfirmDialog(
      context,
      title: 'Delete ${household.household?.name ?? 'household'}?',
      message:
          'This permanently deletes the household with all its shared '
          'transactions and budgets from the cloud. Shared transactions you '
          'added that have not been uploaded are kept as personal ones. Your '
          'personal data is not affected.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await household.deleteHousehold();
    if (ok) {
      // The screen switches to create / join, and the dashboard returns to
      // personal data once the shared records are released.
      _showResult(messenger, 'Household deleted');
    } else {
      _showError(messenger, household);
    }
  }

  @override
  Widget build(BuildContext context) {
    final household = context.watch<HouseholdProvider>();
    final error = Theme.of(context).colorScheme.error;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          if (household.isOwner)
            ListTile(
              key: const Key('renameHouseholdTile'),
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Rename household'),
              trailing: household.isRunning(HouseholdAction.rename)
                  ? const _TileSpinner()
                  : null,
              enabled: !household.isBusy,
              onTap: () => _rename(context),
            ),
          if (!household.isOwner)
            ListTile(
              key: const Key('leaveHouseholdTile'),
              leading: Icon(Icons.logout_rounded, color: error),
              title: Text(
                household.isRunning(HouseholdAction.leave)
                    ? 'Leaving household…'
                    : 'Leave household',
                style: TextStyle(color: error),
              ),
              trailing: household.isRunning(HouseholdAction.leave)
                  ? const _TileSpinner(key: Key('leaveHouseholdProgress'))
                  : null,
              enabled: !household.isBusy,
              onTap: () => _leave(context),
            ),
          if (household.isOwner)
            ListTile(
              key: const Key('deleteHouseholdTile'),
              leading: Icon(Icons.delete_forever_outlined, color: error),
              title: Text(
                household.isRunning(HouseholdAction.delete)
                    ? 'Deleting household…'
                    : 'Delete household',
                style: TextStyle(color: error),
              ),
              subtitle: const Text(
                'To leave as owner, first make another member the owner',
              ),
              trailing: household.isRunning(HouseholdAction.delete)
                  ? const _TileSpinner(key: Key('deleteHouseholdProgress'))
                  : null,
              enabled: !household.isBusy,
              onTap: () => _delete(context),
            ),
        ],
      ),
    );
  }
}

/// Owns its text controller, so the controller lives until the dialog's
/// closing animation (which still shows the field) has finished.
class _RenameHouseholdDialog extends StatefulWidget {
  const _RenameHouseholdDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameHouseholdDialog> createState() => _RenameHouseholdDialogState();
}

class _RenameHouseholdDialogState extends State<_RenameHouseholdDialog> {
  late final _controller = TextEditingController(text: widget.initialName);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Household name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 40,
        textCapitalization: TextCapitalization.words,
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}

/// Progress indicator in a list tile's trailing slot.
class _TileSpinner extends StatelessWidget {
  const _TileSpinner({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 22,
    child: CircularProgressIndicator(strokeWidth: 2.5),
  );
}
