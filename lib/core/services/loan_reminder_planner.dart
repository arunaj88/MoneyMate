import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/core/utils/money.dart';
import 'package:money_mate/models/loan_model.dart';

/// A repayment reminder this device should have scheduled.
@immutable
class PlannedReminder {
  const PlannedReminder({
    required this.id,
    required this.fireAt,
    required this.title,
    required this.body,
    required this.loanId,
    required this.installmentId,
    required this.offsetDays,
    this.householdId,
  });

  /// Stable notification ID (see [LoanReminderPlanner.stableId]): the same
  /// reminder always gets the same ID, so scheduling it again replaces it
  /// instead of adding a duplicate.
  final int id;

  /// Local wall-clock time it should appear.
  final DateTime fireAt;
  final String title;
  final String body;
  final String loanId;
  final String installmentId;
  final int offsetDays;
  final String? householdId;

  /// What a tap hands back to the app (see `NotificationTarget.fromData`).
  Map<String, String> get data => {
    'type': LoanReminderPlanner.payloadType,
    'loanId': loanId,
    'installmentId': installmentId,
    'householdId': ?householdId,
  };

  @override
  bool operator ==(Object other) =>
      other is PlannedReminder &&
      other.id == id &&
      other.fireAt == fireAt &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(id, fireAt, title, body);

  @override
  String toString() => 'PlannedReminder($id at $fireAt: $body)';
}

/// Works out which repayment reminders one user's device should show.
///
/// Reminders are local notifications: each device schedules only its own
/// user's reminders, from the loans and reminder settings it has synced.
/// That is how household recipients work across devices: the owner's
/// recipient list travels with the household's data, and every member's
/// device schedules reminders only when that member is on the list.
///
/// For each unpaid instalment one reminder is planned per configured
/// offset (by default 3 days before, on the day, and 1, 3 and 7 days
/// after), at [reminderHour] local time. Reminders reflect what is still
/// unpaid of the instalment. Only the next [horizonDays] days are planned
/// and at most [maxReminders] (iOS keeps 64 pending notifications per app);
/// the plan is refreshed whenever the app starts or resumes, so later
/// reminders are added as time passes.
class LoanReminderPlanner {
  LoanReminderPlanner._();

  static const String payloadType = 'loan_reminder';
  static const int reminderHour = 9;
  static const int horizonDays = 60;
  static const int maxReminders = 48;

  /// FNV-1a hash of the loan, instalment, recipient and offset, kept in
  /// the positive 31-bit range notification IDs use. It does not depend on
  /// `String.hashCode`, so it is the same on every run.
  static int stableId(
    String loanId,
    String installmentId,
    String uid,
    int offsetDays,
  ) {
    var hash = 0x811c9dc5;
    for (final unit
        in '$payloadType|$loanId|$installmentId|$uid|$offsetDays'.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash & 0x7fffffff;
  }

  /// Whether [uid]'s device should remind about [loan]: always for the
  /// owner of a personal loan; for a household loan only when the
  /// household owner selected [uid] and [uid] is still an active member.
  static bool isRecipient(
    Loan loan,
    LoanReminderSettings settings,
    String uid, {
    required Set<String> activeMembers,
  }) {
    if (loan.isPersonal) return true;
    return settings.notifyUids.contains(uid) && activeMembers.contains(uid);
  }

  static List<PlannedReminder> plan({
    required Iterable<LoanSnapshot> loans,
    required Map<String, LoanReminderSettings> settings,
    required String uid,
    required bool Function(Loan loan, LoanReminderSettings settings) recipient,
    required CurrencyFormatter formatter,
    required DateTime now,
  }) {
    final horizon = now.add(const Duration(days: horizonDays));
    final planned = <PlannedReminder>[];
    for (final snapshot in loans) {
      if (snapshot.isCompleted) continue;
      final loan = snapshot.loan;
      final config =
          settings[loan.id] ??
          LoanReminderSettings(loanId: loan.id, updatedAt: loan.createdAt);
      if (!config.isActive || !recipient(loan, config)) continue;
      for (final installment in snapshot.installments) {
        if (installment.isPaid) continue;
        final due = PeriodUtils.dateOnly(installment.dueDate);
        for (final offset in config.offsets) {
          final fireAt = DateTime(
            due.year,
            due.month,
            due.day + offset,
            reminderHour,
          );
          if (!fireAt.isAfter(now) || fireAt.isAfter(horizon)) continue;
          final text = describe(
            loan: loan,
            installment: installment,
            offsetDays: offset,
            formatter: formatter,
          );
          planned.add(
            PlannedReminder(
              id: stableId(loan.id, installment.id, uid, offset),
              fireAt: fireAt,
              title: text.title,
              body: text.body,
              loanId: loan.id,
              installmentId: installment.id,
              offsetDays: offset,
              householdId: loan.householdId,
            ),
          );
        }
      }
    }
    planned.sort((a, b) {
      final byTime = a.fireAt.compareTo(b.fireAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return planned.length > maxReminders
        ? planned.sublist(0, maxReminders)
        : planned;
  }

  /// Title and text of a reminder [offsetDays] from [installment]'s due
  /// date, e.g. "John has an EMI of AED 1,000.00 due tomorrow."
  static ({String title, String body}) describe({
    required Loan loan,
    required InstallmentView installment,
    required int offsetDays,
    required CurrencyFormatter formatter,
  }) {
    final name = loan.borrowerName.trim();
    final noun = loan.isMonthly ? 'an EMI' : 'a repayment';
    final remaining = formatter.format(installment.remainingMinor);
    final expected = formatter.format(installment.expectedMinor);
    final partial = installment.receivedMinor > 0;
    final amount = partial
        ? '$remaining left of $noun of $expected'
        : '$noun of $remaining';
    final dueLabel = DateFormat('EEE, d MMM').format(installment.dueDate);
    final household = loan.isHousehold ? ' (household)' : '';
    if (offsetDays <= 0) {
      final when = switch (offsetDays) {
        0 => 'today',
        -1 => 'tomorrow',
        _ => 'in ${-offsetDays} days ($dueLabel)',
      };
      return (
        title: offsetDays == 0 ? 'Repayment due today' : 'Repayment reminder',
        body: '$name has $amount due $when.$household',
      );
    }
    final ago = offsetDays == 1 ? 'yesterday' : '$offsetDays days ago';
    return (
      title: 'Repayment overdue',
      body:
          '$name still owes $amount that was due $ago ($dueLabel).'
          '$household',
    );
  }
}
