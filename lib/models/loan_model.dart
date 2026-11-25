import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:money_mate/models/transaction_model.dart';

/// A lending change the user is not allowed to make, with a message that
/// can be shown as is.
class LoanException implements Exception {
  const LoanException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How the borrower pays the money back.
enum LoanRepaymentType {
  /// A fixed amount every month (EMI style) until everything is repaid.
  monthly('Monthly (EMI)', Icons.event_repeat_rounded),

  /// Everything by one expected date; partial payments are still allowed.
  oneTime('One-time', Icons.event_available_rounded);

  const LoanRepaymentType(this.label, this.icon);

  final String label;
  final IconData icon;

  static LoanRepaymentType fromName(String? value) =>
      LoanRepaymentType.values.firstWhere(
        (t) => t.name == value,
        orElse: () => LoanRepaymentType.oneTime,
      );
}

/// How interest is worked out. It is chosen when the loan is recorded and
/// never changed silently.
enum InterestMethod {
  /// Simple interest on the amount (still) lent, spread evenly over the
  /// instalments.
  flat('Flat'),

  /// Interest each month on the principal still outstanding; instalments
  /// follow the standard EMI formula `P × r × (1 + r)^n / ((1 + r)^n − 1)`.
  reducing('Reducing balance');

  const InterestMethod(this.label);

  final String label;

  /// Loans recorded before the choice existed are flat.
  static InterestMethod fromName(Object? value) =>
      value == InterestMethod.reducing.name
      ? InterestMethod.reducing
      : InterestMethod.flat;
}

/// Where a loan stands, derived from its schedule and repayments.
enum LoanStatus {
  active('Active'),
  overdue('Overdue'),
  completed('Completed');

  const LoanStatus(this.label);

  final String label;
}

/// Where one instalment stands, derived from the repayments.
enum InstallmentStatus {
  upcoming('Upcoming'),

  /// Due within [LoanLimits.dueSoonDays] days (today included).
  due('Due'),
  partiallyPaid('Partially paid'),
  paid('Paid'),
  overdue('Overdue');

  const InstallmentStatus(this.label);

  final String label;

  bool get isOpen => this != InstallmentStatus.paid;
}

/// Limits shared by the forms, the database and Firestore rules.
class LoanLimits {
  LoanLimits._();

  static const int nameMaxLength = 80;
  static const int phoneMaxLength = 32;
  static const int emailMaxLength = 254;
  static const int notesMaxLength = 500;
  static const int repaymentNoteMaxLength = 200;
  static const int voidReasonMaxLength = 200;

  /// Interest is stored in basis points (1/100 of a percent): 1250 = 12.5%.
  static const int maxInterestRateBp = 10000;

  /// Monthly schedules longer than this are refused (50 years).
  static const int maxInstallments = 600;

  /// An instalment is "Due" from this many days before its due date.
  static const int dueSoonDays = 3;

  /// Reminder offsets (days relative to the due date) people can choose.
  static const List<int> reminderOffsetChoices = [-7, -3, -1, 0, 1, 3, 7, 14];

  /// The default reminder schedule.
  static const List<int> defaultReminderOffsets = [-3, 0, 1, 3, 7];
}

/// One scheduled instalment of a loan: what is expected and when.
///
/// A one-time loan has a single instalment for the whole amount. What has
/// been received towards an instalment is never stored: repayments are
/// applied to instalments oldest first when the loan is read (see
/// `LoanCalculator.snapshot`).
@immutable
class LoanInstallment {
  const LoanInstallment({
    required this.id,
    required this.loanId,
    required this.number,
    required this.dueDate,
    required this.expectedMinor,
    this.interestMinor,
  }) : assert(expectedMinor > 0, 'An instalment must expect money');

  final String id;
  final String loanId;

  /// 1-based position in the schedule.
  final int number;
  final DateTime dueDate;
  final int expectedMinor;

  /// The interest part of [expectedMinor]; null for instalments recorded
  /// before the split was stored (it is then worked out in proportion).
  final int? interestMinor;

  /// The principal (capital) part of [expectedMinor].
  int get principalMinor => expectedMinor - (interestMinor ?? 0);

  LoanInstallment copyWith({
    String? id,
    int? number,
    DateTime? dueDate,
    int? expectedMinor,
    int? interestMinor,
  }) => LoanInstallment(
    id: id ?? this.id,
    loanId: loanId,
    number: number ?? this.number,
    dueDate: dueDate ?? this.dueDate,
    expectedMinor: expectedMinor ?? this.expectedMinor,
    interestMinor: interestMinor ?? this.interestMinor,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'loan_id': loanId,
    'number': number,
    'due_date': dueDate.millisecondsSinceEpoch,
    'expected_minor': expectedMinor,
    'interest_minor': interestMinor,
  };

  factory LoanInstallment.fromMap(Map<String, Object?> map) {
    final expected = map['expected_minor'];
    if (expected is! int || expected <= 0) {
      throw const FormatException('Loan instalment: bad amount');
    }
    return LoanInstallment(
      id: map['id']! as String,
      loanId: map['loan_id']! as String,
      number: map['number']! as int,
      dueDate: DateTime.fromMillisecondsSinceEpoch(map['due_date']! as int),
      expectedMinor: expected,
      interestMinor: _interestOf(map['interest_minor'], expected),
    );
  }

  static int? _interestOf(Object? value, int expected) =>
      value is int && value >= 0 && value <= expected ? value : null;

  Map<String, Object?> toCloudMap() => {
    'id': id,
    'number': number,
    'dueDate': dueDate.millisecondsSinceEpoch,
    'expectedMinor': expectedMinor,
    'interestMinor': ?interestMinor,
  };

  static LoanInstallment? fromCloudMap(String loanId, Object? data) {
    if (data is! Map) return null;
    final id = data['id'];
    final number = data['number'];
    final due = data['dueDate'];
    final expected = data['expectedMinor'];
    if (id is! String || id.isEmpty || number is! int || due is! int) {
      return null;
    }
    if (expected is! int || expected <= 0) return null;
    return LoanInstallment(
      id: id,
      loanId: loanId,
      number: number,
      dueDate: DateTime.fromMillisecondsSinceEpoch(due),
      expectedMinor: expected,
      interestMinor: _interestOf(data['interestMinor'], expected),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LoanInstallment &&
      other.id == id &&
      other.loanId == loanId &&
      other.number == number &&
      other.dueDate == dueDate &&
      other.expectedMinor == expectedMinor &&
      other.interestMinor == interestMinor;

  @override
  int get hashCode =>
      Object.hash(id, loanId, number, dueDate, expectedMinor, interestMinor);
}

/// Money lent to someone: who, how much, when, and how it is paid back.
///
/// Lending is a transfer, not an expense: lending lowers the available
/// balance of its scope (personal, or the household's) and repaid
/// principal raises it again. Only the interest part of repayments counts
/// as income, and only inside the lending figures; none of it is ever a
/// transaction, so reports and budgets are unaffected.
///
/// [interestMinor] is the total interest agreed (flat, from
/// [interestRateBp]); the borrower owes [totalOwedMinor]. Each repayment is
/// split between principal and interest in that proportion.
@immutable
class Loan {
  const Loan({
    required this.id,
    required this.borrowerName,
    this.borrowerPhone = '',
    this.borrowerEmail = '',
    required this.principalMinor,
    this.interestRateBp = 0,
    this.interestMinor = 0,
    this.interestMethod = InterestMethod.flat,
    this.originalInstallmentMinor,
    this.originalTermMonths,
    required this.lentDate,
    required this.repaymentType,
    this.installmentMinor,
    this.firstDueDate,
    this.dueDay,
    this.endDate,
    this.dueDate,
    this.notes = '',
    this.schedule = const [],
    this.householdId,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy,
    this.createdByName,
    this.updatedBy,
    this.receivedMinor = 0,
    this.pendingRepayments = 0,
  }) : assert(principalMinor > 0, 'Amount must be greater than zero'),
       assert(interestMinor >= 0, 'Interest cannot be negative');

  final String id;
  final String borrowerName;
  final String borrowerPhone;
  final String borrowerEmail;

  /// Amount lent.
  final int principalMinor;

  /// Interest rate per year, in basis points (0 = no interest).
  final int interestRateBp;

  /// Total interest of the schedule (agreed up front; lower after extra
  /// capital repayments).
  final int interestMinor;
  final InterestMethod interestMethod;

  /// Monthly loans: the EMI and number of months first agreed. Kept for the
  /// record when extra repayments revise the EMI.
  final int? originalInstallmentMinor;
  final int? originalTermMonths;
  final DateTime lentDate;
  final LoanRepaymentType repaymentType;

  /// Monthly loans: amount of each instalment.
  final int? installmentMinor;

  /// Monthly loans: due date of the first instalment.
  final DateTime? firstDueDate;

  /// Monthly loans: day of the month instalments fall due (1–31; shorter
  /// months use their last day).
  final int? dueDay;

  /// Monthly loans: when the borrower expects to finish (informational).
  final DateTime? endDate;

  /// One-time loans: expected repayment date.
  final DateTime? dueDate;
  final String notes;

  /// Instalments, in order.
  final List<LoanInstallment> schedule;

  /// Household of a household loan; null for a personal one.
  final String? householdId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdBy;
  final String? createdByName;
  final String? updatedBy;

  /// Repaid so far (derived from the repayments; not stored locally).
  final int receivedMinor;

  /// Repayments recorded on this device and not yet in the cloud (derived).
  final int pendingRepayments;

  bool get isHousehold => householdId != null;
  bool get isPersonal => householdId == null;
  bool get isMonthly => repaymentType == LoanRepaymentType.monthly;

  int get totalOwedMinor => principalMinor + interestMinor;

  /// Still to be repaid (never negative).
  int get outstandingMinor =>
      receivedMinor >= totalOwedMinor ? 0 : totalOwedMinor - receivedMinor;

  bool get isFullyRepaid => receivedMinor >= totalOwedMinor;

  /// e.g. "12.5%" (no trailing zeros).
  String get interestRateLabel => formatRateBp(interestRateBp);

  Loan copyWith({
    String? borrowerName,
    String? borrowerPhone,
    String? borrowerEmail,
    int? principalMinor,
    int? interestRateBp,
    int? interestMinor,
    InterestMethod? interestMethod,
    DateTime? lentDate,
    LoanRepaymentType? repaymentType,
    int? Function()? installmentMinor,
    DateTime? Function()? firstDueDate,
    int? Function()? dueDay,
    DateTime? Function()? endDate,
    DateTime? Function()? dueDate,
    String? notes,
    List<LoanInstallment>? schedule,
    DateTime? updatedAt,
    String? updatedBy,
    int? receivedMinor,
    int? pendingRepayments,
  }) => Loan(
    id: id,
    borrowerName: borrowerName ?? this.borrowerName,
    borrowerPhone: borrowerPhone ?? this.borrowerPhone,
    borrowerEmail: borrowerEmail ?? this.borrowerEmail,
    principalMinor: principalMinor ?? this.principalMinor,
    interestRateBp: interestRateBp ?? this.interestRateBp,
    interestMinor: interestMinor ?? this.interestMinor,
    interestMethod: interestMethod ?? this.interestMethod,
    originalInstallmentMinor: originalInstallmentMinor,
    originalTermMonths: originalTermMonths,
    lentDate: lentDate ?? this.lentDate,
    repaymentType: repaymentType ?? this.repaymentType,
    installmentMinor: installmentMinor != null
        ? installmentMinor()
        : this.installmentMinor,
    firstDueDate: firstDueDate != null ? firstDueDate() : this.firstDueDate,
    dueDay: dueDay != null ? dueDay() : this.dueDay,
    endDate: endDate != null ? endDate() : this.endDate,
    dueDate: dueDate != null ? dueDate() : this.dueDate,
    notes: notes ?? this.notes,
    schedule: schedule ?? this.schedule,
    householdId: householdId,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy,
    createdByName: createdByName,
    updatedBy: updatedBy ?? this.updatedBy,
    receivedMinor: receivedMinor ?? this.receivedMinor,
    pendingRepayments: pendingRepayments ?? this.pendingRepayments,
  );

  static DateTime? _date(Object? value) =>
      value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;

  /// Stored columns of the `loans` table (schedule and derived fields
  /// excluded).
  Map<String, Object?> toMap() => {
    'id': id,
    'household_id': householdId ?? '',
    'borrower_name': borrowerName,
    'borrower_phone': borrowerPhone,
    'borrower_email': borrowerEmail,
    'principal_minor': principalMinor,
    'interest_rate_bp': interestRateBp,
    'interest_minor': interestMinor,
    'interest_method': interestMethod.name,
    'original_installment_minor': originalInstallmentMinor,
    'original_term_months': originalTermMonths,
    'lent_date': lentDate.millisecondsSinceEpoch,
    'repayment_type': repaymentType.name,
    'installment_minor': installmentMinor,
    'first_due_date': firstDueDate?.millisecondsSinceEpoch,
    'due_day': dueDay,
    'end_date': endDate?.millisecondsSinceEpoch,
    'due_date': dueDate?.millisecondsSinceEpoch,
    'notes': notes,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'created_by': createdBy,
    'created_by_name': createdByName,
    'updated_by': updatedBy,
  };

  factory Loan.fromMap(
    Map<String, Object?> map, {
    List<LoanInstallment> schedule = const [],
  }) {
    final principal = map['principal_minor'];
    final name = map['borrower_name'];
    if (principal is! int || principal <= 0) {
      throw const FormatException('Loan: bad amount');
    }
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Loan: bad borrower');
    }
    final household = map['household_id'];
    return Loan(
      id: map['id']! as String,
      borrowerName: name,
      borrowerPhone: (map['borrower_phone'] as String?) ?? '',
      borrowerEmail: (map['borrower_email'] as String?) ?? '',
      principalMinor: principal,
      interestRateBp: (map['interest_rate_bp'] as int?) ?? 0,
      interestMinor: (map['interest_minor'] as int?) ?? 0,
      interestMethod: InterestMethod.fromName(map['interest_method']),
      originalInstallmentMinor: map['original_installment_minor'] as int?,
      originalTermMonths: map['original_term_months'] as int?,
      lentDate: DateTime.fromMillisecondsSinceEpoch(map['lent_date']! as int),
      repaymentType: LoanRepaymentType.fromName(
        map['repayment_type'] as String?,
      ),
      installmentMinor: map['installment_minor'] as int?,
      firstDueDate: _date(map['first_due_date']),
      dueDay: map['due_day'] as int?,
      endDate: _date(map['end_date']),
      dueDate: _date(map['due_date']),
      notes: (map['notes'] as String?) ?? '',
      schedule: schedule,
      householdId: household is String && household.isNotEmpty
          ? household
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
      createdBy: map['created_by'] as String?,
      createdByName: map['created_by_name'] as String?,
      updatedBy: map['updated_by'] as String?,
      receivedMinor: (map['received_minor'] as int?) ?? 0,
      pendingRepayments: (map['pending_repayments'] as int?) ?? 0,
    );
  }

  /// Fields of the Firestore document (id / updatedAt / deleted are added by
  /// the store). The cloud running total (`receivedMinor`) is never part of
  /// it: only repayment transactions change that.
  Map<String, Object?> toCloudMap() => {
    'borrowerName': borrowerName,
    'borrowerPhone': borrowerPhone,
    'borrowerEmail': borrowerEmail,
    'principalMinor': principalMinor,
    'interestRateBp': interestRateBp,
    'interestMinor': interestMinor,
    'interestMethod': interestMethod.name,
    'originalInstallmentMinor': originalInstallmentMinor,
    'originalTermMonths': originalTermMonths,
    'totalOwedMinor': totalOwedMinor,
    'lentDate': lentDate.millisecondsSinceEpoch,
    'repaymentType': repaymentType.name,
    'installmentMinor': installmentMinor,
    'firstDueDate': firstDueDate?.millisecondsSinceEpoch,
    'dueDay': dueDay,
    'endDate': endDate?.millisecondsSinceEpoch,
    'dueDate': dueDate?.millisecondsSinceEpoch,
    'notes': notes,
    'schedule': [for (final i in schedule) i.toCloudMap()],
    'createdAt': createdAt.millisecondsSinceEpoch,
    'householdId': ?householdId,
    'createdBy': ?createdBy,
    'createdByName': ?createdByName,
    'updatedBy': ?updatedBy,
  };

  /// Parses a Firestore document; null when it is not a valid loan. The
  /// household comes from where the document was read.
  static Loan? fromCloudMap(
    String id,
    Map<String, Object?> data,
    int updatedAtMs, {
    String? householdId,
  }) {
    final name = data['borrowerName'];
    final principal = data['principalMinor'];
    final lent = data['lentDate'];
    final createdAt = data['createdAt'];
    if (name is! String || name.trim().isEmpty) return null;
    if (principal is! int || principal <= 0) return null;
    if (lent is! int || createdAt is! int) return null;
    final interest = data['interestMinor'];
    final rawSchedule = data['schedule'];
    final schedule = <LoanInstallment>[
      if (rawSchedule is List)
        for (final item in rawSchedule)
          if (LoanInstallment.fromCloudMap(id, item) case final i?) i,
    ]..sort((a, b) => a.number.compareTo(b.number));
    return Loan(
      id: id,
      borrowerName: name,
      borrowerPhone: (data['borrowerPhone'] as String?) ?? '',
      borrowerEmail: (data['borrowerEmail'] as String?) ?? '',
      principalMinor: principal,
      interestRateBp: (data['interestRateBp'] as int?) ?? 0,
      interestMinor: interest is int && interest >= 0 ? interest : 0,
      interestMethod: InterestMethod.fromName(data['interestMethod']),
      originalInstallmentMinor: data['originalInstallmentMinor'] as int?,
      originalTermMonths: data['originalTermMonths'] as int?,
      lentDate: DateTime.fromMillisecondsSinceEpoch(lent),
      repaymentType: LoanRepaymentType.fromName(
        data['repaymentType'] as String?,
      ),
      installmentMinor: data['installmentMinor'] as int?,
      firstDueDate: _date(data['firstDueDate']),
      dueDay: data['dueDay'] as int?,
      endDate: _date(data['endDate']),
      dueDate: _date(data['dueDate']),
      notes: (data['notes'] as String?) ?? '',
      schedule: schedule,
      householdId: householdId,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
      createdBy: data['createdBy'] as String?,
      createdByName: data['createdByName'] as String?,
      updatedBy: data['updatedBy'] as String?,
    );
  }
}

/// Upload state of a repayment recorded on this device.
enum RepaymentSyncState {
  pending,
  synced,

  /// The cloud refused it, because together with repayments recorded on
  /// other devices it would exceed what is owed. It stays in the history
  /// (marked) but does not count.
  rejected;

  static RepaymentSyncState fromName(Object? value) =>
      RepaymentSyncState.values.firstWhere(
        (s) => s.name == value,
        orElse: () => RepaymentSyncState.pending,
      );
}

/// How one repayment was applied, worked out when it was recorded and kept
/// with it for the record. It never changes afterwards, even when later
/// repayments revise the schedule again.
@immutable
class RepaymentAllocation {
  const RepaymentAllocation({
    this.installmentNumber,
    this.scheduledEmiMinor = 0,
    this.appliedToInstallmentMinor = 0,
    this.interestPortionMinor = 0,
    this.principalPortionMinor = 0,
    this.extraPrincipalMinor = 0,
    required this.principalBeforeMinor,
    required this.principalAfterMinor,
    this.previousEmiMinor,
    this.revisedEmiMinor,
    required this.remainingInstallments,
    required this.recalculatedAt,
    this.effectiveFrom,
  });

  /// The instalment the scheduled part went to.
  final int? installmentNumber;

  /// That instalment's amount when the repayment was recorded.
  final int scheduledEmiMinor;

  /// Paid towards that instalment.
  final int appliedToInstallmentMinor;
  final int interestPortionMinor;
  final int principalPortionMinor;

  /// Paid above the instalment, straight off the capital.
  final int extraPrincipalMinor;
  final int principalBeforeMinor;
  final int principalAfterMinor;

  /// The regular EMI before and after (null without later instalments).
  final int? previousEmiMinor;
  final int? revisedEmiMinor;
  final int remainingInstallments;
  final DateTime recalculatedAt;

  /// Due date of the first instalment with the revised EMI.
  final DateTime? effectiveFrom;

  bool get revisedEmi =>
      extraPrincipalMinor > 0 && revisedEmiMinor != previousEmiMinor;

  Map<String, Object?> toJson() => {
    'installmentNumber': installmentNumber,
    'scheduledEmiMinor': scheduledEmiMinor,
    'appliedToInstallmentMinor': appliedToInstallmentMinor,
    'interestPortionMinor': interestPortionMinor,
    'principalPortionMinor': principalPortionMinor,
    'extraPrincipalMinor': extraPrincipalMinor,
    'principalBeforeMinor': principalBeforeMinor,
    'principalAfterMinor': principalAfterMinor,
    'previousEmiMinor': previousEmiMinor,
    'revisedEmiMinor': revisedEmiMinor,
    'remainingInstallments': remainingInstallments,
    'recalculatedAt': recalculatedAt.millisecondsSinceEpoch,
    'effectiveFrom': effectiveFrom?.millisecondsSinceEpoch,
  };

  static RepaymentAllocation? fromJson(Object? raw) {
    Object? data = raw;
    if (data is String) {
      try {
        data = jsonDecode(data);
      } on FormatException {
        return null;
      }
    }
    if (data is! Map) return null;
    int i(String key) => (data as Map)[key] is int ? data[key] as int : 0;
    int? n(String key) => (data as Map)[key] is int ? data[key] as int : null;
    final at = n('recalculatedAt');
    final from = n('effectiveFrom');
    if (at == null) return null;
    return RepaymentAllocation(
      installmentNumber: n('installmentNumber'),
      scheduledEmiMinor: i('scheduledEmiMinor'),
      appliedToInstallmentMinor: i('appliedToInstallmentMinor'),
      interestPortionMinor: i('interestPortionMinor'),
      principalPortionMinor: i('principalPortionMinor'),
      extraPrincipalMinor: i('extraPrincipalMinor'),
      principalBeforeMinor: i('principalBeforeMinor'),
      principalAfterMinor: i('principalAfterMinor'),
      previousEmiMinor: n('previousEmiMinor'),
      revisedEmiMinor: n('revisedEmiMinor'),
      remainingInstallments: i('remainingInstallments'),
      recalculatedAt: DateTime.fromMillisecondsSinceEpoch(at),
      effectiveFrom: from == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(from),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RepaymentAllocation &&
      jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Money the borrower paid back.
///
/// Repayments are permanent records: they are never edited or deleted. A
/// mistake is corrected by voiding the repayment, which keeps it in the
/// history (with who voided it and why) but stops it counting.
@immutable
class LoanRepayment {
  const LoanRepayment({
    required this.id,
    required this.loanId,
    required this.amountMinor,
    required this.date,
    this.method = PaymentMethod.cash,
    this.note = '',
    this.installmentId,
    required this.createdAt,
    required this.updatedAt,
    this.userUid,
    this.userName,
    this.voided = false,
    this.voidedAt,
    this.voidedBy,
    this.voidReason = '',
    this.syncState = RepaymentSyncState.pending,
    this.allocation,
  }) : assert(amountMinor > 0, 'Amount must be greater than zero');

  final String id;
  final String loanId;
  final int amountMinor;
  final DateTime date;
  final PaymentMethod method;
  final String note;

  /// The instalment it was recorded from, if any (a reference for the
  /// history; amounts are always applied oldest instalment first).
  final String? installmentId;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Who recorded it.
  final String? userUid;
  final String? userName;
  final bool voided;
  final DateTime? voidedAt;
  final String? voidedBy;
  final String voidReason;
  final RepaymentSyncState syncState;

  /// How it was applied when recorded (null for older repayments).
  final RepaymentAllocation? allocation;

  bool get isPending => syncState == RepaymentSyncState.pending;
  bool get isRejected => syncState == RepaymentSyncState.rejected;

  /// Counts towards what was repaid.
  bool get counts => !voided && !isRejected;

  Map<String, Object?> toMap() => {
    'id': id,
    'loan_id': loanId,
    'amount_minor': amountMinor,
    'date': date.millisecondsSinceEpoch,
    'method': method.name,
    'note': note,
    'installment_id': installmentId,
    'created_at': createdAt.millisecondsSinceEpoch,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'user_uid': userUid,
    'user_name': userName,
    'voided': voided ? 1 : 0,
    'voided_at': voidedAt?.millisecondsSinceEpoch,
    'voided_by': voidedBy,
    'void_reason': voidReason,
    'allocation': allocation == null ? null : jsonEncode(allocation!.toJson()),
  };

  factory LoanRepayment.fromMap(Map<String, Object?> map) {
    final amount = map['amount_minor'];
    if (amount is! int || amount <= 0) {
      throw const FormatException('Loan repayment: bad amount');
    }
    return LoanRepayment(
      id: map['id']! as String,
      loanId: map['loan_id']! as String,
      amountMinor: amount,
      date: DateTime.fromMillisecondsSinceEpoch(map['date']! as int),
      method: PaymentMethod.fromName((map['method'] as String?) ?? 'cash'),
      note: (map['note'] as String?) ?? '',
      installmentId: map['installment_id'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at']! as int),
      userUid: map['user_uid'] as String?,
      userName: map['user_name'] as String?,
      voided: map['voided'] == 1,
      voidedAt: map['voided_at'] is int
          ? DateTime.fromMillisecondsSinceEpoch(map['voided_at']! as int)
          : null,
      voidedBy: map['voided_by'] as String?,
      voidReason: (map['void_reason'] as String?) ?? '',
      syncState: RepaymentSyncState.fromName(map['sync_status']),
      allocation: RepaymentAllocation.fromJson(map['allocation']),
    );
  }

  Map<String, Object?> toCloudMap() => {
    'loanId': loanId,
    'amountMinor': amountMinor,
    'date': date.millisecondsSinceEpoch,
    'method': method.name,
    'note': note,
    'installmentId': installmentId,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'userUid': ?userUid,
    'userName': ?userName,
    'voided': voided,
    'voidedAt': voidedAt?.millisecondsSinceEpoch,
    'voidedBy': voidedBy,
    'voidReason': voidReason,
    if (allocation != null) 'allocation': allocation!.toJson(),
  };

  static LoanRepayment? fromCloudMap(
    String id,
    Map<String, Object?> data,
    int updatedAtMs,
  ) {
    final loanId = data['loanId'];
    final amount = data['amountMinor'];
    final date = data['date'];
    final createdAt = data['createdAt'];
    if (loanId is! String || loanId.isEmpty) return null;
    if (amount is! int || amount <= 0 || date is! int || createdAt is! int) {
      return null;
    }
    final voidedAt = data['voidedAt'];
    return LoanRepayment(
      id: id,
      loanId: loanId,
      amountMinor: amount,
      date: DateTime.fromMillisecondsSinceEpoch(date),
      method: PaymentMethod.fromName((data['method'] as String?) ?? 'cash'),
      note: (data['note'] as String?) ?? '',
      installmentId: data['installmentId'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
      userUid: data['userUid'] as String?,
      userName: data['userName'] as String?,
      voided: data['voided'] == true,
      voidedAt: voidedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(voidedAt)
          : null,
      voidedBy: data['voidedBy'] as String?,
      voidReason: (data['voidReason'] as String?) ?? '',
      syncState: RepaymentSyncState.synced,
      allocation: RepaymentAllocation.fromJson(data['allocation']),
    );
  }
}

/// When repayment reminders are shown for one loan, and (household loans)
/// to whom.
///
/// For a household loan only the household owner (its admin) changes these
/// settings; Firestore rules enforce it. [notifyUids] lists the members
/// whose devices show the reminders. Nobody is added automatically, so a
/// member who joins later gets no reminders until the owner selects them.
/// For a personal loan [notifyUids] is unused: the owner is always the one
/// reminded.
@immutable
class LoanReminderSettings {
  const LoanReminderSettings({
    required this.loanId,
    this.enabled = true,
    this.paused = false,
    this.offsets = LoanLimits.defaultReminderOffsets,
    this.notifyUids = const [],
    required this.updatedAt,
    this.updatedBy,
  });

  /// Defaults for a new loan. A household loan created by its owner
  /// reminds the owner; one created by another member also reminds the
  /// owner, who can then choose others.
  factory LoanReminderSettings.defaults(
    String loanId,
    DateTime now, {
    String? householdOwnerUid,
    String? updatedBy,
  }) => LoanReminderSettings(
    loanId: loanId,
    notifyUids: householdOwnerUid == null ? const [] : [householdOwnerUid],
    updatedAt: now,
    updatedBy: updatedBy,
  );

  final String loanId;
  final bool enabled;
  final bool paused;

  /// Days relative to the due date (negative = before), sorted.
  final List<int> offsets;
  final List<String> notifyUids;
  final DateTime updatedAt;
  final String? updatedBy;

  /// Reminders are scheduled at all.
  bool get isActive => enabled && !paused && offsets.isNotEmpty;

  LoanReminderSettings copyWith({
    bool? enabled,
    bool? paused,
    List<int>? offsets,
    List<String>? notifyUids,
    DateTime? updatedAt,
    String? updatedBy,
  }) => LoanReminderSettings(
    loanId: loanId,
    enabled: enabled ?? this.enabled,
    paused: paused ?? this.paused,
    offsets: offsets == null ? this.offsets : normalizeOffsets(offsets),
    notifyUids: notifyUids == null
        ? this.notifyUids
        : (notifyUids.toSet().toList()..sort()),
    updatedAt: updatedAt ?? this.updatedAt,
    updatedBy: updatedBy ?? this.updatedBy,
  );

  /// Unique, allowed offsets in order.
  static List<int> normalizeOffsets(Iterable<int> offsets) =>
      offsets.where((o) => o >= -30 && o <= 60).toSet().toList()..sort();

  Map<String, Object?> toMap() => {
    'loan_id': loanId,
    'enabled': enabled ? 1 : 0,
    'paused': paused ? 1 : 0,
    'offsets': jsonEncode(offsets),
    'notify_uids': jsonEncode(notifyUids),
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'updated_by': updatedBy,
  };

  static List<T> _decodeList<T>(Object? raw) {
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<T>().toList() : const [];
    } on FormatException {
      return const [];
    }
  }

  factory LoanReminderSettings.fromMap(Map<String, Object?> map) =>
      LoanReminderSettings(
        loanId: map['loan_id']! as String,
        enabled: map['enabled'] != 0,
        paused: map['paused'] == 1,
        offsets: normalizeOffsets(_decodeList<int>(map['offsets'])),
        notifyUids: _decodeList<String>(map['notify_uids']),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          map['updated_at']! as int,
        ),
        updatedBy: map['updated_by'] as String?,
      );

  Map<String, Object?> toCloudMap() => {
    'loanId': loanId,
    'enabled': enabled,
    'paused': paused,
    'offsets': offsets,
    'notifyUids': notifyUids,
    'updatedBy': ?updatedBy,
  };

  static LoanReminderSettings? fromCloudMap(
    String loanId,
    Map<String, Object?> data,
    int updatedAtMs,
  ) {
    final offsets = data['offsets'];
    final uids = data['notifyUids'];
    if (data['enabled'] is! bool || offsets is! List) return null;
    return LoanReminderSettings(
      loanId: loanId,
      enabled: data['enabled'] == true,
      paused: data['paused'] == true,
      offsets: normalizeOffsets(offsets.whereType<int>()),
      notifyUids: uids is List ? uids.whereType<String>().toList() : const [],
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
      updatedBy: data['updatedBy'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LoanReminderSettings &&
      other.loanId == loanId &&
      other.enabled == enabled &&
      other.paused == paused &&
      _listEquals(other.offsets, offsets) &&
      _listEquals(other.notifyUids, notifyUids) &&
      other.updatedAt == updatedAt &&
      other.updatedBy == updatedBy;

  @override
  int get hashCode => Object.hash(
    loanId,
    enabled,
    paused,
    Object.hashAll(offsets),
    Object.hashAll(notifyUids),
    updatedAt,
    updatedBy,
  );
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// e.g. 1250 → "12.5%", 0 → "0%".
String formatRateBp(int bp) {
  final whole = bp ~/ 100;
  final fraction = bp % 100;
  if (fraction == 0) return '$whole%';
  final digits = fraction
      .toString()
      .padLeft(2, '0')
      .replaceAll(RegExp(r'0+$'), '');
  return '$whole.$digits%';
}

/// Parses "12.5" / "12,5" / "0" into basis points; null when invalid.
int? parseRateBp(String input) {
  final text = input.trim().replaceAll(',', '.').replaceAll('%', '');
  if (text.isEmpty) return 0;
  final match = RegExp(r'^(\d{1,3})(?:\.(\d{0,2}))?$').firstMatch(text);
  if (match == null) return null;
  final whole = int.parse(match.group(1)!);
  final fraction = (match.group(2) ?? '').padRight(2, '0');
  return whole * 100 + int.parse(fraction);
}

/// One instalment with what has been received towards it.
@immutable
class InstallmentView {
  const InstallmentView({
    required this.installment,
    required this.receivedMinor,
    required this.status,
    this.repaymentIds = const [],
    this.interestMinor = 0,
    this.extraPrincipalMinor = 0,
  });

  final LoanInstallment installment;
  final int receivedMinor;
  final InstallmentStatus status;

  /// The interest part of this instalment (worked out for older records).
  final int interestMinor;

  /// Extra capital repaid together with this instalment (included in
  /// [expectedMinor] and [receivedMinor]).
  final int extraPrincipalMinor;

  /// The principal part, extra capital included.
  int get principalMinor => expectedMinor - interestMinor;

  /// Received towards interest (interest is paid first within an
  /// instalment).
  int get interestPaidMinor =>
      receivedMinor < interestMinor ? receivedMinor : interestMinor;
  int get principalPaidMinor => receivedMinor - interestPaidMinor;

  /// What this instalment asked for before any extra capital.
  int get scheduledMinor => expectedMinor - extraPrincipalMinor;

  /// Repayments that went (partly) towards this instalment, oldest first.
  final List<String> repaymentIds;

  int get remainingMinor => installment.expectedMinor - receivedMinor;
  String get id => installment.id;
  DateTime get dueDate => installment.dueDate;
  int get number => installment.number;
  int get expectedMinor => installment.expectedMinor;
  bool get isPaid => status == InstallmentStatus.paid;
}

/// Everything about a loan worked out at one moment.
@immutable
class LoanSnapshot {
  const LoanSnapshot({
    required this.loan,
    required this.installments,
    required this.status,
    required this.principalReceivedMinor,
    required this.interestReceivedMinor,
    required this.overdueMinor,
    this.overduePrincipalMinor = 0,
    this.settlementMinor = 0,
  });

  final Loan loan;
  final List<InstallmentView> installments;
  final LoanStatus status;
  final int principalReceivedMinor;
  final int interestReceivedMinor;

  /// Amount of instalments past their due date that is still unpaid.
  final int overdueMinor;

  /// The principal part of [overdueMinor].
  final int overduePrincipalMinor;

  /// What settles the loan today: the current instalment plus the capital
  /// still outstanding after it (later instalments' interest is not owed
  /// when the capital is repaid early).
  final int settlementMinor;

  /// The EMI now asked for each month (after any revisions).
  int? get currentEmiMinor => loan.isMonthly ? loan.installmentMinor : null;

  /// Unpaid instalments left.
  int get remainingInstallments => installments.where((i) => !i.isPaid).length;
  String get id => loan.id;
  int get receivedMinor => loan.receivedMinor;
  int get outstandingMinor => loan.outstandingMinor;
  int get outstandingPrincipalMinor =>
      loan.principalMinor - principalReceivedMinor;
  bool get isCompleted => status == LoanStatus.completed;
  bool get isOverdue => status == LoanStatus.overdue;

  /// The first instalment that still expects money.
  InstallmentView? get nextDue {
    for (final i in installments) {
      if (!i.isPaid) return i;
    }
    return null;
  }

  InstallmentView? installmentById(String id) {
    for (final i in installments) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// 0..1 of the total owed that has been repaid.
  double get progress => loan.totalOwedMinor <= 0
      ? 0
      : (loan.receivedMinor / loan.totalOwedMinor).clamp(0.0, 1.0);
}

/// Totals for one borrower across their (separate) loans.
@immutable
class BorrowerSummary {
  const BorrowerSummary({
    required this.key,
    required this.name,
    required this.loans,
    required this.lentMinor,
    required this.receivedMinor,
    required this.outstandingMinor,
    required this.overdueMinor,
    required this.activeCount,
    required this.completedCount,
  });

  /// Normalised name used to group loans (case and spacing ignored).
  final String key;
  final String name;
  final List<LoanSnapshot> loans;
  final int lentMinor;
  final int receivedMinor;
  final int outstandingMinor;
  final int overdueMinor;
  final int activeCount;
  final int completedCount;
}

/// Lending totals of a set of loans.
@immutable
class LendingSummary {
  const LendingSummary({
    required this.lentMinor,
    required this.receivedMinor,
    required this.principalReceivedMinor,
    required this.interestReceivedMinor,
    required this.outstandingMinor,
    required this.outstandingPrincipalMinor,
    required this.overdueMinor,
    required this.overduePrincipalMinor,
    required this.activeCount,
    required this.overdueCount,
    required this.completedCount,
  });

  static const empty = LendingSummary(
    lentMinor: 0,
    receivedMinor: 0,
    principalReceivedMinor: 0,
    interestReceivedMinor: 0,
    outstandingMinor: 0,
    outstandingPrincipalMinor: 0,
    overdueMinor: 0,
    overduePrincipalMinor: 0,
    activeCount: 0,
    overdueCount: 0,
    completedCount: 0,
  );

  /// Principal lent.
  final int lentMinor;

  /// All money repaid (principal and interest).
  final int receivedMinor;
  final int principalReceivedMinor;

  /// Interest received: the only part of lending that is income.
  final int interestReceivedMinor;

  /// Still owed (principal and interest).
  final int outstandingMinor;

  /// Principal not yet repaid: money lent that is not in the balance.
  final int outstandingPrincipalMinor;
  final int overdueMinor;
  final int overduePrincipalMinor;

  /// Loans not completed (overdue ones included).
  final int activeCount;
  final int overdueCount;
  final int completedCount;

  int get loanCount => activeCount + completedCount;
}
