import 'package:money_mate/models/scope_models.dart';

export 'package:money_mate/models/scope_models.dart' show TransactionScope, ScopeFilter;

/// Whether a transaction adds money (income) or spends it (expense).
enum TransactionType {
  income,
  expense;

  String get label => this == TransactionType.income ? 'Income' : 'Expense';

  static TransactionType fromName(String value) =>
      TransactionType.values.firstWhere(
        (t) => t.name == value,
        orElse: () => throw FormatException('Unknown transaction type: $value'),
      );
}

/// How a transaction was paid / received.
enum PaymentMethod {
  cash,
  card,
  bankTransfer,
  other;

  String get label {
    switch (this) {
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.card:
        return 'Card';
      case PaymentMethod.bankTransfer:
        return 'Bank Transfer';
      case PaymentMethod.other:
        return 'Other';
    }
  }

  static PaymentMethod fromName(String value) => PaymentMethod.values
      .firstWhere((p) => p.name == value, orElse: () => PaymentMethod.other);
}

/// A single income or expense entry.
///
/// [amountMinor] is stored in integer minor units (1/100 of the currency)
/// to avoid floating point rounding errors.
class TransactionModel {
  const TransactionModel({
    required this.id,
    required this.type,
    required this.amountMinor,
    required this.categoryId,
    required this.date,
    this.note = '',
    this.paymentMethod = PaymentMethod.cash,
    required this.createdAt,
    required this.updatedAt,
    this.scope = TransactionScope.personal,
    this.householdId,
    this.createdBy,
    this.createdByName,
    this.updatedBy,
  }) : assert(amountMinor > 0, 'Amount must be greater than zero'),
       assert(
         (scope == TransactionScope.shared) == (householdId != null),
         'Shared transactions need a household; personal ones must not '
         'have one',
       );

  final String id;
  final TransactionType type;
  final int amountMinor;
  final String categoryId;
  final DateTime date;
  final String note;
  final PaymentMethod paymentMethod;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Personal (owner only) or shared with [householdId]'s members.
  final TransactionScope scope;

  /// Household of a shared transaction; null for personal ones.
  final String? householdId;

  /// UID of the user who created it (null for records created before
  /// accounts existed).
  final String? createdBy;

  /// Creator's display name when it was created, for showing shared records
  /// offline.
  final String? createdByName;

  /// UID of the user who last changed it.
  final String? updatedBy;

  bool get isShared => scope == TransactionScope.shared;
  bool get isPersonal => scope == TransactionScope.personal;

  bool get isExpense => type == TransactionType.expense;
  bool get isIncome => type == TransactionType.income;

  /// Positive for income, negative for expenses.
  int get signedAmountMinor => isIncome ? amountMinor : -amountMinor;

  TransactionModel copyWith({
    TransactionType? type,
    int? amountMinor,
    String? categoryId,
    DateTime? date,
    String? note,
    PaymentMethod? paymentMethod,
    DateTime? updatedAt,
    String? createdBy,
    String? createdByName,
    String? updatedBy,
  }) {
    return TransactionModel(
      id: id,
      type: type ?? this.type,
      amountMinor: amountMinor ?? this.amountMinor,
      categoryId: categoryId ?? this.categoryId,
      date: date ?? this.date,
      note: note ?? this.note,
      paymentMethod: paymentMethod ?? this.paymentMethod,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      scope: scope,
      householdId: householdId,
      createdBy: createdBy ?? this.createdBy,
      createdByName: createdByName ?? this.createdByName,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }

  /// A copy that belongs to [scope] / [householdId] instead (used when the
  /// user explicitly moves a transaction between personal and shared).
  TransactionModel withScope(
    TransactionScope scope, {
    String? householdId,
    required DateTime updatedAt,
    String? updatedBy,
  }) {
    return TransactionModel(
      id: id,
      type: type,
      amountMinor: amountMinor,
      categoryId: categoryId,
      date: date,
      note: note,
      paymentMethod: paymentMethod,
      createdAt: createdAt,
      updatedAt: updatedAt,
      scope: scope,
      householdId: scope == TransactionScope.shared ? householdId : null,
      createdBy: createdBy,
      createdByName: createdByName,
      updatedBy: updatedBy ?? this.updatedBy,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'type': type.name,
    'amount_minor': amountMinor,
    'category_id': categoryId,
    'date': date.millisecondsSinceEpoch,
    'note': note,
    'payment_method': paymentMethod.name,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'scope': scope.name,
    'household_id': householdId,
    'created_by': createdBy,
    'created_by_name': createdByName,
    'updated_by': updatedBy,
  };

  factory TransactionModel.fromMap(Map<String, Object?> map) {
    return TransactionModel(
      id: map['id']! as String,
      type: TransactionType.fromName(map['type']! as String),
      amountMinor: map['amount_minor']! as int,
      categoryId: map['category_id']! as String,
      date: DateTime.fromMillisecondsSinceEpoch(map['date']! as int),
      note: (map['note'] as String?) ?? '',
      paymentMethod: PaymentMethod.fromName(
        (map['payment_method'] as String?) ?? '',
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
      // Rows and backups from before households existed are personal.
      scope: _sharedHousehold(map) != null
          ? TransactionScope.shared
          : TransactionScope.personal,
      householdId: _sharedHousehold(map),
      createdBy: map['created_by'] as String?,
      createdByName: map['created_by_name'] as String?,
      updatedBy: map['updated_by'] as String?,
    );
  }

  static String? _sharedHousehold(Map<String, Object?> map) {
    final household = map['household_id'];
    return map['scope'] == TransactionScope.shared.name &&
            household is String &&
            household.isNotEmpty
        ? household
        : null;
  }

  /// JSON representation used for backups (same keys as the database).
  Map<String, Object?> toJson() => toMap();

  factory TransactionModel.fromJson(Map<String, dynamic> json) =>
      TransactionModel.fromMap(json);

  @override
  bool operator ==(Object other) =>
      other is TransactionModel &&
      other.id == id &&
      other.type == type &&
      other.amountMinor == amountMinor &&
      other.categoryId == categoryId &&
      other.date == date &&
      other.note == note &&
      other.paymentMethod == paymentMethod &&
      other.updatedAt == updatedAt &&
      other.scope == scope &&
      other.householdId == householdId;

  @override
  int get hashCode => Object.hash(
    id,
    type,
    amountMinor,
    categoryId,
    date,
    note,
    paymentMethod,
    updatedAt,
    scope,
    householdId,
  );
}

/// Criteria used to search and filter transactions.
class TransactionFilter {
  const TransactionFilter({
    this.query = '',
    this.type,
    this.categoryIds = const {},
    this.start,
    this.end,
    this.scope = const ScopeFilter.personal(),
  });

  /// Free text matched against the note and category name.
  final String query;
  final TransactionType? type;
  final Set<String> categoryIds;

  /// Inclusive start of the date range.
  final DateTime? start;

  /// Exclusive end of the date range.
  final DateTime? end;

  /// Personal or household records. Set from the app-wide view
  /// scope, so it is not counted as a user filter.
  final ScopeFilter scope;

  bool get isEmpty =>
      query.trim().isEmpty &&
      type == null &&
      categoryIds.isEmpty &&
      start == null &&
      end == null;

  int get activeFilterCount =>
      (type != null ? 1 : 0) +
      (categoryIds.isNotEmpty ? 1 : 0) +
      (start != null || end != null ? 1 : 0);

  TransactionFilter copyWith({
    String? query,
    TransactionType? Function()? type,
    Set<String>? categoryIds,
    DateTime? Function()? start,
    DateTime? Function()? end,
    ScopeFilter? scope,
  }) {
    return TransactionFilter(
      query: query ?? this.query,
      type: type != null ? type() : this.type,
      categoryIds: categoryIds ?? this.categoryIds,
      start: start != null ? start() : this.start,
      end: end != null ? end() : this.end,
      scope: scope ?? this.scope,
    );
  }
}
