import '../core/utils/date_range.dart';

/// Length of a budget period.
enum BudgetPeriod {
  weekly,
  monthly;

  String get label => this == BudgetPeriod.weekly ? 'Weekly' : 'Monthly';
  String get noun => this == BudgetPeriod.weekly ? 'week' : 'month';

  static BudgetPeriod fromName(String value) => BudgetPeriod.values.firstWhere(
    (p) => p.name == value,
    orElse: () => throw FormatException('Unknown budget period: $value'),
  );
}

/// Severity of a budget alert, ordered from least to most severe.
enum BudgetAlertLevel {
  none,
  approaching, // >= 80 %
  warning, // >= 90 %
  exceeded; // >= 100 %

  bool operator >(BudgetAlertLevel other) => index > other.index;
  bool operator <(BudgetAlertLevel other) => index < other.index;
}

/// An overall spending target for a period type.
///
/// Targets are versioned: every change inserts a row whose [effectiveFrom] is
/// the start of the period in which it was set. The target that applied to a
/// historical period is the latest version effective on or before that
/// period's start, so historical budget information is never lost.
/// An [amountMinor] of zero means the target was removed from that point.
class BudgetTarget {
  const BudgetTarget({
    this.id,
    required this.period,
    required this.amountMinor,
    required this.effectiveFrom,
    required this.updatedAt,
    this.householdId,
    this.updatedBy,
  });

  final int? id;
  final BudgetPeriod period;
  final int amountMinor;
  final DateTime effectiveFrom;
  final DateTime updatedAt;

  /// Household of a shared budget; null for a personal one.
  final String? householdId;

  /// UID of the member who set it (shared budgets).
  final String? updatedBy;

  bool get isActive => amountMinor > 0;

  /// Stable cloud document ID: one version per period start.
  String get cloudId =>
      'target_${period.name}_${effectiveFrom.millisecondsSinceEpoch}';

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'household_id': householdId ?? '',
    'period': period.name,
    'amount_minor': amountMinor,
    'effective_from': effectiveFrom.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'updated_by': updatedBy,
  };

  factory BudgetTarget.fromMap(Map<String, Object?> map) => BudgetTarget(
    id: map['id'] as int?,
    period: BudgetPeriod.fromName(map['period']! as String),
    amountMinor: map['amount_minor']! as int,
    effectiveFrom: DateTime.fromMillisecondsSinceEpoch(
      map['effective_from']! as int,
    ),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
    householdId: _household(map['household_id']),
    updatedBy: map['updated_by'] as String?,
  );

  /// Backup format (personal budgets only, unchanged since v1).
  Map<String, Object?> toJson() => toMap()
    ..remove('id')
    ..remove('household_id')
    ..remove('updated_by');

  factory BudgetTarget.fromJson(Map<String, dynamic> json) =>
      BudgetTarget.fromMap(json);
}

/// A spending limit for a single category over a weekly or monthly period.
class CategoryBudget {
  const CategoryBudget({
    required this.id,
    required this.categoryId,
    required this.period,
    required this.amountMinor,
    required this.createdAt,
    required this.updatedAt,
    this.householdId,
    this.updatedBy,
  }) : assert(amountMinor > 0);

  final String id;
  final String categoryId;
  final BudgetPeriod period;
  final int amountMinor;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Household of a shared category budget; null for a personal one.
  final String? householdId;

  /// UID of the member who last changed it (shared budgets).
  final String? updatedBy;

  /// Stable cloud document ID.
  String get cloudId => 'category_$id';

  CategoryBudget copyWith({int? amountMinor, DateTime? updatedAt}) =>
      CategoryBudget(
        id: id,
        categoryId: categoryId,
        period: period,
        amountMinor: amountMinor ?? this.amountMinor,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        householdId: householdId,
        updatedBy: updatedBy,
      );

  Map<String, Object?> toMap() => {
    'id': id,
    'household_id': householdId ?? '',
    'category_id': categoryId,
    'period': period.name,
    'amount_minor': amountMinor,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'updated_by': updatedBy,
  };

  factory CategoryBudget.fromMap(Map<String, Object?> map) => CategoryBudget(
    id: map['id']! as String,
    categoryId: map['category_id']! as String,
    period: BudgetPeriod.fromName(map['period']! as String),
    amountMinor: map['amount_minor']! as int,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
    householdId: _household(map['household_id']),
    updatedBy: map['updated_by'] as String?,
  );

  /// Backup format (personal budgets only, unchanged since v1).
  Map<String, Object?> toJson() => toMap()
    ..remove('household_id')
    ..remove('updated_by');

  factory CategoryBudget.fromJson(Map<String, dynamic> json) =>
      CategoryBudget.fromMap(json);
}

String? _household(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Computed progress of spending against a target for one period.
class BudgetStatus {
  const BudgetStatus({
    required this.period,
    required this.range,
    required this.targetMinor,
    required this.spentMinor,
    required this.remainingMinor,
    required this.usagePercent,
    required this.alertLevel,
  });

  final BudgetPeriod period;
  final DateRange range;

  /// Null when no target applies to this period.
  final int? targetMinor;
  final int spentMinor;

  /// Target minus spent; negative when over budget. Null without a target.
  final int? remainingMinor;

  /// Percentage of the target consumed (may exceed 100). Null without target.
  final double? usagePercent;
  final BudgetAlertLevel alertLevel;

  bool get hasTarget => targetMinor != null && targetMinor! > 0;
  bool get isExceeded => alertLevel == BudgetAlertLevel.exceeded;

  /// Progress clamped to 0..1 for progress bars.
  double get progress =>
      usagePercent == null ? 0 : (usagePercent! / 100).clamp(0.0, 1.0);
}

/// A category budget combined with the spending in the current period.
class CategoryBudgetStatus {
  const CategoryBudgetStatus({required this.budget, required this.status});

  final CategoryBudget budget;
  final BudgetStatus status;
}

/// An alert raised when spending crosses a threshold.
class BudgetAlert {
  const BudgetAlert({
    required this.key,
    required this.title,
    required this.message,
    required this.level,
  });

  /// Unique key (period + target) used to avoid duplicate alerts.
  final String key;
  final String title;
  final String message;
  final BudgetAlertLevel level;
}
