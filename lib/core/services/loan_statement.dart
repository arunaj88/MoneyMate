import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';

/// What the lender chose to put in a statement.
@immutable
class LoanStatementOptions {
  const LoanStatementOptions({
    this.lenderName = '',
    this.includeContactDetails = false,
    this.includeNotes = true,
  });

  /// Shown as the lender (the signed-in user's name by default).
  final String lenderName;

  /// The borrower's phone and email are left out unless chosen.
  final bool includeContactDetails;

  /// The loan's notes / terms.
  final bool includeNotes;

  LoanStatementOptions copyWith({
    String? lenderName,
    bool? includeContactDetails,
    bool? includeNotes,
  }) => LoanStatementOptions(
    lenderName: lenderName ?? this.lenderName,
    includeContactDetails: includeContactDetails ?? this.includeContactDetails,
    includeNotes: includeNotes ?? this.includeNotes,
  );

  @override
  bool operator ==(Object other) =>
      other is LoanStatementOptions &&
      other.lenderName == lenderName &&
      other.includeContactDetails == includeContactDetails &&
      other.includeNotes == includeNotes;

  @override
  int get hashCode =>
      Object.hash(lenderName, includeContactDetails, includeNotes);
}

/// One instalment as the statement shows it.
@immutable
class StatementInstallment {
  const StatementInstallment({
    required this.number,
    required this.dueDate,
    required this.scheduledMinor,
    required this.principalMinor,
    required this.interestMinor,
    required this.receivedMinor,
    required this.extraPrincipalMinor,
    required this.unpaidMinor,
    required this.status,
    this.revisedFromHere = false,
  });

  final int number;
  final DateTime dueDate;

  /// The EMI asked for (before any extra capital paid with it).
  final int scheduledMinor;

  /// Principal and interest parts of [scheduledMinor].
  final int principalMinor;
  final int interestMinor;

  /// Everything received towards it, extra capital included.
  final int receivedMinor;

  /// Paid above the EMI with this instalment, straight to capital.
  final int extraPrincipalMinor;

  /// Still to be paid on this instalment.
  final int unpaidMinor;
  final InstallmentStatus status;

  /// A revised EMI took effect with this instalment.
  final bool revisedFromHere;

  /// "Overdue" also says when part of it was paid.
  String get statusLabel =>
      status == InstallmentStatus.overdue && receivedMinor > 0
      ? 'Overdue (part paid)'
      : status.label;
}

/// One recorded repayment as the statement shows it.
@immutable
class StatementRepayment {
  const StatementRepayment({
    required this.date,
    required this.amountMinor,
    this.installmentNumber,
    this.scheduledEmiMinor,
    this.principalMinor = 0,
    this.interestMinor = 0,
    this.extraPrincipalMinor = 0,
    this.capitalAfterMinor,
    this.voided = false,
  });

  final DateTime date;
  final int amountMinor;
  final int? installmentNumber;

  /// The EMI of the instalment it went to, when it was paid.
  final int? scheduledEmiMinor;
  final int principalMinor;
  final int interestMinor;
  final int extraPrincipalMinor;

  /// Capital still owed right after it.
  final int? capitalAfterMinor;

  /// Recorded by mistake and voided: listed, but not counted.
  final bool voided;
}

/// One EMI change caused by an extra capital repayment.
@immutable
class StatementRevision {
  const StatementRevision({
    required this.date,
    required this.capitalBeforeMinor,
    required this.extraPrincipalMinor,
    required this.capitalAfterMinor,
    this.previousEmiMinor,
    this.newEmiMinor,
    required this.remainingInstallments,
    this.effectiveFrom,
  });

  /// When the extra repayment was made.
  final DateTime date;
  final int capitalBeforeMinor;
  final int extraPrincipalMinor;
  final int capitalAfterMinor;
  final int? previousEmiMinor;

  /// Null when the extra repayment settled the loan.
  final int? newEmiMinor;
  final int remainingInstallments;
  final DateTime? effectiveFrom;
}

/// Everything a loan statement for the borrower contains, worked out from
/// the saved loan and its repayments at [generatedAt].
///
/// It holds only this one lending record: no household, member, reminder
/// or other borrowers' information.
@immutable
class LoanStatement {
  const LoanStatement({
    required this.reference,
    required this.generatedAt,
    required this.currencyCode,
    required this.lenderName,
    required this.borrowerName,
    this.borrowerPhone,
    this.borrowerEmail,
    required this.repaymentType,
    required this.lentDate,
    required this.principalMinor,
    required this.interestRateBp,
    this.interestMethodLabel,
    this.originalTermMonths,
    this.originalEmiMinor,
    this.originalFinalDueDate,
    required this.originalInterestMinor,
    this.notes,
    required this.status,
    required this.principalRepaidMinor,
    required this.extraPrincipalMinor,
    required this.interestReceivedMinor,
    required this.receivedMinor,
    required this.outstandingPrincipalMinor,
    required this.outstandingMinor,
    required this.overdueMinor,
    required this.currentInterestMinor,
    this.currentEmiMinor,
    this.currentFinalDueDate,
    required this.completedInstallments,
    required this.remainingInstallments,
    this.nextAmountMinor,
    this.nextDueDate,
    required this.installments,
    required this.repayments,
    required this.revisions,
  });

  /// Builds the statement of [loan] (as saved: the agreed schedule, not a
  /// snapshot) with [repayments] applied at [now], the same way the app
  /// shows it.
  factory LoanStatement.build({
    required Loan loan,
    required Iterable<LoanRepayment> repayments,
    required DateTime now,
    required String currencyCode,
    LoanStatementOptions options = const LoanStatementOptions(),
  }) {
    final own = [
      for (final r in repayments)
        if (r.loanId == loan.id && !r.isRejected) r,
    ]..sort(_byDate);
    final counted = [
      for (final r in own)
        if (r.counts) r,
    ];
    final snapshot = LoanCalculator.snapshot(loan, counted, now);
    final current = snapshot.loan;
    final allocations = _allocations(loan, counted, now);

    // EMI revisions, oldest first.
    final revisions = <StatementRevision>[];
    for (final r in counted) {
      final a = allocations[r.id];
      if (a == null || a.extraPrincipalMinor <= 0) continue;
      revisions.add(
        StatementRevision(
          date: r.date,
          capitalBeforeMinor: a.principalBeforeMinor,
          extraPrincipalMinor: a.extraPrincipalMinor,
          capitalAfterMinor: a.principalAfterMinor,
          previousEmiMinor: a.previousEmiMinor,
          newEmiMinor: a.revisedEmiMinor,
          remainingInstallments: a.remainingInstallments,
          effectiveFrom: a.effectiveFrom,
        ),
      );
    }
    final revisedDays = {
      for (final r in revisions)
        if (r.effectiveFrom != null && r.newEmiMinor != null)
          PeriodUtils.dateOnly(r.effectiveFrom!),
    };

    final installments = [
      for (final v in snapshot.installments)
        StatementInstallment(
          number: v.number,
          dueDate: v.dueDate,
          scheduledMinor: v.scheduledMinor,
          principalMinor: v.scheduledMinor - v.interestMinor,
          interestMinor: v.interestMinor,
          receivedMinor: v.receivedMinor,
          extraPrincipalMinor: v.extraPrincipalMinor,
          unpaidMinor: v.remainingMinor,
          status: v.status,
          revisedFromHere: revisedDays.contains(
            PeriodUtils.dateOnly(v.dueDate),
          ),
        ),
    ];

    final history = [
      for (final r in own)
        if (r.voided)
          StatementRepayment(
            date: r.date,
            amountMinor: r.amountMinor,
            voided: true,
          )
        else
          switch (allocations[r.id]) {
            final a? => StatementRepayment(
              date: r.date,
              amountMinor: r.amountMinor,
              installmentNumber: a.installmentNumber,
              scheduledEmiMinor: a.installmentNumber == null
                  ? null
                  : a.scheduledEmiMinor,
              principalMinor: a.principalPortionMinor,
              interestMinor: a.interestPortionMinor,
              extraPrincipalMinor: a.extraPrincipalMinor,
              capitalAfterMinor: a.principalAfterMinor,
            ),
            null => StatementRepayment(
              date: r.date,
              amountMinor: r.amountMinor,
            ),
          },
    ];

    final next = snapshot.nextDue;
    final extraTotal = snapshot.installments.fold<int>(
      0,
      (s, i) => s + i.extraPrincipalMinor,
    );
    final contact = options.includeContactDetails;
    return LoanStatement(
      reference: referenceOf(loan),
      generatedAt: now,
      currencyCode: currencyCode,
      lenderName: options.lenderName.trim(),
      borrowerName: loan.borrowerName.trim(),
      borrowerPhone: contact && loan.borrowerPhone.trim().isNotEmpty
          ? loan.borrowerPhone.trim()
          : null,
      borrowerEmail: contact && loan.borrowerEmail.trim().isNotEmpty
          ? loan.borrowerEmail.trim()
          : null,
      repaymentType: loan.repaymentType,
      lentDate: loan.lentDate,
      principalMinor: loan.principalMinor,
      interestRateBp: loan.interestRateBp,
      interestMethodLabel: loan.interestRateBp == 0
          ? null
          : loan.isMonthly
          ? loan.interestMethod.label
          : 'Simple interest (by days)',
      originalTermMonths: loan.isMonthly
          ? loan.originalTermMonths ?? loan.schedule.length
          : null,
      originalEmiMinor: loan.isMonthly
          ? loan.originalInstallmentMinor ??
                loan.installmentMinor ??
                (loan.schedule.isEmpty
                    ? null
                    : loan.schedule.first.expectedMinor)
          : null,
      originalFinalDueDate: _originalFinalDue(loan),
      originalInterestMinor: loan.interestMinor,
      notes: options.includeNotes && loan.notes.trim().isNotEmpty
          ? loan.notes.trim()
          : null,
      status: snapshot.status,
      principalRepaidMinor: snapshot.principalReceivedMinor,
      extraPrincipalMinor: extraTotal,
      interestReceivedMinor: snapshot.interestReceivedMinor,
      receivedMinor: snapshot.receivedMinor,
      outstandingPrincipalMinor: snapshot.outstandingPrincipalMinor,
      outstandingMinor: snapshot.outstandingMinor,
      overdueMinor: snapshot.overdueMinor,
      currentInterestMinor: current.interestMinor,
      currentEmiMinor: snapshot.isCompleted ? null : snapshot.currentEmiMinor,
      currentFinalDueDate: snapshot.installments.isEmpty
          ? null
          : snapshot.installments.last.dueDate,
      completedInstallments: snapshot.installments
          .where((i) => i.isPaid)
          .length,
      remainingInstallments: snapshot.remainingInstallments,
      nextAmountMinor: next?.remainingMinor,
      nextDueDate: next?.dueDate,
      installments: List.unmodifiable(installments),
      repayments: List.unmodifiable(history),
      revisions: List.unmodifiable(revisions),
    );
  }

  /// e.g. "ML-20261201-3F9A2C": the lending date and the start of the
  /// record's ID, so the same loan always has the same reference.
  static String referenceOf(Loan loan) {
    final id = loan.id.replaceAll(RegExp('[^A-Za-z0-9]'), '').toUpperCase();
    final short = id.length > 6 ? id.substring(0, 6) : id;
    return 'ML-${DateFormat('yyyyMMdd').format(loan.lentDate)}-$short';
  }

  final String reference;
  final DateTime generatedAt;
  final String currencyCode;

  /// Empty when the lender left it out.
  final String lenderName;
  final String borrowerName;
  final String? borrowerPhone;
  final String? borrowerEmail;

  // --------------------------------------------------- original agreement
  final LoanRepaymentType repaymentType;
  final DateTime lentDate;
  final int principalMinor;
  final int interestRateBp;

  /// Null for an interest-free loan.
  final String? interestMethodLabel;
  final int? originalTermMonths;
  final int? originalEmiMinor;
  final DateTime? originalFinalDueDate;

  /// Interest agreed when the loan was recorded.
  final int originalInterestMinor;
  final String? notes;

  // ----------------------------------------------------------- now
  final LoanStatus status;

  /// Principal repaid, extra capital included.
  final int principalRepaidMinor;

  /// Of which paid above the EMI.
  final int extraPrincipalMinor;
  final int interestReceivedMinor;
  final int receivedMinor;
  final int outstandingPrincipalMinor;

  /// Still owed by the schedule (principal and interest).
  final int outstandingMinor;
  final int overdueMinor;

  /// Interest of the schedule as it is now.
  final int currentInterestMinor;

  /// Null for one-time and completed loans.
  final int? currentEmiMinor;
  final DateTime? currentFinalDueDate;
  final int completedInstallments;
  final int remainingInstallments;
  final int? nextAmountMinor;
  final DateTime? nextDueDate;

  final List<StatementInstallment> installments;

  /// All repayments, oldest first (voided ones marked).
  final List<StatementRepayment> repayments;

  /// EMI revisions, oldest first.
  final List<StatementRevision> revisions;

  bool get isMonthly => repaymentType == LoanRepaymentType.monthly;
  bool get isCompleted => status == LoanStatus.completed;
  bool get hasInterest => interestRateBp > 0;
  bool get hasContactDetails => borrowerPhone != null || borrowerEmail != null;

  /// The EMI now differs from the one agreed.
  bool get emiRevised =>
      revisions.isNotEmpty ||
      (currentEmiMinor != null &&
          originalEmiMinor != null &&
          currentEmiMinor != originalEmiMinor);

  int get totalInstallments => installments.length;

  // ------------------------------------------------------------ formatting

  static final NumberFormat _amount = NumberFormat('#,##0.00', 'en_US');
  static final DateFormat longDate = DateFormat('d MMMM yyyy', 'en_US');
  static final DateFormat shortDate = DateFormat('d MMM yyyy', 'en_US');
  static final DateFormat _time = DateFormat('HH:mm', 'en_US');

  /// e.g. "AED 1,234.50".
  String money(int minor) => '$currencyCode ${amount(minor)}';

  /// e.g. "1,234.50" (tables say the currency once in the heading).
  static String amount(int minor) => _amount.format(Money.toMajor(minor));

  /// e.g. "26 November 2026, 14:05".
  String get generatedLabel =>
      '${longDate.format(generatedAt)}, ${_time.format(generatedAt)}';

  /// e.g. "12.5% a year (Reducing balance)" or "Interest-free".
  String get interestLabel => hasInterest
      ? '${formatRateBp(interestRateBp)} a year'
            '${interestMethodLabel == null ? '' : ' ($interestMethodLabel)'}'
      : 'Interest-free';

  String get originalPeriodLabel {
    if (!isMonthly) {
      final due = originalFinalDueDate;
      return due == null
          ? 'One-time repayment'
          : 'One-time repayment by ${longDate.format(due)}';
    }
    final months = originalTermMonths;
    if (months == null) return 'Monthly';
    return '$months monthly instalment${months == 1 ? '' : 's'}';
  }

  // ------------------------------------------------------------ text

  /// A short summary to send as a message. [withAttachment] says the PDF
  /// statement is sent with it.
  String toText({bool withAttachment = false}) {
    final lines = <String>[
      'MoneyMate - Loan Repayment Details',
      'Reference: $reference',
      'Borrower: $borrowerName',
      if (lenderName.isNotEmpty) 'Lender: $lenderName',
      'Loan Amount: ${money(principalMinor)}',
      'Loan Date: ${longDate.format(lentDate)}',
      if (hasInterest) 'Interest: $interestLabel',
    ];
    if (isMonthly) {
      if (originalEmiMinor != null) {
        lines.add('Original EMI: ${money(originalEmiMinor!)}');
      }
      if (currentEmiMinor != null) {
        lines.add(
          '${emiRevised ? 'Revised EMI' : 'Current EMI'}: '
          '${money(currentEmiMinor!)}',
        );
      }
    }
    if (isCompleted) {
      lines.addAll([
        'Total Repaid: ${money(receivedMinor)}',
        'Status: Repaid in full',
      ]);
    } else {
      lines.addAll([
        'Outstanding Capital: ${money(outstandingPrincipalMinor)}',
        if (hasInterest || outstandingMinor != outstandingPrincipalMinor)
          'Total Outstanding: ${money(outstandingMinor)}',
        if (isMonthly) 'Remaining Instalments: $remainingInstallments',
        if (nextAmountMinor != null) 'Next Payment: ${money(nextAmountMinor!)}',
        if (nextDueDate != null)
          'Next Due Date: ${longDate.format(nextDueDate!)}',
        if (overdueMinor > 0) 'Overdue: ${money(overdueMinor)}',
      ]);
    }
    lines
      ..add('Statement Date: ${longDate.format(generatedAt)}')
      ..add('')
      ..add(
        withAttachment
            ? 'Please refer to the attached complete repayment statement for '
                  'the instalment schedule and payment history.'
            : 'A complete repayment statement with the instalment schedule '
                  'and payment history is available as a PDF.',
      );
    return lines.join('\n');
  }

  /// e.g. "MoneyMate-Loan-Statement-ML-20261201-3F9A2C-20261126.pdf".
  String get fileName =>
      'MoneyMate-Loan-Statement-$reference-'
      '${DateFormat('yyyyMMdd').format(generatedAt)}.pdf';

  // ------------------------------------------------------------ helpers

  static int _byDate(LoanRepayment a, LoanRepayment b) {
    final byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.createdAt.compareTo(b.createdAt);
  }

  static DateTime? _originalFinalDue(Loan loan) {
    if (!loan.isMonthly) return loan.dueDate;
    final first = loan.firstDueDate;
    final months = loan.originalTermMonths;
    if (first != null && months != null && months > 0) {
      return LoanCalculator.monthlyDueDate(
        first,
        loan.dueDay ?? first.day,
        months - 1,
      );
    }
    if (loan.endDate != null) return loan.endDate;
    return loan.schedule.isEmpty ? null : loan.schedule.last.dueDate;
  }

  /// How each counted repayment was applied: the record kept with it, or
  /// (for repayments recorded before that record existed) worked out by
  /// replaying the repayments in order.
  static Map<String, RepaymentAllocation> _allocations(
    Loan loan,
    List<LoanRepayment> counted,
    DateTime now,
  ) {
    final result = <String, RepaymentAllocation>{
      for (final r in counted)
        if (r.allocation != null) r.id: r.allocation!,
    };
    if (result.length == counted.length) return result;
    var before = LoanCalculator.snapshot(loan, const [], now);
    for (var k = 0; k < counted.length; k++) {
      final r = counted[k];
      final after = LoanCalculator.snapshot(
        loan,
        counted.sublist(0, k + 1),
        now,
      );
      result.putIfAbsent(
        r.id,
        () => LoanCalculator.allocation(
          before: before,
          after: after,
          amountMinor: r.amountMinor,
          now: r.date,
        ),
      );
      before = after;
    }
    return result;
  }
}
