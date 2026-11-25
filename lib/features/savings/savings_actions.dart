import 'package:flutter/material.dart';

import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/features/savings/screens/goal_details_screen.dart';
import 'package:money_mate/features/savings/screens/goal_form_screen.dart';
import 'package:money_mate/features/savings/screens/savings_screen.dart';
import 'package:money_mate/features/savings/widgets/money_entry_sheet.dart';
import 'package:money_mate/features/savings/widgets/shared_goal_widgets.dart';

/// Opens the Savings screen on the tab of [ownership].
Future<void> openSavingsScreen(
  BuildContext context, {
  SavingsOwnership ownership = SavingsOwnership.personal,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => SavingsScreen(initialOwnership: ownership),
  ),
);

/// Opens the form to create a goal of [ownership], or to edit [goal].
Future<void> openGoalForm(
  BuildContext context, {
  SavingsGoal? goal,
  SavingsOwnership ownership = SavingsOwnership.personal,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => GoalFormScreen(goal: goal, initialOwnership: ownership),
  ),
);

/// Opens [goal]'s details and history.
Future<void> openGoalDetails(BuildContext context, SavingsGoal goal) =>
    openGoalDetailsById(context, goal.id);

/// Opens the details of the goal with [goalId] (e.g. from a notification);
/// the screen says so when the goal no longer exists.
Future<void> openGoalDetailsById(BuildContext context, String goalId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GoalDetailsScreen(goalId: goalId),
      ),
    );

/// Asks for a contribution ([SavingsEntryType.deposit]) or withdrawal and
/// records it. [goal] preselects the goal; otherwise the user picks one of
/// the goals of [ownership].
Future<void> showMoneySheet(
  BuildContext context, {
  required SavingsEntryType type,
  SavingsGoal? goal,
  SavingsOwnership? ownership,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => MoneyEntrySheet(
    type: type,
    initialGoal: goal,
    ownership: ownership ?? goal?.ownership ?? SavingsOwnership.personal,
  ),
);

/// Asks for a shared-goal invitation code and joins the goal.
Future<void> showJoinWithCode(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const JoinWithCodeDialog(),
);
