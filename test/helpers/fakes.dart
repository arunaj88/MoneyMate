import 'dart:typed_data';
import 'dart:async';

import 'package:money_mate/core/services/auth_service.dart';
import 'package:money_mate/core/services/backup_service.dart';
import 'package:money_mate/core/services/recurring_scheduler.dart';
import 'package:money_mate/core/services/transaction_calculator.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/category_model.dart';
import 'package:money_mate/models/recurring_model.dart';
import 'package:money_mate/models/report_models.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/scope_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/repositories/app_settings_repository.dart';
import 'package:money_mate/repositories/budget_repository.dart';
import 'package:money_mate/repositories/category_repository.dart';
import 'package:money_mate/repositories/recurring_repository.dart';
import 'package:money_mate/repositories/savings_repository.dart';
import 'package:money_mate/repositories/transaction_repository.dart';

/// In-memory repositories for widget tests (no real I/O, so they work
/// inside the fake-async zone used by `testWidgets`).
class InMemoryCategoryRepository implements CategoryRepository {
  InMemoryCategoryRepository([List<CategoryModel>? initial])
    : items = [...(initial ?? DefaultCategories.all)];

  final List<CategoryModel> items;

  @override
  Future<List<CategoryModel>> getAll() async => [...items];

  @override
  Future<void> insert(CategoryModel category) async => items.add(category);

  @override
  Future<void> update(CategoryModel category) async {
    final i = items.indexWhere((c) => c.id == category.id);
    if (i >= 0) items[i] = category;
  }

  @override
  Future<void> delete(CategoryModel category) async =>
      items.removeWhere((c) => c.id == category.id);

  @override
  Future<bool> nameExists(
    String name,
    TransactionType type, {
    String? excludeId,
  }) async => items.any(
    (c) =>
        c.name.toLowerCase() == name.trim().toLowerCase() &&
        c.type == type &&
        c.id != excludeId,
  );
}

class InMemoryTransactionRepository implements TransactionRepository {
  InMemoryTransactionRepository({
    List<TransactionModel>? initial,
    Map<String, String>? categoryNames,
  }) : items = [...?initial],
       categoryNames =
           categoryNames ??
           {for (final c in DefaultCategories.all) c.id: c.name};

  final List<TransactionModel> items;
  final Map<String, String> categoryNames;

  bool _inRange(DateTime d, DateRange? r) => r == null || r.contains(d);

  List<TransactionModel> _in(ScopeFilter scope) =>
      items.where((t) => scope.accepts(t.scope, t.householdId)).toList();

  @override
  Future<List<TransactionModel>> getTransactions({
    TransactionFilter filter = const TransactionFilter(),
    int? limit,
  }) async {
    final q = filter.query.trim().toLowerCase();
    final result = _in(filter.scope).where((t) {
      if (filter.type != null && t.type != filter.type) return false;
      if (filter.categoryIds.isNotEmpty &&
          !filter.categoryIds.contains(t.categoryId)) {
        return false;
      }
      if (filter.start != null && t.date.isBefore(filter.start!)) return false;
      if (filter.end != null && !t.date.isBefore(filter.end!)) return false;
      if (q.isNotEmpty &&
          !t.note.toLowerCase().contains(q) &&
          !(categoryNames[t.categoryId] ?? '').toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList()..sort((a, b) => b.date.compareTo(a.date));
    return limit == null ? result : result.take(limit).toList();
  }

  @override
  Future<TransactionModel?> getById(String id) async {
    for (final t in items) {
      if (t.id == id) return t;
    }
    return null;
  }

  @override
  Future<void> insert(TransactionModel transaction) async =>
      items.add(transaction);

  @override
  Future<void> update(TransactionModel transaction) async {
    final i = items.indexWhere((t) => t.id == transaction.id);
    items[i] = transaction;
  }

  @override
  Future<void> delete(String id, {DataScope? scope}) async =>
      items.removeWhere((t) => t.id == id);

  @override
  Future<int> sumAmount({
    required TransactionType type,
    DateRange? range,
    String? categoryId,
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async => _in(scope)
      .where(
        (t) =>
            t.type == type &&
            _inRange(t.date, range) &&
            (categoryId == null || t.categoryId == categoryId),
      )
      .fold<int>(0, (s, t) => s + t.amountMinor);

  @override
  Future<List<PeriodTotals>> totalsForRanges(
    List<DateRange> ranges, {
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async => [
    for (final r in ranges)
      PeriodTotals(
        range: r,
        incomeMinor: TransactionCalculator.totalIncome(_in(scope), range: r),
        expenseMinor: TransactionCalculator.totalExpense(_in(scope), range: r),
      ),
  ];

  @override
  Future<List<CategoryTotal>> totalsByCategory({
    required TransactionType type,
    required DateRange range,
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async =>
      TransactionCalculator.totalsByCategory(_in(scope), type, range: range);

  @override
  Future<List<int>> categorySpendForRanges(
    String categoryId,
    List<DateRange> ranges, {
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async => [
    for (final r in ranges)
      await sumAmount(
        type: TransactionType.expense,
        range: r,
        categoryId: categoryId,
        scope: scope,
      ),
  ];

  @override
  Future<List<DailyTotal>> dailyTotals({
    required TransactionType type,
    required DateRange range,
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async => TransactionCalculator.dailyTotals(_in(scope), type, range);

  @override
  Future<({int income, int expense})> archivedTotals({
    ScopeFilter scope = const ScopeFilter.personal(),
  }) async => (income: 0, expense: 0);

  @override
  Future<int> countForCategory(String categoryId) async =>
      items.where((t) => t.categoryId == categoryId).length;
}

class InMemoryBudgetRepository implements BudgetRepository {
  final List<BudgetTarget> targets = [];
  final List<CategoryBudget> categoryBudgets = [];

  @override
  Future<List<BudgetTarget>> getTargetVersions(
    BudgetPeriod period, {
    DataScope scope = const DataScope.personal(),
  }) async =>
      targets
          .where(
            (t) => t.period == period && t.householdId == scope.householdId,
          )
          .toList()
        ..sort((a, b) => a.effectiveFrom.compareTo(b.effectiveFrom));

  @override
  Future<void> setTarget({
    required BudgetPeriod period,
    required int amountMinor,
    required DateTime effectiveFrom,
    DataScope scope = const DataScope.personal(),
    String? updatedBy,
  }) async {
    targets.removeWhere(
      (t) =>
          t.period == period &&
          t.effectiveFrom == effectiveFrom &&
          t.householdId == scope.householdId,
    );
    targets.add(
      BudgetTarget(
        period: period,
        amountMinor: amountMinor,
        effectiveFrom: effectiveFrom,
        updatedAt: DateTime.now(),
        householdId: scope.householdId,
        updatedBy: updatedBy,
      ),
    );
  }

  @override
  Future<List<CategoryBudget>> getCategoryBudgets({
    DataScope scope = const DataScope.personal(),
  }) async => [
    for (final b in categoryBudgets)
      if (b.householdId == scope.householdId) b,
  ];

  @override
  Future<void> upsertCategoryBudget(CategoryBudget budget) async {
    categoryBudgets.removeWhere(
      (b) =>
          b.id == budget.id ||
          (b.categoryId == budget.categoryId &&
              b.period == budget.period &&
              b.householdId == budget.householdId),
    );
    categoryBudgets.add(budget);
  }

  @override
  Future<void> deleteCategoryBudget(String id) async =>
      categoryBudgets.removeWhere((b) => b.id == id);
}

class InMemoryAppSettingsRepository implements AppSettingsRepository {
  final Map<String, String> values = {};

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<Map<String, String>> getByPrefix(String prefix) async => {
    for (final e in values.entries)
      if (e.key.startsWith(prefix)) e.key: e.value,
  };

  @override
  Future<void> set(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

class FakeBackupService implements BackupService {
  @override
  Future<String> createBackupJson({Map<String, Object>? settings}) async =>
      '{}';

  @override
  Future<Uint8List> createTransactionsWorkbook({
    required ViewScope view,
    String? householdId,
    String? householdName,
    required String currencyCode,
  }) async => Uint8List(0);

  @override
  Future<void> restore(BackupContents contents) async {}
}

/// Builds a transaction with sensible defaults for tests.
TransactionModel tx({
  required String id,
  required int amountMinor,
  required DateTime date,
  TransactionType type = TransactionType.expense,
  String categoryId = 'exp_food',
  String note = '',
  String? householdId,
  String? createdBy,
}) {
  return TransactionModel(
    id: id,
    type: type,
    amountMinor: amountMinor,
    categoryId: categoryId,
    date: date,
    note: note,
    createdAt: date,
    updatedAt: date,
    scope: householdId == null
        ? TransactionScope.personal
        : TransactionScope.shared,
    householdId: householdId,
    createdBy: createdBy,
  );
}

const testUser = AppUser(
  uid: 'uid-1',
  email: 'sam.lee@example.com',
  displayName: 'Sam Lee',
);

/// In-memory [AuthService]. Accounts are kept in a map of email → password.
/// Set [gate] to hold requests open (to test loading and duplicate taps).
class FakeAuthService implements AuthService {
  FakeAuthService({AppUser? signedIn, Map<String, String>? accounts})
    : _user = signedIn,
      accounts = accounts ?? {'sam.lee@example.com': 'secret123'};

  final Map<String, String> accounts;
  final _controller = StreamController<AppUser?>.broadcast();
  AppUser? _user;
  Completer<void>? gate;
  AppUser? googleUser = testUser;
  final List<String> calls = [];
  final List<String> resetEmails = [];

  Future<void> _wait() async {
    if (gate != null) await gate!.future;
  }

  void _emit(AppUser? user) {
    _user = user;
    _controller.add(user);
  }

  @override
  Stream<AppUser?> authStateChanges() async* {
    yield _user;
    yield* _controller.stream;
  }

  @override
  AppUser? get currentUser => _user;

  @override
  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    calls.add('signIn');
    await _wait();
    if (accounts[email.trim()] != password) {
      throw AuthException(firebaseAuthMessage('invalid-credential'));
    }
    final user = AppUser(uid: 'uid-${email.hashCode}', email: email.trim());
    _emit(email.trim() == testUser.email ? testUser : user);
    return _user!;
  }

  @override
  Future<AppUser> registerWithEmail({
    required String name,
    required String email,
    required String password,
  }) async {
    calls.add('register');
    await _wait();
    if (accounts.containsKey(email.trim())) {
      throw AuthException(firebaseAuthMessage('email-already-in-use'));
    }
    accounts[email.trim()] = password;
    // Like Firebase, the auth state fires before the display name is set.
    final uid = 'uid-${email.hashCode}';
    _emit(AppUser(uid: uid, email: email.trim()));
    final named = AppUser(uid: uid, email: email.trim(), displayName: name);
    _user = named;
    return named;
  }

  @override
  Future<AppUser?> signInWithGoogle() async {
    calls.add('google');
    await _wait();
    if (googleUser == null) return null;
    _emit(googleUser);
    return googleUser;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    calls.add('reset');
    await _wait();
    resetEmails.add(email);
  }

  @override
  Future<void> signOut() async {
    calls.add('signOut');
    await _wait();
    _emit(null);
  }
}

/// In-memory recurring rules that add their occurrences to [transactions].
class InMemoryRecurringRepository implements RecurringRepository {
  InMemoryRecurringRepository(this.transactions);

  final InMemoryTransactionRepository transactions;
  final List<RecurringRule> rules = [];

  @override
  Future<List<RecurringRule>> getRules() async =>
      [...rules]..sort((a, b) => a.nextDate.compareTo(b.nextDate));

  @override
  Future<void> insert(RecurringRule rule) async => rules.add(rule);

  @override
  Future<void> delete(String id) async => rules.removeWhere((r) => r.id == id);

  @override
  Future<int> commit(DueOccurrences due) async {
    final i = rules.indexWhere((r) => r.id == due.rule.id);
    if (i < 0 || rules[i].nextIndex != due.rule.nextIndex) return 0;
    var added = 0;
    for (final t in due.transactions) {
      if (transactions.items.any((e) => e.id == t.id)) continue;
      transactions.items.add(t);
      added++;
    }
    rules[i] = rules[i].copyWith(nextIndex: due.nextIndex);
    return added;
  }
}

/// In-memory [SavingsRepository] with the same rules as the SQLite one.
class InMemorySavingsRepository implements SavingsRepository {
  final List<SavingsGoal> goals = [];
  final List<SavingsEntry> entries = [];
  final Map<String, List<SharedGoalMember>> members = {};
  final Map<String?, List<SharedGoalInvitation>> invitations = {};

  int _balance(String goalId) => entries
      .where((e) => e.goalId == goalId)
      .fold(0, (s, e) => s + e.signedMinor);

  @override
  Future<List<SavingsGoal>> getGoals({String? uid}) async {
    int rank(SavingsGoal g) => g.status.index;
    final result =
        [
          for (final g in goals)
            g.copyWith(
              savedMinor: _balance(g.id),
              myContributionMinor: entries
                  .where((e) => e.goalId == g.id && e.userUid == uid)
                  .fold<int>(0, (s, e) => s + e.signedMinor),
              memberCount: (members[g.id] ?? const [])
                  .where((m) => m.isActive)
                  .length,
              firstEntryDate: () {
                final dates =
                    entries
                        .where((e) => e.goalId == g.id)
                        .map((e) => e.date)
                        .toList()
                      ..sort();
                return dates.isEmpty ? null : dates.first;
              },
            ),
        ]..sort((a, b) {
          final byStatus = rank(a).compareTo(rank(b));
          return byStatus != 0 ? byStatus : b.createdAt.compareTo(a.createdAt);
        });
    return result;
  }

  @override
  Future<List<SavingsEntry>> getEntries(String goalId) async =>
      entries.where((e) => e.goalId == goalId).toList()
        ..sort((a, b) => b.date.compareTo(a.date));

  @override
  Future<void> insertGoal(SavingsGoal goal, {bool synced = false}) async {
    goals.removeWhere((g) => g.id == goal.id);
    goals.add(goal);
  }

  @override
  Future<void> updateGoal(SavingsGoal goal, {bool synced = false}) async {
    final i = goals.indexWhere((g) => g.id == goal.id);
    if (i < 0) throw const SavingsException('This goal no longer exists.');
    goals[i] = goal;
  }

  @override
  Future<void> deleteGoal(String goalId, DateTime deletedAt) async {
    goals.removeWhere((g) => g.id == goalId);
    entries.removeWhere((e) => e.goalId == goalId);
  }

  @override
  Future<void> addEntry(SavingsEntry entry, {bool synced = false}) async {
    if (!goals.any((g) => g.id == entry.goalId)) {
      throw const SavingsException('This goal no longer exists.');
    }
    if (!synced &&
        !entry.isDeposit &&
        entry.amountMinor > _balance(entry.goalId)) {
      throw const SavingsException(
        'You cannot withdraw more than is saved in this goal.',
      );
    }
    if (entries.any((e) => e.id == entry.id)) return;
    entries.add(entry);
  }

  @override
  Future<void> deleteEntry(String entryId, DateTime deletedAt) async {
    final entry = entries.where((e) => e.id == entryId).firstOrNull;
    if (entry == null) return;
    final goal = goals.where((g) => g.id == entry.goalId).firstOrNull;
    if (goal != null && !goal.isPersonal) {
      throw const SavingsException('Entries of shared goals stay.');
    }
    if (entry.isDeposit && _balance(entry.goalId) - entry.amountMinor < 0) {
      throw const SavingsException(
        'Money from this contribution has already been withdrawn. '
        'Delete the withdrawal first.',
      );
    }
    entries.remove(entry);
  }

  @override
  Future<List<SharedGoalMember>> getMembers(String goalId) async =>
      members[goalId] ?? const [];

  @override
  Future<void> replaceMembers(
    String goalId,
    List<SharedGoalMember> list,
  ) async => members[goalId] = [...list];

  @override
  Future<List<SharedGoalInvitation>> getInvitations({String? goalId}) async =>
      invitations[goalId] ?? const [];

  @override
  Future<void> replaceInvitations(
    List<SharedGoalInvitation> list, {
    String? goalId,
  }) async => invitations[goalId] = [...list];

  @override
  Future<void> releaseSharedGoal(String goalId) async {
    goals.removeWhere((g) => g.id == goalId);
    entries.removeWhere((e) => e.goalId == goalId);
    members.remove(goalId);
    invitations.remove(goalId);
  }
}
