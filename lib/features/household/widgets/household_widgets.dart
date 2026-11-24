import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/features/household/screens/household_screen.dart';

/// "Shared · Sara" for a shared transaction (with "You" for the user's
/// own), or null for a personal one. Watch [HouseholdProvider] in the
/// caller so names update.
String? sharedLabelFor(HouseholdProvider household, TransactionModel t) {
  if (!t.isShared) return null;
  final String name;
  if (t.createdBy != null && t.createdBy == household.uid) {
    name = 'You';
  } else {
    name =
        household.memberName(t.createdBy) ??
        t.createdByName ??
        'Household member';
  }
  return 'Shared · $name';
}

/// Opens household management (create, join, members, invitations).
Future<void> openHouseholdScreen(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const HouseholdScreen()));

/// Personal / Household switch for the app-wide transaction view.
/// Hidden while the user has no household, so only personal data shows.
class ViewScopeSelector extends StatelessWidget {
  const ViewScopeSelector({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final scope = context.watch<TransactionScopeProvider>();
    if (!scope.canShare) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: SizedBox(
        width: double.infinity,
        child: SegmentedButton<ViewScope>(
          key: const Key('viewScopeSelector'),
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: ViewScope.personal,
              label: Text(ViewScope.personal.label),
              icon: const Icon(Icons.person_outline_rounded),
            ),
            ButtonSegment(
              value: ViewScope.shared,
              label: Text(ViewScope.shared.label),
              icon: const Icon(Icons.home_outlined),
              tooltip: scope.householdName,
            ),
          ],
          selected: {scope.view},
          onSelectionChanged: (s) => scope.setView(s.first),
        ),
      ),
    );
  }
}

/// Small "Shared" / "Personal" marker.
class ScopeBadge extends StatelessWidget {
  const ScopeBadge({super.key, required this.scope});

  final TransactionScope scope;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shared = scope == TransactionScope.shared;
    final color = shared
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            shared ? Icons.group_rounded : Icons.person_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            shared ? 'Shared' : 'Personal',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows household notices (e.g. access ended) once, as a snack bar.
class HouseholdNoticeListener extends StatefulWidget {
  const HouseholdNoticeListener({super.key, required this.child});

  final Widget child;

  @override
  State<HouseholdNoticeListener> createState() =>
      _HouseholdNoticeListenerState();
}

class _HouseholdNoticeListenerState extends State<HouseholdNoticeListener> {
  @override
  Widget build(BuildContext context) {
    final notice = context.select<HouseholdProvider, String?>((h) => h.notice);
    if (notice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final text = context.read<HouseholdProvider>().takeNotice();
        if (text == null) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
        );
      });
    }
    return widget.child;
  }
}
