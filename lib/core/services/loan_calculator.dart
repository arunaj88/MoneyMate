import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';

/// The agreed interest of a loan and how many instalments it takes.
typedef LoanQuote = ({int interestMinor, int installmentCount});

/// Pure lending arithmetic, free of I/O so it can be unit tested.
///
/// Interest is simple (flat) interest on the amount lent, agreed up front:
///
/// * one-time loans: `principal × rate × days(lent → due) / 365`;
/// * monthly loans: `principal × rate × months / 12`, where `months` is the
///   number of instalments needed to repay principal and interest.
///
/// Every repayment is split between principal and interest in the
/// proportion `principal : interest` of the total owed, so the principal
/// and interest received always add up to what was received.
class LoanCalculator {
  LoanCalculator._();

  // ------------------------------------------------------------ schedule

  /// Due date of the instalment [index] (0-based) of a monthly loan whose
  /// first instalment is due on [firstDue]. Later instalments fall on
  /// [dueDay] of each following month, or that month's last day when it is
  /// shorter (e.g. the 31st becomes 28/29 February and 30 April).
  static DateTime monthlyDueDate(DateTime firstDue, int dueDay, int index) {
    final first = PeriodUtils.dateOnly(firstDue);
    if (index == 0) return first;
    final monthStart = DateTime(first.year, first.month + index);
    final lastDay = DateTime(monthStart.year, monthStart.month + 1, 0).day;
    final day = dueDay < 1 ? 1 : (dueDay > lastDay ? lastDay : dueDay);
    return DateTime(monthStart.year, monthStart.month, day);
  }

  /// Interest and instalment count for new terms. Throws [LoanException]
  /// when the terms cannot be repaid (e.g. an instalment that does not even
  /// cover the monthly interest).
  static LoanQuote quote({
    required int principalMinor,
    required int interestRateBp,
    required LoanRepaymentType type,
    required DateTime lentDate,
    int? installmentMinor,
    DateTime? dueDate,
  }) {
    if (principalMinor <= 0) {
      throw const LoanException('The amount must be greater than zero.');
    }
    if (interestRateBp < 0 || interestRateBp > LoanLimits.maxInterestRateBp) {
      throw const LoanException('Enter an interest rate from 0% to 100%.');
    }
    switch (type) {
      case LoanRepaymentType.oneTime:
        if (dueDate == null) {
          throw const LoanException('Choose the expected repayment date.');
        }
        final days = PeriodUtils.daysBetween(
          PeriodUtils.dateOnly(lentDate),
          PeriodUtils.dateOnly(dueDate),
        );
        final interest = interestRateBp == 0 || days <= 0
            ? 0
            : _round(
                BigInt.from(principalMinor) *
                    BigInt.from(interestRateBp) *
                    BigInt.from(days),
                BigInt.from(10000 * 365),
              );
        return (interestMinor: interest, installmentCount: 1);
      case LoanRepaymentType.monthly:
        final installment = installmentMinor ?? 0;
        if (installment <= 0) {
          throw const LoanException(
            'The monthly instalment must be greater than zero.',
          );
        }
        if (interestRateBp == 0) {
          final count = (principalMinor + installment - 1) ~/ installment;
          _checkCount(count);
          return (interestMinor: 0, installmentCount: count);
        }
        // Flat monthly interest; each instalment must cover more than it.
        final monthlyInterest = principalMinor * interestRateBp / (10000 * 12);
        if (installment <= monthlyInterest) {
          throw LoanException(
            'The monthly instalment must be more than the monthly interest '
            '(${Money.toInputString(monthlyInterest.ceil())}).',
          );
        }
        final months = (principalMinor / (installment - monthlyInterest))
            .ceil();
        _checkCount(months);
        final interest = _round(
          BigInt.from(principalMinor) *
              BigInt.from(interestRateBp) *
              BigInt.from(months),
          BigInt.from(10000 * 12),
        );
        final total = principalMinor + interest;
        final count = (total + installment - 1) ~/ installment;
        _checkCount(count);
        return (interestMinor: interest, installmentCount: count);
    }
  }

  /// Monthly instalment and interest when the borrower repays in [months]
  /// instalments: interest is `principal × rate × months / 12`, and the
  /// total is spread over the months (the last instalment may be a little
  /// smaller). Throws [LoanException] when [months] is out of range or the
  /// amount is too small to spread over that many months.
  static ({int installmentMinor, int interestMinor}) quoteForMonths({
    required int principalMinor,
    required int interestRateBp,
    required int months,
  }) {
    if (principalMinor <= 0) {
      throw const LoanException('The amount must be greater than zero.');
    }
    if (interestRateBp < 0 || interestRateBp > LoanLimits.maxInterestRateBp) {
      throw const LoanException('Enter an interest rate from 0% to 100%.');
    }
    if (months < 1) {
      throw const LoanException('Enter at least 1 month.');
    }
    _checkCount(months);
    final interest = interestRateBp == 0
        ? 0
        : _round(
            BigInt.from(principalMinor) *
                BigInt.from(interestRateBp) *
                BigInt.from(months),
            BigInt.from(10000 * 12),
          );
    final total = principalMinor + interest;
    final installment = (total + months - 1) ~/ months;
    // Rounding up must still leave something for the last month.
    if ((total + installment - 1) ~/ installment != months) {
      throw const LoanException(
        'The amount is too small to spread over that many months.',
      );
    }
    return (installmentMinor: installment, interestMinor: interest);
  }

  static void _checkCount(int count) {
    if (count > LoanLimits.maxInstallments) {
      throw const LoanException(
        'This would take more than 50 years to repay. Increase the monthly '
        'instalment.',
      );
    }
  }

  /// Rounds a / b to the nearest whole number (halves up).
  static int _round(BigInt a, BigInt b) =>
      ((a * BigInt.two + b) ~/ (b * BigInt.two)).toInt();

  /// Builds the schedule of a loan: [kept] instalments first (those that
  /// already received money; they never change), then new instalments for
  /// whatever of [totalOwedMinor] they do not cover.
  ///
  /// Monthly loans get instalments of [installmentMinor] (the last one
  /// smaller) from [firstDueDate] on [dueDay]; one-time loans one
  /// instalment due on [dueDate]. No instalment is created beyond what is
  /// owed. Throws [LoanException] when [kept] already expects more than
  /// [totalOwedMinor].
  static List<LoanInstallment> buildSchedule({
    required String loanId,
    required LoanRepaymentType type,
    required int totalOwedMinor,
    required String Function() newId,
    List<LoanInstallment> kept = const [],
    int? installmentMinor,
    DateTime? firstDueDate,
    int? dueDay,
    DateTime? dueDate,
  }) {
    final sortedKept = [...kept]..sort((a, b) => a.number.compareTo(b.number));
    final keptTotal = sortedKept.fold<int>(0, (s, i) => s + i.expectedMinor);
    var remaining = totalOwedMinor - keptTotal;
    if (remaining < 0) {
      throw const LoanException(
        'The total owed cannot be less than the instalments that have '
        'already been (partly) paid.',
      );
    }
    final result = [...sortedKept];
    var number = sortedKept.isEmpty ? 1 : sortedKept.last.number + 1;
    if (remaining == 0) return result;
    switch (type) {
      case LoanRepaymentType.oneTime:
        if (dueDate == null) {
          throw const LoanException('Choose the expected repayment date.');
        }
        result.add(
          LoanInstallment(
            id: newId(),
            loanId: loanId,
            number: number,
            dueDate: PeriodUtils.dateOnly(dueDate),
            expectedMinor: remaining,
          ),
        );
      case LoanRepaymentType.monthly:
        final amount = installmentMinor ?? 0;
        final first = firstDueDate;
        if (amount <= 0 || first == null) {
          throw const LoanException(
            'Enter the monthly instalment and the first repayment date.',
          );
        }
        final day = dueDay ?? first.day;
        var index = 0;
        while (remaining > 0) {
          if (result.length >= LoanLimits.maxInstallments) {
            _checkCount(result.length + 1);
          }
          final expected = remaining < amount ? remaining : amount;
          result.add(
            LoanInstallment(
              id: newId(),
              loanId: loanId,
              number: number++,
              dueDate: monthlyDueDate(first, day, index++),
              expectedMinor: expected,
            ),
          );
          remaining -= expected;
        }
    }
    return result;
  }

  /// Instalments of [snapshot] that have received money: they are kept as
  /// they are when the rest of the schedule is recalculated.
  static List<LoanInstallment> settledInstallments(LoanSnapshot snapshot) => [
    for (final i in snapshot.installments)
      if (i.receivedMinor > 0) i.installment,
  ];

  // ------------------------------------------------------------ snapshot

  /// [loan] with its [repayments] applied at [now]: amounts received go to
  /// the oldest instalment first, then to later ones (early and extra
  /// payments simply reduce the next instalments).
  static LoanSnapshot snapshot(
    Loan loan,
    Iterable<LoanRepayment> repayments,
    DateTime now,
  ) {
    final counted =
        repayments.where((r) => r.loanId == loan.id && r.counts).toList()
          ..sort((a, b) {
            final byDate = a.date.compareTo(b.date);
            return byDate != 0 ? byDate : a.createdAt.compareTo(b.createdAt);
          });
    final received = counted.fold<int>(0, (s, r) => s + r.amountMinor);
    final withReceived = loan.copyWith(receivedMinor: received);
    final today = PeriodUtils.dateOnly(now);

    final pool = [for (final r in counted) (id: r.id, left: r.amountMinor)];
    var head = 0;
    final views = <InstallmentView>[];
    var overdue = 0;
    final installments = [...loan.schedule]
      ..sort((a, b) => a.number.compareTo(b.number));
    for (final inst in installments) {
      var need = inst.expectedMinor;
      final ids = <String>[];
      while (need > 0 && head < pool.length) {
        final take = pool[head].left < need ? pool[head].left : need;
        ids.add(pool[head].id);
        need -= take;
        pool[head] = (id: pool[head].id, left: pool[head].left - take);
        if (pool[head].left == 0) head++;
      }
      final got = inst.expectedMinor - need;
      final status = statusOf(
        dueDate: inst.dueDate,
        expectedMinor: inst.expectedMinor,
        receivedMinor: got,
        today: today,
      );
      if (status == InstallmentStatus.overdue) overdue += need;
      views.add(
        InstallmentView(
          installment: inst,
          receivedMinor: got,
          status: status,
          repaymentIds: List.unmodifiable(ids),
        ),
      );
    }
    final LoanStatus status;
    if (withReceived.isFullyRepaid) {
      status = LoanStatus.completed;
    } else if (overdue > 0) {
      status = LoanStatus.overdue;
    } else {
      status = LoanStatus.active;
    }
    final principalReceived = principalPart(
      received,
      loan.principalMinor,
      loan.totalOwedMinor,
    );
    return LoanSnapshot(
      loan: withReceived,
      installments: List.unmodifiable(views),
      status: status,
      principalReceivedMinor: principalReceived,
      interestReceivedMinor: received - principalReceived,
      overdueMinor: status == LoanStatus.completed ? 0 : overdue,
    );
  }

  /// Status of one instalment at [today] (a date without time).
  static InstallmentStatus statusOf({
    required DateTime dueDate,
    required int expectedMinor,
    required int receivedMinor,
    required DateTime today,
  }) {
    if (receivedMinor >= expectedMinor) return InstallmentStatus.paid;
    final due = PeriodUtils.dateOnly(dueDate);
    if (due.isBefore(today)) return InstallmentStatus.overdue;
    if (receivedMinor > 0) return InstallmentStatus.partiallyPaid;
    if (PeriodUtils.daysBetween(today, due) <= LoanLimits.dueSoonDays) {
      return InstallmentStatus.due;
    }
    return InstallmentStatus.upcoming;
  }

  /// The principal part of [amountMinor] received on a loan of
  /// [principalMinor] that owes [totalOwedMinor] in total.
  static int principalPart(
    int amountMinor,
    int principalMinor,
    int totalOwedMinor,
  ) {
    if (amountMinor <= 0 || totalOwedMinor <= 0) return 0;
    if (amountMinor >= totalOwedMinor) return principalMinor;
    return (BigInt.from(amountMinor) *
            BigInt.from(principalMinor) ~/
            BigInt.from(totalOwedMinor))
        .toInt();
  }

  // ------------------------------------------------------------ summaries

  static LendingSummary summarize(Iterable<LoanSnapshot> loans) {
    var lent = 0;
    var received = 0;
    var principalReceived = 0;
    var interestReceived = 0;
    var outstanding = 0;
    var outstandingPrincipal = 0;
    var overdue = 0;
    var overduePrincipal = 0;
    var active = 0;
    var overdueCount = 0;
    var completed = 0;
    for (final s in loans) {
      final loan = s.loan;
      lent += loan.principalMinor;
      received += loan.receivedMinor;
      principalReceived += s.principalReceivedMinor;
      interestReceived += s.interestReceivedMinor;
      outstanding += loan.outstandingMinor;
      outstandingPrincipal += s.outstandingPrincipalMinor;
      overdue += s.overdueMinor;
      overduePrincipal += principalPart(
        s.overdueMinor,
        loan.principalMinor,
        loan.totalOwedMinor,
      );
      switch (s.status) {
        case LoanStatus.completed:
          completed++;
        case LoanStatus.overdue:
          active++;
          overdueCount++;
        case LoanStatus.active:
          active++;
      }
    }
    return LendingSummary(
      lentMinor: lent,
      receivedMinor: received,
      principalReceivedMinor: principalReceived,
      interestReceivedMinor: interestReceived,
      outstandingMinor: outstanding,
      outstandingPrincipalMinor: outstandingPrincipal,
      overdueMinor: overdue,
      overduePrincipalMinor: overduePrincipal,
      activeCount: active,
      overdueCount: overdueCount,
      completedCount: completed,
    );
  }

  /// Key used to group loans by borrower: the name without case or extra
  /// spaces. Loans are never merged, only listed together.
  static String borrowerKey(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Loans grouped by borrower, the borrowers with the most outstanding
  /// first.
  static List<BorrowerSummary> byBorrower(Iterable<LoanSnapshot> loans) {
    final groups = <String, List<LoanSnapshot>>{};
    for (final s in loans) {
      groups.putIfAbsent(borrowerKey(s.loan.borrowerName), () => []).add(s);
    }
    final result = <BorrowerSummary>[];
    for (final MapEntry(key: key, value: list) in groups.entries) {
      list.sort((a, b) => b.loan.lentDate.compareTo(a.loan.lentDate));
      final sum = summarize(list);
      result.add(
        BorrowerSummary(
          key: key,
          name: list.first.loan.borrowerName.trim(),
          loans: List.unmodifiable(list),
          lentMinor: sum.lentMinor,
          receivedMinor: sum.receivedMinor,
          outstandingMinor: sum.outstandingMinor,
          overdueMinor: sum.overdueMinor,
          activeCount: sum.activeCount,
          completedCount: sum.completedCount,
        ),
      );
    }
    result.sort((a, b) {
      final byOutstanding = b.outstandingMinor.compareTo(a.outstandingMinor);
      return byOutstanding != 0 ? byOutstanding : a.name.compareTo(b.name);
    });
    return result;
  }
}
