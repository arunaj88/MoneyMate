import 'package:intl/intl.dart';

import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/transaction_model.dart';

/// How often a recurring transaction repeats.
enum RecurrenceFrequency {
  weekly,
  monthly,
  yearly;

  String get label => switch (this) {
    RecurrenceFrequency.weekly => 'Weekly',
    RecurrenceFrequency.monthly => 'Monthly',
    RecurrenceFrequency.yearly => 'Yearly',
  };

  static RecurrenceFrequency fromName(String value) =>
      RecurrenceFrequency.values.firstWhere(
        (f) => f.name == value,
        orElse: () => throw FormatException('Unknown frequency: $value'),
      );
}

/// A transaction that repeats on a schedule, such as a monthly salary.
///
/// Occurrence `n` falls on [occurrenceDate]`(n)`, counted from [startDate]
/// (occurrence 0). [nextIndex] is the first occurrence not yet added as a
/// transaction, so each one is created exactly once. Monthly and yearly
/// schedules keep the start day where the month has it and otherwise use
/// the month's last day (a rule started on the 31st lands on 28/29 Feb and
/// 30 Apr, then on the 31st again where it exists).
class RecurringRule {
  const RecurringRule({
    required this.id,
    required this.type,
    required this.amountMinor,
    required this.categoryId,
    required this.frequency,
    required this.startDate,
    this.note = '',
    this.paymentMethod = PaymentMethod.cash,
    this.scope = TransactionScope.personal,
    this.householdId,
    this.nextIndex = 0,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy,
    this.createdByName,
  }) : assert(amountMinor > 0, 'Amount must be greater than zero'),
       assert(nextIndex >= 0),
       assert(
         (scope == TransactionScope.shared) == (householdId != null),
         'Shared rules need a household; personal ones must not have one',
       );

  final String id;
  final TransactionType type;
  final int amountMinor;
  final String categoryId;
  final RecurrenceFrequency frequency;

  /// Date (and time of day) of the first occurrence.
  final DateTime startDate;
  final String note;
  final PaymentMethod paymentMethod;
  final TransactionScope scope;

  /// Household of a shared rule; null for personal ones.
  final String? householdId;

  /// Index of the next occurrence to create.
  final int nextIndex;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdBy;
  final String? createdByName;

  bool get isShared => scope == TransactionScope.shared;
  bool get isIncome => type == TransactionType.income;

  DataScope get dataScope =>
      isShared ? DataScope.household(householdId!) : const DataScope.personal();

  /// Date of the next occurrence that has not been added yet.
  DateTime get nextDate => occurrenceDate(nextIndex);

  /// Date of occurrence [index] (0 = [startDate]).
  DateTime occurrenceDate(int index) {
    final s = startDate;
    switch (frequency) {
      case RecurrenceFrequency.weekly:
        // Calendar arithmetic (not Duration) so DST changes keep the time.
        return DateTime(
          s.year,
          s.month,
          s.day + 7 * index,
          s.hour,
          s.minute,
          s.second,
        );
      case RecurrenceFrequency.monthly:
        return _clamped(s.year, s.month + index, s);
      case RecurrenceFrequency.yearly:
        return _clamped(s.year + index, s.month, s);
    }
  }

  /// [year]/[month] (month may overflow) on [s]'s day, or the month's last
  /// day when it is shorter.
  static DateTime _clamped(int year, int month, DateTime s) {
    final firstOfMonth = DateTime(year, month);
    final lastDay = DateTime(firstOfMonth.year, firstOfMonth.month + 1, 0).day;
    final day = s.day < lastDay ? s.day : lastDay;
    return DateTime(
      firstOfMonth.year,
      firstOfMonth.month,
      day,
      s.hour,
      s.minute,
      s.second,
    );
  }

  /// Human-readable schedule, e.g. "Every month on the 1st".
  String get scheduleLabel => describe(frequency, startDate);

  /// Schedule of a rule repeating at [frequency] from [start].
  static String describe(RecurrenceFrequency frequency, DateTime start) =>
      switch (frequency) {
        RecurrenceFrequency.weekly =>
          'Every week on ${DateFormat('EEEE').format(start)}',
        RecurrenceFrequency.monthly =>
          start.day >= 29
              ? 'Every month on the ${ordinal(start.day)} (or the last day)'
              : 'Every month on the ${ordinal(start.day)}',
        RecurrenceFrequency.yearly =>
          'Every year on ${DateFormat('d MMMM').format(start)}',
      };

  static String ordinal(int n) {
    if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
    return switch (n % 10) {
      1 => '${n}st',
      2 => '${n}nd',
      3 => '${n}rd',
      _ => '${n}th',
    };
  }

  RecurringRule copyWith({int? nextIndex, DateTime? updatedAt}) =>
      RecurringRule(
        id: id,
        type: type,
        amountMinor: amountMinor,
        categoryId: categoryId,
        frequency: frequency,
        startDate: startDate,
        note: note,
        paymentMethod: paymentMethod,
        scope: scope,
        householdId: householdId,
        nextIndex: nextIndex ?? this.nextIndex,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        createdBy: createdBy,
        createdByName: createdByName,
      );

  Map<String, Object?> toMap() => {
    'id': id,
    'type': type.name,
    'amount_minor': amountMinor,
    'category_id': categoryId,
    'frequency': frequency.name,
    'start_date': startDate.millisecondsSinceEpoch,
    'note': note,
    'payment_method': paymentMethod.name,
    'scope': scope.name,
    'household_id': householdId ?? '',
    'next_index': nextIndex,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'created_by': createdBy,
    'created_by_name': createdByName,
  };

  factory RecurringRule.fromMap(Map<String, Object?> map) {
    final household = map['household_id'];
    final shared =
        map['scope'] == TransactionScope.shared.name &&
        household is String &&
        household.isNotEmpty;
    final amount = map['amount_minor']! as int;
    final nextIndex = (map['next_index'] as int?) ?? 0;
    if (amount <= 0 || nextIndex < 0) {
      throw const FormatException('Invalid recurring rule');
    }
    return RecurringRule(
      id: map['id']! as String,
      type: TransactionType.fromName(map['type']! as String),
      amountMinor: amount,
      categoryId: map['category_id']! as String,
      frequency: RecurrenceFrequency.fromName(map['frequency']! as String),
      startDate: DateTime.fromMillisecondsSinceEpoch(map['start_date']! as int),
      note: (map['note'] as String?) ?? '',
      paymentMethod: PaymentMethod.fromName(
        (map['payment_method'] as String?) ?? '',
      ),
      scope: shared ? TransactionScope.shared : TransactionScope.personal,
      householdId: shared ? household : null,
      nextIndex: nextIndex,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
      createdBy: map['created_by'] as String?,
      createdByName: map['created_by_name'] as String?,
    );
  }

  /// JSON representation used for backups (same keys as the database).
  Map<String, Object?> toJson() => toMap();

  factory RecurringRule.fromJson(Map<String, dynamic> json) =>
      RecurringRule.fromMap(json);
}
