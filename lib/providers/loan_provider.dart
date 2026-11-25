import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:money_mate/core/services/cloud_loan_store.dart';
import 'package:money_mate/core/services/cloud_transaction_store.dart';
import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/services/loan_reminder_planner.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/models/sync_models.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/providers/notification_provider.dart';
import 'package:money_mate/providers/settings_provider.dart';
import 'package:money_mate/providers/transaction_provider.dart';
import 'package:money_mate/repositories/loan_repository.dart';

export 'package:money_mate/repositories/loan_repository.dart'
    show LoanException;

/// Which loans a list shows.
enum LoanFilter {
  all('All'),
  personal('Personal'),
  household('Household'),
  active('Active'),
  overdue('Overdue'),
  completed('Completed');

  const LoanFilter(this.label);

  final String label;

  bool accepts(LoanSnapshot s) => switch (this) {
    LoanFilter.all => true,
    LoanFilter.personal => s.loan.isPersonal,
    LoanFilter.household => s.loan.isHousehold,
    LoanFilter.active => !s.isCompleted,
    LoanFilter.overdue => s.isOverdue,
    LoanFilter.completed => s.isCompleted,
  };
}

/// An instalment together with its loan, for the upcoming / overdue lists.
@immutable
class DueInstallment {
  const DueInstallment(this.snapshot, this.installment);

  final LoanSnapshot snapshot;
  final InstallmentView installment;

  Loan get loan => snapshot.loan;
}

/// The members a household owner can pick as reminder recipients.
@immutable
class ReminderMember {
  const ReminderMember({
    required this.uid,
    required this.name,
    required this.isOwner,
  });

  final String uid;
  final String name;
  final bool isOwner;
}

/// Money lent (loans given), personal and household: records, schedules,
/// repayments, figures for the dashboard and repayment reminders.
///
/// * **Personal** loans belong to the signed-in user and show in the
///   personal view.
/// * **Household** loans belong to the user's current household (existing
///   membership decides access) and show in the household view.
///
/// Lending is kept completely separate from the money figures: it is never
/// an expense and repaid principal is never income. None of it is a
/// transaction, so the balance, month income and expenses, reports,
/// budgets and savings are unaffected; money lent has its own card and
/// screen. Interest received is shown only in the lending figures.
///
/// Everything except voiding a repayment works offline. Repayment
/// reminders are local notifications scheduled on this device for the
/// signed-in user only; household reminders go to the members the
/// household owner selected (each member's own device schedules theirs
/// from the synced settings).
class LoanProvider extends ChangeNotifier {
  LoanProvider(
    this._repository, {
    CloudLoanStore? cloud,
    LocalNotifier notifier = const NoopLocalNotifier(),
    Uuid? uuid,
    DateTime Function()? clock,
    this.reminderDebounce = const Duration(milliseconds: 400),
  }) : _cloud = cloud,
       _notifier = notifier,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now;

  final LoanRepository? _repository;
  final CloudLoanStore? _cloud;
  final LocalNotifier _notifier;
  final Uuid _uuid;
  final DateTime Function() _clock;

  /// Reminder planning waits this long after the last change, so a burst of
  /// changes (e.g. a sync) reschedules once.
  final Duration reminderDebounce;

  List<Loan> _loans = const [];
  List<LoanRepayment> _repayments = const [];
  Map<String, LoanReminderSettings> _settings = const {};
  List<LoanSnapshot> _snapshots = const [];
  DateTime? _snapshotDay;
  bool _hasLoaded = false;
  bool _isLoading = false;
  String? _error;
  int _version = 0;
  int _localChangeVersion = 0;
  int? _seenDataVersion;
  int _loadToken = 0;
  bool _disposed = false;

  String? _uid;
  String? _userName;
  String? _householdId;
  String? _householdOwnerUid;
  bool _isHouseholdOwner = false;
  List<ReminderMember> _members = const [];
  CurrencyFormatter _formatter = CurrencyFormatter('AED');
  bool _notificationsAllowed = true;

  AuthProvider? _auth;
  Timer? _reminderTimer;
  Future<void> _reminderQueue = Future.value();
  Object? _plannedKey;

  bool get isAvailable => _repository != null;
  bool get hasLoaded => _hasLoaded;
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// Increases whenever the loaded data changes.
  int get version => _version;

  /// Increases after every change made on this device, so sync uploads it.
  int get localChangeVersion => _localChangeVersion;

  String? get uid => _uid;
  String? get householdId => _householdId;
  bool get hasHousehold => _householdId != null;

  /// The signed-in user owns (administers) the current household.
  bool get isHouseholdOwner => _isHouseholdOwner;

  /// Active members of the current household, owner first.
  List<ReminderMember> get householdMembers => _members;

  // ------------------------------------------------------------- reading

  /// Personal loans and the current household's, newest first. Loans of a
  /// household the user left are not shown.
  List<LoanSnapshot> get loans {
    _refreshSnapshotsIfNewDay();
    return [
      for (final s in _snapshots)
        if (s.loan.isPersonal || s.loan.householdId == _householdId) s,
    ];
  }

  List<LoanSnapshot> filtered(LoanFilter filter) => [
    for (final s in loans)
      if (filter.accepts(s)) s,
  ];

  LoanSnapshot? snapshotById(String id) {
    for (final s in loans) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// [loanId]'s repayments, newest first (voided and refused included).
  List<LoanRepayment> repaymentsOf(String loanId) => [
    for (final r in _repayments)
      if (r.loanId == loanId) r,
  ];

  LoanRepayment? repaymentById(String id) {
    for (final r in _repayments) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Reminder settings of [loanId] (defaults when none are stored yet).
  LoanReminderSettings reminderSettingsOf(String loanId) =>
      _settings[loanId] ??
      LoanReminderSettings(
        loanId: loanId,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );

  LendingSummary summaryOf(LoanFilter filter) =>
      LoanCalculator.summarize(filtered(filter));

  List<BorrowerSummary> borrowers(LoanFilter filter) =>
      LoanCalculator.byBorrower(filtered(filter));

  /// Loans of [scope]: personal ones for the personal view, that
  /// household's for the household view.
  List<LoanSnapshot> _ofScope(ScopeFilter scope) => [
    for (final s in _snapshots)
      if (scope.includePersonal
          ? s.loan.isPersonal
          : s.loan.householdId == scope.householdId)
        s,
  ];

  /// Principal lent in [scope] and not yet repaid.
  int lentOutstandingForScope(ScopeFilter scope) =>
      LoanCalculator.summarize(_ofScope(scope)).outstandingPrincipalMinor;

  /// Interest received in [scope] (income from lending).
  int interestForScope(ScopeFilter scope) =>
      LoanCalculator.summarize(_ofScope(scope)).interestReceivedMinor;

  /// Whether [scope] has any loans (the dashboard shows lending then).
  bool hasLoansIn(ScopeFilter scope) => _ofScope(scope).isNotEmpty;

  /// Unpaid instalments not yet overdue, soonest first.
  List<DueInstallment> upcoming(LoanFilter filter, {int limit = 20}) {
    final result = <DueInstallment>[
      for (final s in filtered(filter))
        for (final i in s.installments)
          if (i.status.isOpen && i.status != InstallmentStatus.overdue)
            DueInstallment(s, i),
    ]..sort((a, b) => a.installment.dueDate.compareTo(b.installment.dueDate));
    return result.length > limit ? result.sublist(0, limit) : result;
  }

  /// Instalments past their due date that are not fully paid, oldest
  /// first.
  List<DueInstallment> overdue(LoanFilter filter) => [
    for (final s in filtered(filter))
      for (final i in s.installments)
        if (i.status == InstallmentStatus.overdue) DueInstallment(s, i),
  ]..sort((a, b) => a.installment.dueDate.compareTo(b.installment.dueDate));

  /// Latest repayments that count, of the loans [filter] shows.
  List<({LoanSnapshot snapshot, LoanRepayment repayment})> recentRepayments(
    LoanFilter filter, {
    int limit = 10,
  }) {
    final byId = {for (final s in filtered(filter)) s.id: s};
    final result = <({LoanSnapshot snapshot, LoanRepayment repayment})>[];
    for (final r in _repayments) {
      final s = byId[r.loanId];
      if (s == null || !r.counts) continue;
      result.add((snapshot: s, repayment: r));
      if (result.length >= limit) break;
    }
    return result;
  }

  // ---------------------------------------------------------- permissions

  /// Personal: always. Household: members of the loan's household.
  bool canManage(Loan loan) =>
      loan.isPersonal || (loan.householdId == _householdId && _uid != null);

  /// Personal: always. Household: whoever recorded it, or the owner.
  bool canDelete(Loan loan) =>
      loan.isPersonal ||
      (canManage(loan) && (_isHouseholdOwner || loan.createdBy == _uid));

  /// Personal: the user. Household: the household owner only.
  bool canEditReminders(Loan loan) =>
      loan.isPersonal || (canManage(loan) && _isHouseholdOwner);

  // ------------------------------------------------------------ lifecycle

  /// Called by the ProxyProvider whenever sign-in, the household,
  /// transactions, settings or notifications change.
  void attach({
    required AuthProvider auth,
    required TransactionProvider transactions,
    HouseholdProvider? household,
    SettingsProvider? settings,
    NotificationProvider? notifications,
  }) {
    if (!identical(auth, _auth)) {
      _auth?.removeSignOutHook(_beforeSignOut);
      auth.addSignOutHook(_beforeSignOut);
      _auth = auth;
    }
    final user = auth.isAuthenticated ? auth.user : null;
    final owner = household?.household?.ownerUid;
    _setContext(
      uid: user?.uid,
      name: user?.name,
      householdId: transactions.householdId,
      householdOwnerUid: owner == null || owner.isEmpty ? null : owner,
      isHouseholdOwner: household?.isOwner ?? false,
      members: [
        for (final m in household?.members ?? const [])
          ReminderMember(uid: m.uid, name: m.name, isOwner: m.isOwner),
      ],
      formatter: settings?.formatter,
      notificationsAllowed: switch (notifications?.permission) {
        null => true,
        NotificationPermission.denied => false,
        _ => true,
      },
      dataVersion: transactions.dataVersion,
    );
  }

  /// Sets the context directly (tests).
  @visibleForTesting
  Future<void> setContextForTesting({
    String? uid,
    String? name,
    String? householdId,
    String? householdOwnerUid,
    bool isHouseholdOwner = false,
    List<ReminderMember> members = const [],
    CurrencyFormatter? formatter,
    bool notificationsAllowed = true,
  }) async {
    _setContext(
      uid: uid,
      name: name,
      householdId: householdId,
      householdOwnerUid: householdOwnerUid,
      isHouseholdOwner: isHouseholdOwner,
      members: members,
      formatter: formatter,
      notificationsAllowed: notificationsAllowed,
      dataVersion: _seenDataVersion,
    );
    await load();
  }

  void _setContext({
    required String? uid,
    required String? name,
    required String? householdId,
    required String? householdOwnerUid,
    required bool isHouseholdOwner,
    required List<ReminderMember> members,
    required CurrencyFormatter? formatter,
    required bool notificationsAllowed,
    required int? dataVersion,
  }) {
    if (!isAvailable) return;
    final uidChanged = uid != _uid;
    final contextChanged =
        uidChanged ||
        householdId != _householdId ||
        isHouseholdOwner != _isHouseholdOwner ||
        !listEquals(
          [for (final m in members) m.uid],
          [for (final m in _members) m.uid],
        );
    _uid = uid;
    _userName = name;
    _householdId = householdId;
    _householdOwnerUid = householdOwnerUid;
    _isHouseholdOwner = isHouseholdOwner;
    _members = List.unmodifiable(members);
    if (formatter != null &&
        formatter.currency.code != _formatter.currency.code) {
      _formatter = formatter;
      _scheduleReminders();
    }
    if (notificationsAllowed != _notificationsAllowed) {
      _notificationsAllowed = notificationsAllowed;
      _scheduleReminders();
    }
    if (contextChanged) {
      _version++;
      _scheduleReminders();
      Future.microtask(_notify);
    }
    if (dataVersion == _seenDataVersion && !uidChanged) return;
    _seenDataVersion = dataVersion;
    // Deferred: this runs while the provider tree is building.
    Future.microtask(load);
  }

  Future<void> load() async {
    final repository = _repository;
    if (repository == null) return;
    final token = ++_loadToken;
    _isLoading = true;
    _notify();
    try {
      final loans = await repository.getLoans();
      final repayments = await repository.getRepayments();
      final settings = await repository.getReminderSettings();
      if (token != _loadToken) return;
      _apply(loans, repayments, settings);
      _error = null;
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Could not load your lending records.';
      debugPrint('LoanProvider.load failed: $e');
    } finally {
      if (token == _loadToken) {
        _isLoading = false;
        _hasLoaded = true;
        _notify();
      }
    }
  }

  void _apply(
    List<Loan> loans,
    List<LoanRepayment> repayments,
    Map<String, LoanReminderSettings> settings,
  ) {
    _loans = List.unmodifiable(loans);
    _repayments = List.unmodifiable(repayments);
    _settings = Map.unmodifiable(settings);
    _rebuildSnapshots();
    _version++;
    _scheduleReminders();
  }

  void _rebuildSnapshots() {
    final now = _clock();
    final byLoan = <String, List<LoanRepayment>>{};
    for (final r in _repayments) {
      byLoan.putIfAbsent(r.loanId, () => []).add(r);
    }
    _snapshots = List.unmodifiable([
      for (final l in _loans)
        LoanCalculator.snapshot(l, byLoan[l.id] ?? const [], now),
    ]);
    _snapshotDay = PeriodUtils.dateOnly(now);
  }

  /// Statuses depend on today's date: recompute them after midnight.
  void _refreshSnapshotsIfNewDay() {
    final today = PeriodUtils.dateOnly(_clock());
    if (_snapshotDay != null && _snapshotDay != today) _rebuildSnapshots();
  }

  /// Recomputes statuses and plans reminders again (app start or resume:
  /// the day, time zone or daylight-saving offset may have changed).
  void refreshForNow() {
    if (!isAvailable || !_hasLoaded) return;
    _rebuildSnapshots();
    _version++;
    _plannedKey = null;
    _scheduleReminders();
    _notify();
  }

  // ---------------------------------------------------------------- loans

  /// Records money lent. Throws [LoanException] for invalid input or when
  /// a household loan is requested without a household.
  ///
  /// Monthly loans are repaid at [installmentMinor] a month, or over
  /// [months] instalments (the EMI is then calculated), with interest
  /// worked out by [interestMethod].
  Future<Loan> createLoan({
    required String borrowerName,
    String borrowerPhone = '',
    String borrowerEmail = '',
    required int principalMinor,
    required DateTime lentDate,
    required LoanRepaymentType repaymentType,
    int interestRateBp = 0,
    InterestMethod interestMethod = InterestMethod.flat,
    int? installmentMinor,
    int? months,
    DateTime? firstDueDate,
    int? dueDay,
    DateTime? endDate,
    DateTime? dueDate,
    String notes = '',
    bool household = false,
  }) async {
    final repository = _requireRepository();
    final now = _clock();
    if (household && _householdId == null) {
      throw const LoanException(
        'Join or create a household to record household lending.',
      );
    }
    if (household && _uid == null) {
      throw const LoanException('Sign in to record household lending.');
    }
    final isMonthly = repaymentType == LoanRepaymentType.monthly;
    final terms = _validateTerms(
      borrowerName: borrowerName,
      borrowerPhone: borrowerPhone,
      borrowerEmail: borrowerEmail,
      principalMinor: principalMinor,
      lentDate: lentDate,
      repaymentType: repaymentType,
      interestRateBp: interestRateBp,
      installmentMinor: isMonthly && months != null ? 1 : installmentMinor,
      firstDueDate: firstDueDate,
      dueDay: dueDay,
      endDate: endDate,
      dueDate: dueDate,
      notes: notes,
      now: now,
    );
    final id = _uuid.v4();
    final schedule = LoanCalculator.buildSchedule(
      loanId: id,
      type: repaymentType,
      principalMinor: principalMinor,
      newId: _uuid.v4,
      method: interestMethod,
      interestRateBp: interestRateBp,
      installmentMinor: months == null ? installmentMinor : null,
      months: isMonthly ? months : null,
      firstDueDate: terms.firstDueDate,
      dueDay: terms.dueDay,
      dueDate: terms.dueDate,
      oneTimeInterestMinor: isMonthly || terms.dueDate == null
          ? 0
          : LoanCalculator.oneTimeInterest(
              principalMinor,
              interestRateBp,
              terms.lentDate,
              terms.dueDate!,
            ),
    );
    final emi = isMonthly ? schedule.first.expectedMinor : null;
    final loan = Loan(
      id: id,
      borrowerName: borrowerName.trim(),
      borrowerPhone: borrowerPhone.trim(),
      borrowerEmail: borrowerEmail.trim().toLowerCase(),
      principalMinor: principalMinor,
      interestRateBp: interestRateBp,
      interestMinor: _interestOf(schedule),
      interestMethod: interestMethod,
      originalInstallmentMinor: emi,
      originalTermMonths: isMonthly ? schedule.length : null,
      lentDate: terms.lentDate,
      repaymentType: repaymentType,
      installmentMinor: emi,
      firstDueDate: terms.firstDueDate,
      dueDay: terms.dueDay,
      endDate: terms.endDate,
      dueDate: terms.dueDate,
      notes: notes.trim(),
      schedule: schedule,
      householdId: household ? _householdId : null,
      createdAt: now,
      updatedAt: now,
      createdBy: _uid,
      createdByName: _userName,
      updatedBy: _uid,
    );
    // Household reminders go to the household owner until they choose
    // other members.
    final reminders = LoanReminderSettings.defaults(
      id,
      now,
      householdOwnerUid: household ? (_householdOwnerUid ?? _uid) : null,
      updatedBy: _uid,
    );
    await repository.insertLoan(loan, reminders);
    await _afterLocalChange();
    return loan;
  }

  static int _interestOf(List<LoanInstallment> schedule) =>
      schedule.fold(0, (s, i) => s + (i.interestMinor ?? 0));

  /// Saves edited details of [snapshot]'s loan. When the amount, interest
  /// or schedule terms change, instalments that already received money
  /// (extra capital included) are kept as they are and only the unpaid
  /// rest is recalculated; repayment history is never changed.
  Future<void> updateLoan(
    LoanSnapshot snapshot, {
    required String borrowerName,
    String borrowerPhone = '',
    String borrowerEmail = '',
    required int principalMinor,
    required DateTime lentDate,
    required LoanRepaymentType repaymentType,
    int interestRateBp = 0,
    InterestMethod? interestMethod,
    int? installmentMinor,
    int? months,
    DateTime? firstDueDate,
    int? dueDay,
    DateTime? endDate,
    DateTime? dueDate,
    String notes = '',
  }) async {
    final loan = snapshot.loan;
    _checkManage(loan);
    final now = _clock();
    final method = interestMethod ?? loan.interestMethod;
    final isMonthly = repaymentType == LoanRepaymentType.monthly;
    final terms = _validateTerms(
      borrowerName: borrowerName,
      borrowerPhone: borrowerPhone,
      borrowerEmail: borrowerEmail,
      principalMinor: principalMinor,
      lentDate: lentDate,
      repaymentType: repaymentType,
      interestRateBp: interestRateBp,
      installmentMinor: isMonthly && months != null ? 1 : installmentMinor,
      firstDueDate: firstDueDate,
      dueDay: dueDay,
      endDate: endDate,
      dueDate: dueDate,
      notes: notes,
      now: now,
      earliestRepayment: _earliestRepayment(loan.id),
    );
    final termsChanged =
        principalMinor != loan.principalMinor ||
        interestRateBp != loan.interestRateBp ||
        method != loan.interestMethod ||
        terms.lentDate != loan.lentDate ||
        repaymentType != loan.repaymentType ||
        (isMonthly &&
            ((months == null && installmentMinor != loan.installmentMinor) ||
                (months != null && months != loan.schedule.length) ||
                terms.firstDueDate != loan.firstDueDate ||
                terms.dueDay != loan.dueDay)) ||
        (!isMonthly && terms.dueDate != loan.dueDate);

    var schedule = loan.schedule;
    if (termsChanged) {
      if (principalMinor < snapshot.principalReceivedMinor) {
        throw LoanException(
          'The amount lent cannot be less than the capital already repaid '
          '(${_formatter.format(snapshot.principalReceivedMinor)}).',
        );
      }
      schedule = _rebuild(
        snapshot,
        type: repaymentType,
        principalMinor: principalMinor,
        method: method,
        rateBp: interestRateBp,
        installmentMinor: months == null ? installmentMinor : null,
        months: isMonthly ? months : null,
        firstDueDate: terms.firstDueDate,
        dueDay: terms.dueDay,
        dueDate: terms.dueDate,
        lentDate: terms.lentDate,
      );
      final total = principalMinor + _interestOf(schedule);
      if (total < snapshot.receivedMinor) {
        throw LoanException(
          'The total owed cannot be less than what has already been repaid '
          '(${_formatter.format(snapshot.receivedMinor)}).',
        );
      }
    }
    await _saveLoan(
      loan.copyWith(
        borrowerName: borrowerName.trim(),
        borrowerPhone: borrowerPhone.trim(),
        borrowerEmail: borrowerEmail.trim().toLowerCase(),
        principalMinor: principalMinor,
        interestRateBp: interestRateBp,
        interestMethod: method,
        interestMinor: _interestOf(schedule),
        lentDate: terms.lentDate,
        repaymentType: repaymentType,
        installmentMinor: () => isMonthly ? _emiOf(schedule, snapshot) : null,
        firstDueDate: () => terms.firstDueDate,
        dueDay: () => terms.dueDay,
        endDate: () => terms.endDate,
        dueDate: () => terms.dueDate,
        notes: notes.trim(),
        schedule: schedule,
        updatedAt: _stamp(loan, now),
        updatedBy: _uid,
      ),
    );
  }

  /// The regular EMI of [schedule]: the first instalment that has not
  /// received money yet.
  static int? _emiOf(List<LoanInstallment> schedule, LoanSnapshot snapshot) {
    final settled = {
      for (final i in snapshot.installments)
        if (i.receivedMinor > 0) i.id,
    };
    for (final i in schedule) {
      if (!settled.contains(i.id)) return i.expectedMinor;
    }
    return schedule.isEmpty ? null : schedule.last.expectedMinor;
  }

  /// Changes the unpaid part of the schedule. Monthly loans repay the
  /// capital still outstanding at a new instalment amount (or over [months]
  /// instalments) from [nextDueDate] on [dueDay]; one-time loans get a new
  /// expected date. Paid and partly paid instalments and history stay as
  /// they are.
  Future<void> reschedule(
    LoanSnapshot snapshot, {
    int? installmentMinor,
    int? months,
    DateTime? nextDueDate,
    int? dueDay,
    DateTime? dueDate,
  }) async {
    final loan = snapshot.loan;
    _checkManage(loan);
    if (snapshot.isCompleted) {
      throw const LoanException('This loan has been repaid in full.');
    }
    final now = _clock();
    final List<LoanInstallment> schedule;
    if (loan.isMonthly) {
      if (months == null) {
        final amount = installmentMinor ?? 0;
        if (amount <= 0 || amount > Money.maxMinor) {
          throw const LoanException(
            'The monthly instalment must be greater than zero.',
          );
        }
      } else {
        monthlyAmountForRest(snapshot, months);
      }
      final next = nextDueDate;
      if (next == null) {
        throw const LoanException('Choose the next repayment date.');
      }
      final day = dueDay ?? next.day;
      if (day < 1 || day > 31) {
        throw const LoanException('Choose a due day from 1 to 31.');
      }
      final settled = LoanCalculator.settledInstallments(snapshot);
      if (settled.isNotEmpty &&
          !PeriodUtils.dateOnly(next).isAfter(settled.last.dueDate)) {
        throw LoanException(
          'The next repayment must be after the last (partly) paid '
          'instalment, due ${_dateLabel(settled.last.dueDate)}.',
        );
      }
      schedule = LoanCalculator.buildSchedule(
        loanId: loan.id,
        type: LoanRepaymentType.monthly,
        principalMinor: loan.principalMinor,
        newId: _uuid.v4,
        method: loan.interestMethod,
        interestRateBp: loan.interestRateBp,
        kept: settled,
        installmentMinor: months == null ? installmentMinor : null,
        months: months,
        firstDueDate: next,
        dueDay: day,
      );
      await _saveLoan(
        loan.copyWith(
          installmentMinor: () => _emiOf(schedule, snapshot),
          interestMinor: _interestOf(schedule),
          dueDay: () => day,
          schedule: schedule,
          updatedAt: _stamp(loan, now),
          updatedBy: _uid,
        ),
      );
      return;
    }
    final date = dueDate;
    if (date == null) {
      throw const LoanException('Choose the expected repayment date.');
    }
    if (PeriodUtils.dateOnly(date).isBefore(loan.lentDate)) {
      throw const LoanException(
        'The repayment date cannot be before the money was lent.',
      );
    }
    // The agreed interest stays as it is; only the date moves.
    schedule = LoanCalculator.buildSchedule(
      loanId: loan.id,
      type: LoanRepaymentType.oneTime,
      principalMinor: loan.principalMinor,
      newId: _uuid.v4,
      dueDate: date,
      oneTimeInterestMinor: loan.interestMinor,
    );
    await _saveLoan(
      loan.copyWith(
        dueDate: () => PeriodUtils.dateOnly(date),
        schedule: schedule,
        updatedAt: _stamp(loan, now),
        updatedBy: _uid,
      ),
    );
  }

  /// The monthly amount that repays the capital not yet covered by (partly)
  /// paid instalments of [snapshot] in [months] instalments, with the
  /// loan's interest method. Throws [LoanException] for fewer than one
  /// month, more than the limit, or nothing left to schedule.
  int monthlyAmountForRest(LoanSnapshot snapshot, int months) {
    if (months < 1) throw const LoanException('Enter at least 1 month.');
    if (months > LoanLimits.maxInstallments) {
      throw const LoanException('That is more than 50 years.');
    }
    final loan = snapshot.loan;
    final settled = LoanCalculator.settledInstallments(snapshot);
    final rest =
        loan.principalMinor -
        settled.fold<int>(0, (s, i) => s + i.principalMinor);
    if (rest <= 0) {
      throw const LoanException('Nothing is left to schedule.');
    }
    final plan = LoanCalculator.planMonthly(
      principalMinor: rest,
      method: loan.interestMethod,
      rateBp: loan.interestRateBp,
      months: months,
    );
    if (plan.length != months) {
      throw const LoanException(
        'The amount left is too small to spread over that many months.',
      );
    }
    return plan.first.principalMinor + plan.first.interestMinor;
  }

  /// New schedule for changed terms. Monthly loans keep the instalments
  /// that received money and continue the series after them; one-time
  /// loans get one instalment for the whole amount (what was repaid is
  /// applied to it).
  List<LoanInstallment> _rebuild(
    LoanSnapshot snapshot, {
    required LoanRepaymentType type,
    required int principalMinor,
    required InterestMethod method,
    required int rateBp,
    int? installmentMinor,
    int? months,
    DateTime? firstDueDate,
    int? dueDay,
    DateTime? dueDate,
    required DateTime lentDate,
  }) {
    final loan = snapshot.loan;
    if (type == LoanRepaymentType.oneTime) {
      return LoanCalculator.buildSchedule(
        loanId: loan.id,
        type: type,
        principalMinor: principalMinor,
        newId: _uuid.v4,
        dueDate: dueDate,
        oneTimeInterestMinor: dueDate == null
            ? 0
            : LoanCalculator.oneTimeInterest(
                principalMinor,
                rateBp,
                lentDate,
                dueDate,
              ),
      );
    }
    final settled = loan.isMonthly
        ? LoanCalculator.settledInstallments(snapshot)
        : const <LoanInstallment>[];
    var first = firstDueDate!;
    final day = dueDay ?? first.day;
    if (settled.isNotEmpty) {
      // The unpaid rest continues the series after the last instalment
      // that received money.
      var index = 0;
      while (!LoanCalculator.monthlyDueDate(
        first,
        day,
        index,
      ).isAfter(settled.last.dueDate)) {
        index++;
      }
      first = LoanCalculator.monthlyDueDate(first, day, index);
    }
    // A number of months is the whole term: the instalments already kept
    // count towards it.
    final rest = months == null ? null : months - settled.length;
    if (rest != null && rest < 1) {
      throw LoanException(
        '${settled.length} instalment(s) have already received money; '
        'choose more months than that.',
      );
    }
    return LoanCalculator.buildSchedule(
      loanId: loan.id,
      type: type,
      principalMinor: principalMinor,
      newId: _uuid.v4,
      method: method,
      interestRateBp: rateBp,
      kept: settled,
      installmentMinor: installmentMinor,
      months: rest,
      firstDueDate: first,
      dueDay: day,
    );
  }

  Future<void> _saveLoan(Loan loan) async {
    await _requireRepository().updateLoan(loan);
    await _afterLocalChange();
  }

  /// Deletes [loan] on this device and (softly) in the cloud. Repayment
  /// records stay in the cloud's history. Its reminders are cancelled.
  Future<void> deleteLoan(Loan loan) async {
    if (!canDelete(loan)) {
      throw const LoanException(
        'Only the member who recorded this loan, or the household owner, '
        'can delete it.',
      );
    }
    await _requireRepository().deleteLoan(loan.id, _clock());
    await _afterLocalChange();
  }

  // ---------------------------------------------------------- repayments

  /// How [amountMinor] paid on [date] would be applied to [snapshot]'s
  /// loan: what goes to the current instalment (interest first), what goes
  /// straight to the capital, and the revised EMI. Nothing is recorded.
  RepaymentAllocation previewRepayment(
    LoanSnapshot snapshot, {
    required int amountMinor,
    DateTime? date,
  }) {
    final now = _clock();
    final when = date ?? now;
    final hypothetical = LoanRepayment(
      id: '_preview',
      loanId: snapshot.id,
      amountMinor: amountMinor <= 0 ? 1 : amountMinor,
      date: when,
      createdAt: now,
      updatedAt: now,
      syncState: RepaymentSyncState.synced,
    );
    return _allocate(snapshot, hypothetical, now);
  }

  RepaymentAllocation _allocate(
    LoanSnapshot before,
    LoanRepayment repayment,
    DateTime now,
  ) {
    final base = _baseLoan(before.id) ?? before.loan;
    final after = LoanCalculator.snapshot(base, [
      ...repaymentsOf(before.id),
      repayment,
    ], now);
    return LoanCalculator.allocation(
      before: before,
      after: after,
      amountMinor: repayment.amountMinor,
      now: now,
    );
  }

  Loan? _baseLoan(String id) {
    for (final l in _loans) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// The most that can be recorded now: for a monthly loan, what settles
  /// it (the current instalment plus the capital after it); for a one-time
  /// loan, what is outstanding.
  int maxRepaymentMinor(LoanSnapshot snapshot) => snapshot.loan.isMonthly
      ? snapshot.settlementMinor
      : snapshot.outstandingMinor;

  /// Records money the borrower paid back. Partial and early payments go to
  /// the current instalment. For monthly loans, whatever is paid above it
  /// reduces the capital, and the remaining EMIs are recalculated over the
  /// remaining months (see `LoanCalculator.snapshot`). How the repayment
  /// was applied is kept with it ([LoanRepayment.allocation]). Works
  /// offline.
  Future<LoanRepayment> recordRepayment(
    LoanSnapshot snapshot, {
    required int amountMinor,
    required DateTime date,
    PaymentMethod method = PaymentMethod.cash,
    String note = '',
    String? installmentId,
  }) async {
    final loan = snapshot.loan;
    _checkManage(loan);
    final now = _clock();
    if (amountMinor <= 0) {
      throw const LoanException('Amount must be greater than zero.');
    }
    if (snapshot.isCompleted) {
      throw const LoanException('This loan has been repaid in full.');
    }
    final max = maxRepaymentMinor(snapshot);
    if (amountMinor > max) {
      throw LoanException(
        loan.isMonthly
            ? 'The repayment cannot be more than the '
                  '${_formatter.format(max)} that settles the loan.'
            : 'The repayment cannot be more than the outstanding '
                  '${_formatter.format(max)}.',
      );
    }
    final day = PeriodUtils.dateOnly(date);
    if (day.isAfter(PeriodUtils.dateOnly(now))) {
      throw const LoanException('The date cannot be in the future.');
    }
    if (day.isBefore(PeriodUtils.dateOnly(loan.lentDate))) {
      throw const LoanException(
        'The repayment cannot be before the money was lent.',
      );
    }
    if (note.trim().length > LoanLimits.repaymentNoteMaxLength) {
      throw const LoanException('The note is too long.');
    }
    // Today's repayments keep the current time so they sort in the order
    // they were made.
    final when = PeriodUtils.isSameDay(date, now)
        ? now
        : DateTime(date.year, date.month, date.day, 12);
    final draft = LoanRepayment(
      id: _uuid.v4(),
      loanId: loan.id,
      amountMinor: amountMinor,
      date: when,
      method: method,
      note: note.trim(),
      installmentId: installmentId ?? snapshot.nextDue?.id,
      createdAt: now,
      updatedAt: now,
      userUid: _uid,
      userName: _userName,
    );
    final repayment = LoanRepayment(
      id: draft.id,
      loanId: draft.loanId,
      amountMinor: draft.amountMinor,
      date: draft.date,
      method: draft.method,
      note: draft.note,
      installmentId: draft.installmentId,
      createdAt: draft.createdAt,
      updatedAt: draft.updatedAt,
      userUid: draft.userUid,
      userName: draft.userName,
      allocation: _allocate(snapshot, draft, now),
    );
    await _requireRepository().addRepayment(repayment);
    await _afterLocalChange();
    return repayment;
  }

  /// Voids [repayment]: it stays in the history, marked with who voided it
  /// and why, and stops counting. Needs a connection (the cloud total is
  /// updated in the same transaction) once the repayment has been
  /// uploaded.
  Future<void> voidRepayment(
    LoanRepayment repayment, {
    String reason = '',
  }) async {
    final snapshot = snapshotById(repayment.loanId);
    if (snapshot == null) {
      throw const LoanException('This lending record no longer exists.');
    }
    _checkManage(snapshot.loan);
    if (repayment.voided) return;
    if (repayment.isRejected) {
      throw const LoanException('This repayment was not recorded.');
    }
    if (reason.trim().length > LoanLimits.voidReasonMaxLength) {
      throw const LoanException('The reason is too long.');
    }
    final now = _clock();
    final voided = LoanRepayment(
      id: repayment.id,
      loanId: repayment.loanId,
      amountMinor: repayment.amountMinor,
      date: repayment.date,
      method: repayment.method,
      note: repayment.note,
      installmentId: repayment.installmentId,
      createdAt: repayment.createdAt,
      updatedAt: now.isAfter(repayment.updatedAt)
          ? now
          : repayment.updatedAt.add(const Duration(milliseconds: 1)),
      userUid: repayment.userUid,
      userName: repayment.userName,
      voided: true,
      voidedAt: now,
      voidedBy: _uid,
      voidReason: reason.trim(),
      syncState: RepaymentSyncState.synced,
      allocation: repayment.allocation,
    );
    final cloud = _cloud;
    if (cloud != null && _uid != null) {
      if (repayment.isPending) {
        throw const LoanException(
          'This repayment has not been uploaded yet. Try again once it has '
          'synced.',
        );
      }
      final partition = snapshot.loan.isPersonal
          ? CloudPartition.personal(_uid!)
          : CloudPartition.household(_uid!, snapshot.loan.householdId!);
      final RepaymentWriteOutcome outcome;
      try {
        outcome = await cloud.voidRepayment(partition, voided);
      } on CloudUnavailableException {
        throw const LoanException(
          'Voiding a repayment needs an internet connection, so the loan '
          'total stays right on every device.',
        );
      } on CloudAccessDeniedException {
        throw const LoanException(
          'You do not have permission to do this (any more).',
        );
      }
      if (outcome == RepaymentWriteOutcome.loanMissing) {
        throw const LoanException('This lending record was deleted.');
      }
    }
    await _requireRepository().applyVoid(voided);
    await _afterLocalChange();
  }

  // ----------------------------------------------------------- reminders

  /// Saves reminder settings of [loan]. For a household loan only the
  /// household owner may do this, and only active members can be chosen.
  Future<void> saveReminderSettings(
    Loan loan, {
    required bool enabled,
    required bool paused,
    required List<int> offsets,
    List<String>? notifyUids,
  }) async {
    if (!canEditReminders(loan)) {
      throw const LoanException(
        'Only the household owner can change who gets reminders for '
        'household lending.',
      );
    }
    if (enabled && offsets.isEmpty) {
      throw const LoanException('Choose at least one reminder.');
    }
    final current = reminderSettingsOf(loan.id);
    List<String> recipients = current.notifyUids;
    if (loan.isHousehold && notifyUids != null) {
      final active = {for (final m in _members) m.uid};
      final unknown = notifyUids.where((u) => !active.contains(u));
      if (unknown.isNotEmpty) {
        throw const LoanException(
          'Only current household members can receive reminders.',
        );
      }
      recipients = notifyUids;
    }
    final now = _clock();
    final updated = current.copyWith(
      enabled: enabled,
      paused: paused,
      offsets: offsets,
      notifyUids: loan.isHousehold ? recipients : const [],
      updatedAt: now.isAfter(current.updatedAt)
          ? now
          : current.updatedAt.add(const Duration(milliseconds: 1)),
      updatedBy: _uid,
    );
    await _requireRepository().saveReminderSettings(updated);
    await _afterLocalChange();
  }

  Future<void> pauseReminders(Loan loan) {
    final s = reminderSettingsOf(loan.id);
    return saveReminderSettings(
      loan,
      enabled: s.enabled,
      paused: true,
      offsets: s.offsets,
    );
  }

  Future<void> resumeReminders(Loan loan) {
    final s = reminderSettingsOf(loan.id);
    return saveReminderSettings(
      loan,
      enabled: true,
      paused: false,
      offsets: s.offsets.isEmpty
          ? LoanLimits.defaultReminderOffsets
          : s.offsets,
    );
  }

  /// Whether this device reminds the signed-in user about [loan].
  bool remindsMe(Loan loan) {
    final uid = _uid;
    if (uid == null) return loan.isPersonal;
    return _isRecipient(loan, reminderSettingsOf(loan.id), uid);
  }

  bool _isRecipient(Loan loan, LoanReminderSettings settings, String uid) {
    if (loan.isPersonal) return true;
    if (loan.householdId != _householdId) return false;
    // Until the member list has loaded (e.g. offline at start-up) the synced
    // recipient list decides; a member who left loses the household's data
    // altogether.
    final active = {for (final m in _members) m.uid};
    return LoanReminderPlanner.isRecipient(
      loan,
      settings,
      uid,
      activeMembers: active.isEmpty ? {uid} : active,
    );
  }

  /// Runs while still signed in: the account's reminders must not appear
  /// for whoever uses the device next.
  Future<void> _beforeSignOut(String uid) async {
    _reminderTimer?.cancel();
    await _reminderQueue;
    for (final id in await _notifier.scheduledIds(
      NotificationChannel.loanReminders,
    )) {
      await _notifier.cancelScheduled(id);
    }
    _plannedKey = null;
  }

  /// Plans this device's reminders again after a short pause.
  void _scheduleReminders() {
    if (_disposed || !isAvailable) return;
    _reminderTimer?.cancel();
    _reminderTimer = Timer(reminderDebounce, () {
      _reminderQueue = _reminderQueue
          .then((_) => syncReminders())
          .catchError((Object e) => debugPrint('Loan reminders: $e'));
    });
  }

  /// Makes the scheduled reminders match the current data: reminders that
  /// no longer apply (paid, deleted, paused, recipient removed, signed out)
  /// are cancelled; the rest are scheduled under their stable IDs, so
  /// nothing is ever shown twice.
  @visibleForTesting
  Future<void> syncReminders() async {
    if (_disposed || !_hasLoaded) return;
    final uid = _uid;
    final plan = uid == null || !_notificationsAllowed
        ? const <PlannedReminder>[]
        : LoanReminderPlanner.plan(
            loans: loans,
            settings: _settings,
            uid: uid,
            recipient: (loan, settings) => _isRecipient(loan, settings, uid),
            formatter: _formatter,
            now: _clock(),
          );
    final key = Object.hashAll(plan);
    final existing = await _notifier.scheduledIds(
      NotificationChannel.loanReminders,
    );
    final wanted = {for (final p in plan) p.id};
    if (key == _plannedKey && existing.containsAll(wanted)) {
      // Nothing changed; only reminders that have been shown are gone.
      for (final id in existing.difference(wanted)) {
        await _notifier.cancelScheduled(id);
      }
      return;
    }
    for (final id in existing.difference(wanted)) {
      await _notifier.cancelScheduled(id);
    }
    for (final p in plan) {
      await _notifier.schedule(
        ScheduledNotification(
          id: p.id,
          fireAt: p.fireAt,
          notification: AppNotification(
            title: p.title,
            body: p.body,
            channel: NotificationChannel.loanReminders,
            tag: 'loan-${p.loanId}-${p.installmentId}',
            data: p.data,
          ),
        ),
      );
    }
    _plannedKey = key;
  }

  // ---------------------------------------------------------------- helpers

  DateTime? _earliestRepayment(String loanId) {
    DateTime? earliest;
    for (final r in repaymentsOf(loanId)) {
      if (!r.counts) continue;
      if (earliest == null || r.date.isBefore(earliest)) earliest = r.date;
    }
    return earliest;
  }

  ({
    DateTime lentDate,
    DateTime? firstDueDate,
    int? dueDay,
    DateTime? endDate,
    DateTime? dueDate,
  })
  _validateTerms({
    required String borrowerName,
    required String borrowerPhone,
    required String borrowerEmail,
    required int principalMinor,
    required DateTime lentDate,
    required LoanRepaymentType repaymentType,
    required int interestRateBp,
    required int? installmentMinor,
    required DateTime? firstDueDate,
    required int? dueDay,
    required DateTime? endDate,
    required DateTime? dueDate,
    required String notes,
    required DateTime now,
    DateTime? earliestRepayment,
  }) {
    final name = borrowerName.trim();
    if (name.isEmpty) {
      throw const LoanException("Enter the borrower's name.");
    }
    if (name.length > LoanLimits.nameMaxLength) {
      throw const LoanException('The name is too long.');
    }
    final phone = borrowerPhone.trim();
    if (phone.isNotEmpty &&
        (phone.length > LoanLimits.phoneMaxLength ||
            !RegExp(r'^\+?[0-9 ()\-]{5,}$').hasMatch(phone))) {
      throw const LoanException('Enter a valid phone number.');
    }
    final email = borrowerEmail.trim();
    if (email.isNotEmpty &&
        (email.length > LoanLimits.emailMaxLength ||
            !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email))) {
      throw const LoanException('Enter a valid email address.');
    }
    if (principalMinor <= 0) {
      throw const LoanException('The amount must be greater than zero.');
    }
    if (principalMinor > Money.maxMinor) {
      throw const LoanException('The amount is too large.');
    }
    if (notes.trim().length > LoanLimits.notesMaxLength) {
      throw const LoanException('The notes are too long.');
    }
    final lent = PeriodUtils.dateOnly(lentDate);
    if (lent.isAfter(PeriodUtils.dateOnly(now))) {
      throw const LoanException('The date lent cannot be in the future.');
    }
    if (earliestRepayment != null &&
        lent.isAfter(PeriodUtils.dateOnly(earliestRepayment))) {
      throw const LoanException(
        'The date lent cannot be after a recorded repayment.',
      );
    }
    if (interestRateBp < 0 || interestRateBp > LoanLimits.maxInterestRateBp) {
      throw const LoanException('Enter an interest rate from 0% to 100%.');
    }
    switch (repaymentType) {
      case LoanRepaymentType.monthly:
        final amount = installmentMinor ?? 0;
        if (amount <= 0) {
          throw const LoanException(
            'The monthly instalment must be greater than zero.',
          );
        }
        if (amount > Money.maxMinor) {
          throw const LoanException('The monthly instalment is too large.');
        }
        final first = firstDueDate;
        if (first == null) {
          throw const LoanException('Choose the first repayment date.');
        }
        final firstDay = PeriodUtils.dateOnly(first);
        if (firstDay.isBefore(lent)) {
          throw const LoanException(
            'The first repayment cannot be before the money was lent.',
          );
        }
        final day = dueDay ?? firstDay.day;
        if (day < 1 || day > 31) {
          throw const LoanException('Choose a due day from 1 to 31.');
        }
        final end = endDate == null ? null : PeriodUtils.dateOnly(endDate);
        if (end != null && end.isBefore(firstDay)) {
          throw const LoanException(
            'The final repayment date cannot be before the first one.',
          );
        }
        return (
          lentDate: lent,
          firstDueDate: firstDay,
          dueDay: day,
          endDate: end,
          dueDate: null,
        );
      case LoanRepaymentType.oneTime:
        final due = dueDate;
        if (due == null) {
          throw const LoanException('Choose the expected repayment date.');
        }
        final dueDay = PeriodUtils.dateOnly(due);
        if (dueDay.isBefore(lent)) {
          throw const LoanException(
            'The repayment date cannot be before the money was lent.',
          );
        }
        return (
          lentDate: lent,
          firstDueDate: null,
          dueDay: null,
          endDate: null,
          dueDate: dueDay,
        );
    }
  }

  void _checkManage(Loan loan) {
    if (!canManage(loan)) {
      throw const LoanException(
        'You are no longer a member of the household this loan belongs to.',
      );
    }
  }

  LoanRepository _requireRepository() {
    final repository = _repository;
    if (repository == null) {
      throw const LoanException('Lending is not available.');
    }
    return repository;
  }

  /// A change time strictly after [loan]'s last one, so the newest edit
  /// always wins the last-writer-wins merge, even with clock skew.
  static DateTime _stamp(Loan loan, DateTime now) => now.isAfter(loan.updatedAt)
      ? now
      : loan.updatedAt.add(const Duration(milliseconds: 1));

  static String _dateLabel(DateTime d) => '${d.day}/${d.month}/${d.year}';

  Future<void> _afterLocalChange() async {
    final repository = _repository!;
    _apply(
      await repository.getLoans(),
      await repository.getRepayments(),
      await repository.getReminderSettings(),
    );
    _hasLoaded = true;
    _error = null;
    _localChangeVersion++;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reminderTimer?.cancel();
    _auth?.removeSignOutHook(_beforeSignOut);
    super.dispose();
  }
}
