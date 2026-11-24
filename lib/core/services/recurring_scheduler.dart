import 'package:uuid/uuid.dart';

import '../../models/recurring_model.dart';
import '../../models/transaction_model.dart';
import '../utils/date_range.dart';

/// Occurrences of one rule that are due, and the rule's next index after
/// they are stored.
class DueOccurrences {
  const DueOccurrences(this.rule, this.transactions, this.nextIndex);

  final RecurringRule rule;
  final List<TransactionModel> transactions;
  final int nextIndex;

  bool get isEmpty => transactions.isEmpty;
}

/// Works out which occurrences of a [RecurringRule] are due.
///
/// Pure logic, so the schedule can be tested without a database.
class RecurringScheduler {
  RecurringScheduler._();

  /// Most occurrences created for one rule in one run, so a weekly rule
  /// started years ago cannot block start-up; the rest follow next run.
  static const int maxPerRun = 200;

  static const _uuid = Uuid();

  /// Stable transaction ID of occurrence [index] of [ruleId].
  ///
  /// Deterministic, so running the scheduler twice (or on two devices)
  /// produces the same record instead of a duplicate.
  static String occurrenceId(String ruleId, int index) =>
      _uuid.v5(Namespace.url.value, 'moneymate:recurring:$ruleId:$index');

  /// The occurrences of [rule] due at [now]: the first one is always due
  /// (it is the transaction the user just added), later ones once their
  /// day has started.
  static DueOccurrences due(RecurringRule rule, DateTime now) {
    final today = PeriodUtils.dateOnly(now);
    final result = <TransactionModel>[];
    var index = rule.nextIndex;
    while (result.length < maxPerRun) {
      final date = rule.occurrenceDate(index);
      if (index > 0 && PeriodUtils.dateOnly(date).isAfter(today)) break;
      result.add(
        TransactionModel(
          id: occurrenceId(rule.id, index),
          type: rule.type,
          amountMinor: rule.amountMinor,
          categoryId: rule.categoryId,
          date: date,
          note: rule.note,
          paymentMethod: rule.paymentMethod,
          createdAt: now,
          updatedAt: now,
          scope: rule.scope,
          householdId: rule.householdId,
          createdBy: rule.createdBy,
          createdByName: rule.createdByName,
          updatedBy: rule.createdBy,
        ),
      );
      index++;
    }
    return DueOccurrences(rule, result, index);
  }
}
