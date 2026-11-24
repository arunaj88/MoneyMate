import '../../models/budget_model.dart';
import '../../models/recurring_model.dart';
import 'notification_cloud.dart';

/// A budget that just crossed 80%, 90% or 100% (see BudgetProvider).
class BudgetAlertEvent {
  const BudgetAlertEvent({this.local, this.household});

  /// Shown on this device; null when the user turned this kind of alert
  /// off.
  final BudgetAlert? local;

  /// For a shared budget: what the other members are told.
  final HouseholdBudgetAlert? household;
}

/// Receives budget alerts as BudgetProvider raises them.
abstract class BudgetAlertSink {
  Future<void> budgetAlertRaised(BudgetAlertEvent event);
}

/// Occurrences of one rule added by a recurring run.
class RecurringAddition {
  const RecurringAddition(this.rule, this.count);

  final RecurringRule rule;
  final int count;
}

/// Receives recurring transactions added automatically (at start-up or
/// when the app resumes), not those added when the user creates a rule.
abstract class RecurringSink {
  Future<void> recurringAdded(List<RecurringAddition> additions);
}
