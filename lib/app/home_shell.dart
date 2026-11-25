import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/features/budget/screens/budget_screen.dart';
import 'package:money_mate/features/dashboard/screens/dashboard_screen.dart';
import 'package:money_mate/features/household/widgets/household_widgets.dart';
import 'package:money_mate/features/reports/screens/reports_screen.dart';
import 'package:money_mate/features/savings/savings_actions.dart';
import 'package:money_mate/features/settings/screens/settings_screen.dart';
import 'package:money_mate/features/transactions/screens/transactions_screen.dart';
import 'package:money_mate/features/transactions/transaction_actions.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/providers/budget_provider.dart';
import 'package:money_mate/providers/dashboard_provider.dart';
import 'package:money_mate/providers/notification_provider.dart';
import 'package:money_mate/providers/recurring_provider.dart';
import 'package:money_mate/providers/report_provider.dart';
import 'package:money_mate/providers/sync_provider.dart';
import 'package:money_mate/providers/transaction_scope_provider.dart';
import 'package:money_mate/shared/widgets/budget_progress_bar.dart';

/// Bottom navigation container for the five main sections.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int _index = 0;
  DateTime _lastActiveDay = PeriodUtils.dateOnly(DateTime.now());
  bool _showingAlert = false;
  StreamSubscription<void>? _sharedChanges;

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.space_dashboard_outlined),
      selectedIcon: Icon(Icons.space_dashboard_rounded),
      label: 'Dashboard',
    ),
    NavigationDestination(
      icon: Icon(Icons.receipt_long_outlined),
      selectedIcon: Icon(Icons.receipt_long_rounded),
      label: 'Transactions',
    ),
    NavigationDestination(
      icon: Icon(Icons.savings_outlined),
      selectedIcon: Icon(Icons.savings_rounded),
      label: 'Budget',
    ),
    NavigationDestination(
      icon: Icon(Icons.insights_outlined),
      selectedIcon: Icon(Icons.insights_rounded),
      label: 'Reports',
    ),
    NavigationDestination(
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings_rounded),
      label: 'Settings',
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Another member changed shared data: fetch it now, so the open screen
    // (dashboard, transactions, budgets, savings) shows it.
    _sharedChanges = context
        .read<NotificationProvider>()
        .sharedDataChanges
        .listen((_) {
          if (mounted) context.read<SyncProvider>().syncNow();
        });
    // Ask for notifications once the signed-in app is actually on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<NotificationProvider>().askOnFirstUse();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sharedChanges?.cancel();
    super.dispose();
  }

  /// When the app resumes on a new day, week and month boundaries may have
  /// moved, so recompute period-based figures. Recurring transactions that
  /// fell due while the app was in the background are added first.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    context.read<RecurringProvider>().runDue();
    // Notifications may have been allowed in the system settings meanwhile.
    context.read<NotificationProvider>().refreshPermission();
    final today = PeriodUtils.dateOnly(DateTime.now());
    if (today == _lastActiveDay) return;
    _lastActiveDay = today;
    context.read<DashboardProvider>().refresh();
    context.read<BudgetProvider>().refresh();
    context.read<ReportProvider>().refresh();
  }

  void _select(int index) => setState(() => _index = index);

  /// Opens what a tapped notification is about. Anything opened on top of
  /// the home screen (forms, dialogs, other screens) is closed first.
  void _openNotificationTarget() {
    final target = context.read<NotificationProvider>().takePendingTarget();
    if (target == null) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
    final scope = target.scope;
    if (scope != null) _showScope(scope);
    switch (target.destination) {
      case NotificationDestination.dashboard:
        _select(0);
      case NotificationDestination.transactions:
        _select(1);
      case NotificationDestination.budget:
        _select(2);
      case NotificationDestination.household:
        openHouseholdScreen(context);
      case NotificationDestination.savings:
        openSavingsScreen(
          context,
          ownership: switch (target.ownership) {
            'household' => SavingsOwnership.household,
            'shared' => SavingsOwnership.shared,
            _ => SavingsOwnership.personal,
          },
        );
      case NotificationDestination.goal:
        openGoalDetailsById(context, target.goalId!);
    }
  }

  /// Switches the personal / household view (transactions, dashboard and
  /// reports) and the budget screen to [scope]. A different household (one
  /// the user has left) leaves the views as they are. While the household
  /// is still loading (the tap started the app) the household view is
  /// chosen anyway and applies once it has loaded.
  void _showScope(DataScope scope) {
    final views = context.read<TransactionScopeProvider>();
    final current = views.householdId;
    if (scope.isHousehold && current != null && scope.householdId != current) {
      return;
    }
    views.setView(scope.isHousehold ? ViewScope.shared : ViewScope.personal);
    context.read<BudgetProvider>().selectScope(scope);
  }

  void _maybeShowAlerts() {
    if (_showingAlert) return;
    final budget = context.read<BudgetProvider>();
    if (!budget.hasPendingAlerts) return;
    final alerts = budget.takePendingAlerts();
    if (alerts.isEmpty) return;
    _showingAlert = true;

    final mostSevere = alerts.reduce((a, b) => b.level > a.level ? b : a);
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentMaterialBanner();
    messenger
        .showMaterialBanner(
          MaterialBanner(
            key: const Key('budgetAlertBanner'),
            leading: Icon(
              mostSevere.level == BudgetAlertLevel.exceeded
                  ? Icons.error_rounded
                  : Icons.warning_amber_rounded,
              color: budgetLevelColor(context, mostSevere.level),
            ),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in alerts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${a.title}: ',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: a.message),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  messenger.hideCurrentMaterialBanner();
                  _select(2);
                },
                child: const Text('View budget'),
              ),
              TextButton(
                onPressed: messenger.hideCurrentMaterialBanner,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        )
        .closed
        .then((_) => _showingAlert = false);
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild when new alerts arrive and show them after the frame.
    final hasAlerts = context.select<BudgetProvider, bool>(
      (b) => b.hasPendingAlerts,
    );
    if (hasAlerts) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeShowAlerts();
      });
    }
    // A tapped notification (also the one that started the app).
    final hasTarget = context.select<NotificationProvider, bool>(
      (n) => n.pendingTarget != null,
    );
    if (hasTarget) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openNotificationTarget();
      });
    }

    final showFab = _index == 0 || _index == 1;
    // Android back button: return to the dashboard before leaving the app.
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(0);
      },
      child: HouseholdNoticeListener(child: _buildScaffold(showFab)),
    );
  }

  Widget _buildScaffold(bool showFab) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          DashboardScreen(onNavigate: _select),
          const TransactionsScreen(),
          const BudgetScreen(),
          const ReportsScreen(),
          const SettingsScreen(),
        ],
      ),
      floatingActionButton: AnimatedScale(
        scale: showFab ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: _AddTransactionFab(
          key: const Key('addTransactionFab'),
          onPressed: showFab ? () => openTransactionForm(context) : null,
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: _destinations,
      ),
    );
  }
}

/// Minimal circular "+" button with a soft shadow and press feedback.
class _AddTransactionFab extends StatefulWidget {
  const _AddTransactionFab({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<_AddTransactionFab> createState() => _AddTransactionFabState();
}

class _AddTransactionFabState extends State<_AddTransactionFab> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: 'Add transaction',
      child: AnimatedScale(
        scale: _pressed ? 0.92 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: scheme.primary,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onPressed,
              onTapDown: (_) => _setPressed(true),
              onTapUp: (_) => _setPressed(false),
              onTapCancel: () => _setPressed(false),
              child: SizedBox.square(
                dimension: 56,
                child: Icon(
                  Icons.add_rounded,
                  size: 28,
                  color: scheme.onPrimary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
