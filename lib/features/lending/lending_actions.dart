import 'package:flutter/material.dart';

import 'package:money_mate/features/lending/screens/borrower_screen.dart';
import 'package:money_mate/features/lending/screens/lending_screen.dart';
import 'package:money_mate/features/lending/screens/loan_details_screen.dart';
import 'package:money_mate/features/lending/screens/loan_form_screen.dart';
import 'package:money_mate/features/lending/screens/loan_statement_screen.dart';
import 'package:money_mate/features/lending/screens/reminder_settings_screen.dart';
import 'package:money_mate/features/lending/widgets/repayment_sheet.dart';
import 'package:money_mate/models/loan_model.dart';
import 'package:money_mate/providers/loan_provider.dart';

/// Opens the Money lent overview.
Future<void> openLendingScreen(
  BuildContext context, {
  LoanFilter filter = LoanFilter.all,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(builder: (_) => LendingScreen(initialFilter: filter)),
);

/// Opens the form to record money lent, or to edit [snapshot]'s loan.
Future<void> openLoanForm(
  BuildContext context, {
  LoanSnapshot? snapshot,
  bool household = false,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) =>
        LoanFormScreen(snapshot: snapshot, initialHousehold: household),
  ),
);

/// Opens a lending record (e.g. from a reminder). [installmentId] is
/// highlighted in the schedule and preselected for a repayment. The screen
/// says so when the record no longer exists.
Future<void> openLoanDetails(
  BuildContext context,
  String loanId, {
  String? installmentId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        LoanDetailsScreen(loanId: loanId, installmentId: installmentId),
  ),
);

/// Opens the statement of [loanId] to review and share with the borrower.
Future<void> openLoanStatement(BuildContext context, String loanId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LoanStatementScreen(loanId: loanId),
      ),
    );

/// Opens every loan of one borrower.
Future<void> openBorrower(BuildContext context, String borrowerKey) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BorrowerScreen(borrowerKey: borrowerKey),
      ),
    );

/// Opens the reminder settings (and household recipients) of [loanId].
Future<void> openReminderSettings(BuildContext context, String loanId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReminderSettingsScreen(loanId: loanId),
      ),
    );

/// Asks for a repayment of [snapshot]'s loan (optionally towards
/// [installment]) and records it.
Future<void> showRepaymentSheet(
  BuildContext context,
  LoanSnapshot snapshot, {
  InstallmentView? installment,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) =>
      RepaymentSheet(loanId: snapshot.id, installmentId: installment?.id),
);

/// Changes the unpaid part of [snapshot]'s schedule.
Future<void> showRescheduleSheet(BuildContext context, LoanSnapshot snapshot) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => RescheduleSheet(loanId: snapshot.id),
    );
