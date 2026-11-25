import 'dart:math' as math;

import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';

/// The interest of a loan's schedule and how many instalments it takes.
typedef LoanQuote = ({int interestMinor, int installmentCount});

/// One planned instalment: its principal and interest parts.
typedef PlannedAmount = ({int principalMinor, int interestMinor});

/// Pure lending arithmetic, free of I/O so it can be unit tested.
///
/// **Interest** is worked out with the method chosen for the loan:
///
/// * one-time loans: `principal × rate × days(lent → due) / 365`;
/// * flat monthly loans: `principal × rate × months / 12`, spread evenly;
/// * reducing-balance monthly loans: each month `outstanding × rate / 12`,
///   with the EMI from `P × r × (1 + r)^n / ((1 + r)^n − 1)`.
///
/// Within an instalment, money goes to its interest first, then to its
/// principal.
///
/// **Extra repayments.** Whatever is paid above the current instalment goes
/// straight to the capital (principal): the instalment is paid, the capital
/// drops by the extra, and the remaining instalments — the same number, on
/// the same dates — are recalculated from the reduced capital with the
/// loan's interest method. The schedule is derived from the repayments
/// every time it is read ([snapshot]), so every device arrives at the same
/// schedule from the same repayment records, and voiding a repayment undoes
/// its effect.
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

  static void _checkRate(int bp) {
    if (bp < 0 || bp > LoanLimits.maxInterestRateBp) {
      throw const LoanException('Enter an interest rate from 0% to 100%.');
    }
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

  static int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;

  /// Flat interest on [principalMinor] for [months] months.
  static int flatInterest(int principalMinor, int rateBp, int months) =>
      rateBp == 0 || months <= 0
      ? 0
      : _round(
          BigInt.from(principalMinor) *
              BigInt.from(rateBp) *
              BigInt.from(months),
          BigInt.from(10000 * 12),
        );

  /// Monthly instalments that repay [principalMinor] with [method] at
  /// [rateBp], either over [months] instalments or at [installmentMinor] a
  /// month. Amounts are whole minor units; the last instalment settles the
  /// exact rest (so it may be a little smaller). Throws [LoanException]
  /// when the terms cannot work.
  static List<PlannedAmount> planMonthly({
    required int principalMinor,
    required InterestMethod method,
    required int rateBp,
    int? months,
    int? installmentMinor,
  }) {
    if (principalMinor <= 0) {
      throw const LoanException('The amount must be greater than zero.');
    }
    _checkRate(rateBp);
    if (months != null) {
      if (months < 1) throw const LoanException('Enter at least 1 month.');
      _checkCount(months);
      return rateBp > 0 && method == InterestMethod.reducing
          ? _reducingOver(principalMinor, rateBp, months)
          : _flatOver(principalMinor, rateBp, months);
    }
    final amount = installmentMinor ?? 0;
    if (amount <= 0) {
      throw const LoanException(
        'The monthly instalment must be greater than zero.',
      );
    }
    if (rateBp == 0) {
      final count = _ceilDiv(principalMinor, amount);
      _checkCount(count);
      return _flatAmounts(principalMinor, 0, amount);
    }
    if (method == InterestMethod.reducing) {
      return _reducingAt(principalMinor, rateBp, amount);
    }
    // Flat: the instalment must cover more than the monthly interest.
    final monthlyInterest = principalMinor * rateBp / (10000 * 12);
    if (amount <= monthlyInterest) {
      throw LoanException(
        'The monthly instalment must be more than the monthly interest '
        '(${Money.toInputString(monthlyInterest.ceil())}).',
      );
    }
    final monthsNeeded = (principalMinor / (amount - monthlyInterest)).ceil();
    _checkCount(monthsNeeded);
    final interest = flatInterest(principalMinor, rateBp, monthsNeeded);
    final plan = _flatAmounts(principalMinor, interest, amount);
    _checkCount(plan.length);
    return plan;
  }

  /// Flat (or interest-free) over [months]: the total spread evenly, the
  /// EMI rounded up and the last instalment settling the rest.
  static List<PlannedAmount> _flatOver(int principal, int rateBp, int months) {
    final interest = flatInterest(principal, rateBp, months);
    final total = principal + interest;
    final emi = _ceilDiv(total, months);
    return _flatAmounts(principal, interest, emi);
  }

  /// [principal] + [interest] in instalments of [emi] (the last one
  /// smaller), with the interest spread in proportion to each amount.
  static List<PlannedAmount> _flatAmounts(
    int principal,
    int interest,
    int emi,
  ) {
    final total = principal + interest;
    final result = <PlannedAmount>[];
    var paid = 0;
    var interestSoFar = 0;
    while (paid < total) {
      final amount = total - paid < emi ? total - paid : emi;
      paid += amount;
      final interestCumulative = total == 0
          ? 0
          : _round(
              BigInt.from(interest) * BigInt.from(paid),
              BigInt.from(total),
            );
      final part = interestCumulative - interestSoFar;
      interestSoFar = interestCumulative;
      result.add((principalMinor: amount - part, interestMinor: part));
    }
    return result;
  }

  /// Reducing balance over [months]: the EMI from the standard formula,
  /// rounded up to a whole minor unit; the last instalment settles the
  /// exact rest.
  static List<PlannedAmount> _reducingOver(
    int principal,
    int rateBp,
    int months,
  ) {
    final r = rateBp / (10000 * 12);
    final growth = math.pow(1 + r, months).toDouble();
    final emi = (principal * r * growth / (growth - 1)).ceil();
    return _amortize(principal, rateBp, emi, maxCount: months);
  }

  /// Reducing balance at a fixed [emi] until the capital is repaid.
  static List<PlannedAmount> _reducingAt(int principal, int rateBp, int emi) {
    final firstInterest = _monthlyInterest(principal, rateBp);
    if (emi <= firstInterest) {
      throw LoanException(
        'The monthly instalment must be more than the monthly interest '
        '(${Money.toInputString(firstInterest)}).',
      );
    }
    return _amortize(principal, rateBp, emi);
  }

  static int _monthlyInterest(int balance, int rateBp) => _round(
    BigInt.from(balance) * BigInt.from(rateBp),
    BigInt.from(10000 * 12),
  );

  static List<PlannedAmount> _amortize(
    int principal,
    int rateBp,
    int emi, {
    int? maxCount,
  }) {
    final result = <PlannedAmount>[];
    var balance = principal;
    while (balance > 0) {
      final interest = _monthlyInterest(balance, rateBp);
      final last =
          balance + interest <= emi ||
          (maxCount != null && result.length == maxCount - 1);
      final principalPart = last ? balance : emi - interest;
      result.add((principalMinor: principalPart, interestMinor: interest));
      balance -= principalPart;
      _checkCount(result.length);
    }
    return result;
  }

  /// Interest and instalment count for new terms. Throws [LoanException]
  /// when the terms cannot be repaid (e.g. an instalment that does not even
  /// cover the monthly interest).
  static LoanQuote quote({
    required int principalMinor,
    required int interestRateBp,
    required LoanRepaymentType type,
    required DateTime lentDate,
    InterestMethod method = InterestMethod.flat,
    int? installmentMinor,
    int? months,
    DateTime? dueDate,
  }) {
    if (principalMinor <= 0) {
      throw const LoanException('The amount must be greater than zero.');
    }
    _checkRate(interestRateBp);
    switch (type) {
      case LoanRepaymentType.oneTime:
        if (dueDate == null) {
          throw const LoanException('Choose the expected repayment date.');
        }
        return (
          interestMinor: oneTimeInterest(
            principalMinor,
            interestRateBp,
            lentDate,
            dueDate,
          ),
          installmentCount: 1,
        );
      case LoanRepaymentType.monthly:
        final plan = planMonthly(
          principalMinor: principalMinor,
          method: method,
          rateBp: interestRateBp,
          months: months,
          installmentMinor: installmentMinor,
        );
        return (
          interestMinor: plan.fold(0, (s, p) => s + p.interestMinor),
          installmentCount: plan.length,
        );
    }
  }

  /// Simple interest from [lentDate] to [dueDate].
  static int oneTimeInterest(
    int principalMinor,
    int rateBp,
    DateTime lentDate,
    DateTime dueDate,
  ) {
    final days = PeriodUtils.daysBetween(
      PeriodUtils.dateOnly(lentDate),
      PeriodUtils.dateOnly(dueDate),
    );
    return rateBp == 0 || days <= 0
        ? 0
        : _round(
            BigInt.from(principalMinor) *
                BigInt.from(rateBp) *
                BigInt.from(days),
            BigInt.from(10000 * 365),
          );
  }

  /// Monthly instalment and interest when the borrower repays in [months]
  /// instalments with [method]. Throws [LoanException] when [months] is out
  /// of range or the amount is too small to spread over that many months.
  static ({int installmentMinor, int interestMinor}) quoteForMonths({
    required int principalMinor,
    required int interestRateBp,
    required int months,
    InterestMethod method = InterestMethod.flat,
  }) {
    final plan = planMonthly(
      principalMinor: principalMinor,
      method: method,
      rateBp: interestRateBp,
      months: months,
    );
    if (plan.length != months) {
      throw const LoanException(
        'The amount is too small to spread over that many months.',
      );
    }
    final first = plan.first;
    return (
      installmentMinor: first.principalMinor + first.interestMinor,
      interestMinor: plan.fold(0, (s, p) => s + p.interestMinor),
    );
  }

  /// Builds the schedule of a loan: [kept] instalments first (those that
  /// already received money; they never change), then new instalments for
  /// the capital they do not cover.
  ///
  /// Monthly loans repay that capital with [method] at [interestRateBp],
  /// over [months] instalments or at [installmentMinor] a month, from
  /// [firstDueDate] on [dueDay]. One-time loans get one instalment due on
  /// [dueDate] for the capital plus [oneTimeInterestMinor]. No instalment is
  /// created beyond what is owed. Throws [LoanException] when [kept]
  /// already covers more capital than [principalMinor].
  static List<LoanInstallment> buildSchedule({
    required String loanId,
    required LoanRepaymentType type,
    required int principalMinor,
    required String Function() newId,
    InterestMethod method = InterestMethod.flat,
    int interestRateBp = 0,
    List<LoanInstallment> kept = const [],
    int? installmentMinor,
    int? months,
    DateTime? firstDueDate,
    int? dueDay,
    DateTime? dueDate,
    int oneTimeInterestMinor = 0,
  }) {
    final sortedKept = [...kept]..sort((a, b) => a.number.compareTo(b.number));
    final keptPrincipal = sortedKept.fold<int>(
      0,
      (s, i) => s + i.principalMinor,
    );
    final remaining = principalMinor - keptPrincipal;
    if (remaining < 0) {
      throw const LoanException(
        'The amount lent cannot be less than what the instalments that have '
        'already been (partly) paid cover.',
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
            expectedMinor: remaining + oneTimeInterestMinor,
            interestMinor: oneTimeInterestMinor,
          ),
        );
      case LoanRepaymentType.monthly:
        final first = firstDueDate;
        if (first == null) {
          throw const LoanException('Choose the first repayment date.');
        }
        final plan = planMonthly(
          principalMinor: remaining,
          method: method,
          rateBp: interestRateBp,
          months: months,
          installmentMinor: installmentMinor,
        );
        final day = dueDay ?? first.day;
        for (var index = 0; index < plan.length; index++) {
          final p = plan[index];
          result.add(
            LoanInstallment(
              id: newId(),
              loanId: loanId,
              number: number++,
              dueDate: monthlyDueDate(first, day, index),
              expectedMinor: p.principalMinor + p.interestMinor,
              interestMinor: p.interestMinor,
            ),
          );
        }
        _checkCount(result.length);
    }
    return result;
  }

  /// Instalments of [snapshot] that have received money: they are kept as
  /// they are (extra capital included) when the rest of the schedule is
  /// recalculated.
  static List<LoanInstallment> settledInstallments(LoanSnapshot snapshot) => [
    for (final i in snapshot.installments)
      if (i.receivedMinor > 0)
        i.installment.copyWith(interestMinor: i.interestMinor),
  ];

  // ------------------------------------------------------------ snapshot

  /// [loan] with its [repayments] applied at [now].
  ///
  /// Repayments are applied in date order to the first instalment that is
  /// not fully paid. For monthly loans, whatever a repayment brings above
  /// that instalment reduces the capital: it is added to the instalment as
  /// extra principal and the later instalments are recalculated from the
  /// reduced capital over the same number of months (keeping their IDs and
  /// due dates, so reminders follow). One-time loans have a single
  /// instalment that takes every repayment.
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
    final today = PeriodUtils.dateOnly(now);
    final schedule = _withInterestSplit(loan);

    final expected = [for (final i in schedule) i.expectedMinor];
    final interest = [for (final i in schedule) i.interestMinor ?? 0];
    final extra = List<int>.filled(schedule.length, 0);
    final received = List<int>.filled(schedule.length, 0);
    final ids = List.generate(schedule.length, (_) => <String>[]);
    var count = schedule.length;
    var index = 0;

    for (final r in counted) {
      var left = r.amountMinor;
      while (left > 0 && index < count) {
        final need = expected[index] - received[index];
        final take = left < need ? left : need;
        if (take > 0) {
          received[index] += take;
          ids[index].add(r.id);
          left -= take;
        }
        if (received[index] < expected[index]) break;
        if (left > 0 && loan.isMonthly) {
          // Above the instalment: straight off the capital.
          var principalAfter = loan.principalMinor;
          for (var k = 0; k <= index; k++) {
            principalAfter -= expected[k] - interest[k];
          }
          final toCapital = left < principalAfter ? left : principalAfter;
          if (toCapital > 0) {
            expected[index] += toCapital;
            received[index] += toCapital;
            extra[index] += toCapital;
            left -= toCapital;
            principalAfter -= toCapital;
            count = _recalculateTail(
              loan,
              index,
              count,
              principalAfter,
              expected,
              interest,
            );
          }
          // Anything beyond the capital is not owed and does not count.
          left = 0;
        }
        index++;
      }
    }

    final views = <InstallmentView>[];
    var overdue = 0;
    var overduePrincipal = 0;
    var totalInterest = 0;
    var interestPaid = 0;
    var receivedTotal = 0;
    final derived = <LoanInstallment>[];
    for (var k = 0; k < count; k++) {
      final inst = schedule[k].copyWith(
        expectedMinor: expected[k],
        interestMinor: interest[k],
      );
      derived.add(inst);
      final status = statusOf(
        dueDate: inst.dueDate,
        expectedMinor: expected[k],
        receivedMinor: received[k],
        today: today,
      );
      final view = InstallmentView(
        installment: inst,
        receivedMinor: received[k],
        status: status,
        repaymentIds: List.unmodifiable(ids[k]),
        interestMinor: interest[k],
        extraPrincipalMinor: extra[k],
      );
      if (status == InstallmentStatus.overdue) {
        overdue += view.remainingMinor;
        overduePrincipal += view.principalMinor - view.principalPaidMinor;
      }
      totalInterest += interest[k];
      interestPaid += view.interestPaidMinor;
      receivedTotal += received[k];
      views.add(view);
    }
    // Repayments recorded beyond the schedule (rare: e.g. a backdated
    // repayment after a refused one) still count as received.
    final allReceived = counted.fold<int>(0, (s, r) => s + r.amountMinor);
    final derivedLoan = loan.copyWith(
      receivedMinor: allReceived < receivedTotal ? receivedTotal : allReceived,
      interestMinor: totalInterest,
      schedule: List.unmodifiable(derived),
    );
    final principalPaid = receivedTotal - interestPaid;

    InstallmentView? current;
    var principalAfterCurrent = 0;
    for (final v in views) {
      if (current != null) {
        principalAfterCurrent += v.principalMinor - v.principalPaidMinor;
      } else if (!v.isPaid) {
        current = v;
      }
    }
    final settlement = current == null
        ? 0
        : (loan.isMonthly
              ? current.remainingMinor + principalAfterCurrent
              : current.remainingMinor);

    final LoanStatus status;
    if (receivedTotal >= derivedLoan.totalOwedMinor && current == null) {
      status = LoanStatus.completed;
    } else if (overdue > 0) {
      status = LoanStatus.overdue;
    } else {
      status = LoanStatus.active;
    }
    return LoanSnapshot(
      loan: derivedLoan.copyWith(
        installmentMinor: () =>
            loan.isMonthly ? _currentEmi(views) ?? loan.installmentMinor : null,
      ),
      installments: List.unmodifiable(views),
      status: status,
      principalReceivedMinor: principalPaid,
      interestReceivedMinor: interestPaid,
      overdueMinor: status == LoanStatus.completed ? 0 : overdue,
      overduePrincipalMinor: status == LoanStatus.completed
          ? 0
          : overduePrincipal,
      settlementMinor: settlement,
    );
  }

  /// The regular EMI now asked for: the first unpaid instalment with
  /// nothing received yet (otherwise the partly paid current one).
  static int? _currentEmi(List<InstallmentView> views) {
    InstallmentView? partial;
    for (final v in views) {
      if (v.isPaid) continue;
      if (v.receivedMinor == 0) return v.scheduledMinor;
      partial ??= v;
    }
    return partial?.scheduledMinor;
  }

  /// Recalculates the instalments after [index] from [principal] over the
  /// same number of months, keeping their IDs and due dates. Returns the
  /// new instalment count (smaller only when the capital is gone, or too
  /// small to spread).
  static int _recalculateTail(
    Loan loan,
    int index,
    int count,
    int principal,
    List<int> expected,
    List<int> interest,
  ) {
    final months = count - index - 1;
    if (principal <= 0 || months <= 0) return index + 1;
    final plan = planMonthly(
      principalMinor: principal,
      method: loan.interestMethod,
      rateBp: loan.interestRateBp,
      months: months,
    );
    for (var k = 0; k < plan.length; k++) {
      expected[index + 1 + k] = plan[k].principalMinor + plan[k].interestMinor;
      interest[index + 1 + k] = plan[k].interestMinor;
    }
    return index + 1 + plan.length;
  }

  /// The schedule with every instalment's interest part known. Older
  /// records without it get the loan's interest in proportion to their
  /// amounts.
  static List<LoanInstallment> _withInterestSplit(Loan loan) {
    final sorted = [...loan.schedule]
      ..sort((a, b) => a.number.compareTo(b.number));
    if (sorted.every((i) => i.interestMinor != null)) return sorted;
    final total = sorted.fold<int>(0, (s, i) => s + i.expectedMinor);
    var cumulative = 0;
    var interestSoFar = 0;
    return [
      for (final i in sorted)
        () {
          cumulative += i.expectedMinor;
          final interestCumulative = total == 0
              ? 0
              : _round(
                  BigInt.from(loan.interestMinor) * BigInt.from(cumulative),
                  BigInt.from(total),
                );
          final part = interestCumulative - interestSoFar;
          interestSoFar = interestCumulative;
          return i.copyWith(
            interestMinor: part.clamp(0, i.expectedMinor).toInt(),
          );
        }(),
    ];
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

  /// How [amountMinor] paid on [date] would be applied to the loan of
  /// [before] (repayments so far) and what the loan looks like after it
  /// ([after], with the repayment). Used to show and record the treatment.
  static RepaymentAllocation allocation({
    required LoanSnapshot before,
    required LoanSnapshot after,
    required int amountMinor,
    required DateTime now,
  }) {
    InstallmentView? current;
    var currentIndex = -1;
    for (var k = 0; k < before.installments.length; k++) {
      if (!before.installments[k].isPaid) {
        current = before.installments[k];
        currentIndex = k;
        break;
      }
    }
    final remainingCurrent = current?.remainingMinor ?? 0;
    final applied = amountMinor < remainingCurrent
        ? amountMinor
        : remainingCurrent;
    final interestLeft = current == null
        ? 0
        : current.interestMinor - current.interestPaidMinor;
    final interestPortion = applied < interestLeft ? applied : interestLeft;
    // Capital repaid beyond the instalment's own principal part.
    final principalNow =
        after.principalReceivedMinor - before.principalReceivedMinor;
    final extraRaw = principalNow - (applied - interestPortion);
    final extra = before.loan.isMonthly && extraRaw > 0 ? extraRaw : 0;
    InstallmentView? next(LoanSnapshot s) =>
        currentIndex >= 0 && currentIndex + 1 < s.installments.length
        ? s.installments[currentIndex + 1]
        : null;
    final nextBefore = next(before);
    final nextAfter = next(after);
    return RepaymentAllocation(
      installmentNumber: current?.number,
      scheduledEmiMinor: current?.scheduledMinor ?? 0,
      appliedToInstallmentMinor: applied,
      interestPortionMinor: interestPortion,
      principalPortionMinor: applied - interestPortion,
      extraPrincipalMinor: extra,
      principalBeforeMinor: before.outstandingPrincipalMinor,
      principalAfterMinor: after.outstandingPrincipalMinor,
      previousEmiMinor: nextBefore?.scheduledMinor,
      revisedEmiMinor: nextAfter?.scheduledMinor,
      remainingInstallments: after.remainingInstallments,
      recalculatedAt: now,
      effectiveFrom: extra > 0 ? nextAfter?.dueDate : null,
    );
  }

  /// The principal part of [amountMinor] received on a loan of
  /// [principalMinor] that owes [totalOwedMinor] in total, in proportion.
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
      outstanding += s.outstandingMinor;
      outstandingPrincipal += s.outstandingPrincipalMinor;
      overdue += s.overdueMinor;
      overduePrincipal += s.overduePrincipalMinor;
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
