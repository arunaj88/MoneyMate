import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/utils/date_range.dart';
import '../features/budget/screens/budget_screen.dart';
import '../features/dashboard/screens/dashboard_screen.dart';
import '../features/household/widgets/household_widgets.dart';
import '../features/reports/screens/reports_screen.dart';
import '../features/settings/screens/settings_screen.dart';
import '../features/transactions/screens/transactions_screen.dart';
import '../features/transactions/transaction_actions.dart';
import '../models/budget_model.dart';
import '../providers/budget_provider.dart';
import '../providers/dashboard_provider.dart';
import '../providers/recurring_provider.dart';
import '../providers/report_provider.dart';
import '../shared/widgets/budget_progress_bar.dart';

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// When the app resumes on a new day, week and month boundaries may have
  /// moved, so recompute period-based figures. Recurring transactions that
  /// fell due while the app was in the background are added first.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    context.read<RecurringProvider>().runDue();
    final today = PeriodUtils.dateOnly(DateTime.now());
    if (today == _lastActiveDay) return;
    _lastActiveDay = today;
    context.read<DashboardProvider>().refresh();
    context.read<BudgetProvider>().refresh();
    context.read<ReportProvider>().refresh();
  }

  void _select(int index) => setState(() => _index = index);

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
