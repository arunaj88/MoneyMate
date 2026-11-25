import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/models/loan_model.dart';

/// Minor units of [major] (AED 1,000 → 100000).
int aed(num major) => (major * 100).round();

int _ids = 0;
String nextId() => 'i${++_ids}';

/// A monthly loan repaid at [installment] a month, or over [months]
/// instalments when given.
Loan monthlyLoan({
  String id = 'loan',
  int principal = 1200000,
  int? installment = 100000,
  int? months,
  int rateBp = 0,
  InterestMethod method = InterestMethod.flat,
  DateTime? lent,
  DateTime? firstDue,
  int? dueDay,
}) {
  final lentDate = lent ?? DateTime(2026, 12, 1);
  final first = firstDue ?? DateTime(2027, 1, 1);
  final schedule = LoanCalculator.buildSchedule(
    loanId: id,
    type: LoanRepaymentType.monthly,
    principalMinor: principal,
    newId: nextId,
    method: method,
    interestRateBp: rateBp,
    installmentMinor: months == null ? installment : null,
    months: months,
    firstDueDate: first,
    dueDay: dueDay ?? first.day,
  );
  final interest = schedule.fold<int>(0, (s, i) => s + (i.interestMinor ?? 0));
  return Loan(
    id: id,
    borrowerName: 'John',
    principalMinor: principal,
    interestRateBp: rateBp,
    interestMinor: interest,
    interestMethod: method,
    originalInstallmentMinor: schedule.first.expectedMinor,
    originalTermMonths: schedule.length,
    lentDate: lentDate,
    repaymentType: LoanRepaymentType.monthly,
    installmentMinor: schedule.first.expectedMinor,
    firstDueDate: first,
    dueDay: dueDay ?? first.day,
    schedule: schedule,
    createdAt: lentDate,
    updatedAt: lentDate,
  );
}

Loan oneTimeLoan({
  String id = 'once',
  int principal = 500000,
  int rateBp = 0,
  DateTime? lent,
  DateTime? due,
  String name = 'Sara',
  String? householdId,
}) {
  final lentDate = lent ?? DateTime(2026, 11, 1);
  final dueDate = due ?? DateTime(2027, 2, 1);
  final interest = LoanCalculator.oneTimeInterest(
    principal,
    rateBp,
    lentDate,
    dueDate,
  );
  return Loan(
    id: id,
    borrowerName: name,
    principalMinor: principal,
    interestRateBp: rateBp,
    interestMinor: interest,
    lentDate: lentDate,
    repaymentType: LoanRepaymentType.oneTime,
    dueDate: dueDate,
    householdId: householdId,
    schedule: LoanCalculator.buildSchedule(
      loanId: id,
      type: LoanRepaymentType.oneTime,
      principalMinor: principal,
      newId: nextId,
      dueDate: dueDate,
      oneTimeInterestMinor: interest,
    ),
    createdAt: lentDate,
    updatedAt: lentDate,
  );
}

LoanRepayment pay(
  String loanId,
  int amount,
  DateTime date, {
  String? id,
  bool voided = false,
  RepaymentSyncState state = RepaymentSyncState.synced,
}) => LoanRepayment(
  id: id ?? 'r-${date.millisecondsSinceEpoch}-$amount',
  loanId: loanId,
  amountMinor: amount,
  date: date,
  createdAt: date,
  updatedAt: date,
  voided: voided,
  syncState: state,
);
