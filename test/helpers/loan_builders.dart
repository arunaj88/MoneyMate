import 'package:money_mate/core/services/loan_calculator.dart';
import 'package:money_mate/models/loan_model.dart';

/// Minor units of [major] (AED 1,000 → 100000).
int aed(num major) => (major * 100).round();

int _ids = 0;
String nextId() => 'i${++_ids}';

Loan monthlyLoan({
  String id = 'loan',
  int principal = 1200000,
  int installment = 100000,
  int rateBp = 0,
  DateTime? lent,
  DateTime? firstDue,
  int? dueDay,
}) {
  final lentDate = lent ?? DateTime(2026, 12, 1);
  final first = firstDue ?? DateTime(2027, 1, 1);
  final quote = LoanCalculator.quote(
    principalMinor: principal,
    interestRateBp: rateBp,
    type: LoanRepaymentType.monthly,
    lentDate: lentDate,
    installmentMinor: installment,
  );
  final schedule = LoanCalculator.buildSchedule(
    loanId: id,
    type: LoanRepaymentType.monthly,
    totalOwedMinor: principal + quote.interestMinor,
    newId: nextId,
    installmentMinor: installment,
    firstDueDate: first,
    dueDay: dueDay ?? first.day,
  );
  return Loan(
    id: id,
    borrowerName: 'John',
    principalMinor: principal,
    interestRateBp: rateBp,
    interestMinor: quote.interestMinor,
    lentDate: lentDate,
    repaymentType: LoanRepaymentType.monthly,
    installmentMinor: installment,
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
  final quote = LoanCalculator.quote(
    principalMinor: principal,
    interestRateBp: rateBp,
    type: LoanRepaymentType.oneTime,
    lentDate: lentDate,
    dueDate: dueDate,
  );
  return Loan(
    id: id,
    borrowerName: name,
    principalMinor: principal,
    interestRateBp: rateBp,
    interestMinor: quote.interestMinor,
    lentDate: lentDate,
    repaymentType: LoanRepaymentType.oneTime,
    dueDate: dueDate,
    householdId: householdId,
    schedule: LoanCalculator.buildSchedule(
      loanId: id,
      type: LoanRepaymentType.oneTime,
      totalOwedMinor: principal + quote.interestMinor,
      newId: nextId,
      dueDate: dueDate,
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
