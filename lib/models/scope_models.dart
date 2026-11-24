/// Who a transaction belongs to.
enum TransactionScope {
  /// Owned by the signed-in user and visible only to them.
  personal,

  /// Owned by a household and visible to all of its active members.
  shared;

  String get label =>
      this == TransactionScope.personal ? 'Personal' : 'Shared household';

  static TransactionScope fromName(String? value) =>
      value == TransactionScope.shared.name
      ? TransactionScope.shared
      : TransactionScope.personal;
}

/// The owner of a set of synchronised records: the user's personal data, or
/// one household's shared data.
///
/// Every synced record (transaction, budget, category) lives in exactly one
/// data scope, locally and in Firestore. Personal and shared records are
/// never mixed: each scope has its own cloud collections, sync cursor,
/// retention clean-up and failure handling.
class DataScope {
  const DataScope.personal() : householdId = null;

  const DataScope.household(String this.householdId);

  /// Null for personal data.
  final String? householdId;

  bool get isPersonal => householdId == null;
  bool get isHousehold => householdId != null;

  TransactionScope get transactionScope =>
      isPersonal ? TransactionScope.personal : TransactionScope.shared;

  /// Value stored in the `household_id` columns of budget, category and
  /// tombstone tables ('' for personal data, so it can be part of a
  /// UNIQUE constraint).
  String get storageKey => householdId ?? '';

  /// Stable text form, used in setting keys.
  String get key => householdId == null ? 'personal' : 'household:$householdId';

  static DataScope fromStorageKey(String? value) =>
      value == null || value.isEmpty
      ? const DataScope.personal()
      : DataScope.household(value);

  @override
  bool operator ==(Object other) =>
      other is DataScope && other.householdId == householdId;

  @override
  int get hashCode => householdId.hashCode;

  @override
  String toString() => 'DataScope($key)';
}

/// Which transactions a screen shows: the user's personal records or the
/// selected household's shared records. The two are never mixed on screen.
enum ViewScope {
  personal,
  shared;

  String get label => switch (this) {
    ViewScope.personal => 'Personal',
    ViewScope.shared => 'Household',
  };

  /// Unknown values (including the retired "combined" view saved by older
  /// versions) fall back to personal.
  static ViewScope fromName(String? value) => ViewScope.values.firstWhere(
    (v) => v.name == value,
    orElse: () => ViewScope.personal,
  );
}

/// Restricts transaction queries to personal and/or one household's shared
/// records. Every record has exactly one scope, so combining both never
/// counts the same transaction twice.
class ScopeFilter {
  const ScopeFilter._({required this.includePersonal, this.householdId});

  /// Only the signed-in user's personal transactions.
  const ScopeFilter.personal() : this._(includePersonal: true);

  /// Only [householdId]'s shared transactions.
  const ScopeFilter.shared(String householdId)
    : this._(includePersonal: false, householdId: householdId);

  /// Personal transactions plus [householdId]'s shared ones (personal only
  /// when [householdId] is null).
  const ScopeFilter.combined(String? householdId)
    : this._(includePersonal: true, householdId: householdId);

  /// Builds the filter for [view]; without a household every view falls
  /// back to personal data.
  factory ScopeFilter.forView(ViewScope view, String? householdId) {
    if (householdId == null) return const ScopeFilter.personal();
    return switch (view) {
      ViewScope.personal => const ScopeFilter.personal(),
      ViewScope.shared => ScopeFilter.shared(householdId),
    };
  }

  final bool includePersonal;
  final String? householdId;

  bool get includesShared => householdId != null;

  /// The data scopes this filter reads from.
  List<DataScope> get dataScopes => [
    if (includePersonal) const DataScope.personal(),
    if (householdId != null) DataScope.household(householdId!),
  ];

  /// True when a record with [scope] / [recordHouseholdId] passes.
  bool accepts(TransactionScope scope, String? recordHouseholdId) =>
      scope == TransactionScope.personal
      ? includePersonal
      : householdId != null && recordHouseholdId == householdId;

  /// SQL condition for the `transactions` table aliased as [alias] (empty
  /// for no alias), with its arguments.
  ({String sql, List<Object?> args}) sql([String alias = '']) {
    final p = alias.isEmpty ? '' : '$alias.';
    final personal = "${p}scope = 'personal'";
    final shared = "(${p}scope = 'shared' AND ${p}household_id = ?)";
    if (includePersonal && householdId != null) {
      return (sql: '($personal OR $shared)', args: [householdId]);
    }
    if (householdId != null) return (sql: shared, args: [householdId]);
    return (sql: personal, args: const []);
  }

  @override
  bool operator ==(Object other) =>
      other is ScopeFilter &&
      other.includePersonal == includePersonal &&
      other.householdId == householdId;

  @override
  int get hashCode => Object.hash(includePersonal, householdId);

  @override
  String toString() =>
      'ScopeFilter(personal: $includePersonal, household: $householdId)';
}
