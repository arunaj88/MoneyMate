import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/report_models.dart';
import 'package:money_mate/models/savings_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/dashboard_provider.dart';
import 'package:money_mate/providers/savings_provider.dart';

import '../helpers/fakes.dart';

void main() {
  final now = DateTime(2026, 11, 24, 10);

  late InMemorySavingsRepository repo;
  late SavingsProvider provider;

  setUp(() {
    repo = InMemorySavingsRepository();
    provider = SavingsProvider(repo, clock: () => now);
  });

  Future<SavingsGoal> create({int target = 100000, DateTime? targetDate}) =>
      provider.createGoal(
        name: '  Japan trip ',
        purpose: SavingsPurpose.trip,
        targetMinor: target,
        targetDate: targetDate,
      );

  group('goals', () {
    test('create trims input and starts active with nothing saved', () async {
      final goal = await create();
      expect(goal.name, 'Japan trip');
      expect(goal.isActive, isTrue);
      expect(goal.savedMinor, 0);
      expect(provider.summaryOf(SavingsOwnership.personal).activeCount, 1);
      expect(provider.localChangeVersion, 1);
    });

    test('invalid targets, names and dates are refused', () async {
      await expectLater(create(target: 0), throwsA(isA<SavingsException>()));
      await expectLater(create(target: -5), throwsA(isA<SavingsException>()));
      await expectLater(
        provider.createGoal(
          name: '   ',
          purpose: SavingsPurpose.house,
          targetMinor: 100,
        ),
        throwsA(isA<SavingsException>()),
      );
      await expectLater(
        create(targetDate: DateTime(2026, 11, 23)),
        throwsA(isA<SavingsException>()),
      );
      expect(provider.goals, isEmpty);
      expect(provider.localChangeVersion, 0);
    });

    test('custom purpose is kept only for Other', () async {
      final other = await provider.createGoal(
        name: 'Ring',
        purpose: SavingsPurpose.other,
        customPurpose: ' Wedding ',
        targetMinor: 100,
      );
      expect(other.purposeLabel, 'Wedding');
      final gold = await provider.createGoal(
        name: 'Gold',
        purpose: SavingsPurpose.gold,
        customPurpose: 'ignored',
        targetMinor: 100,
      );
      expect(gold.customPurpose, '');
    });

    test('edit, pause, resume, complete, reopen and delete', () async {
      final goal = await create();
      await provider.updateGoal(
        goal,
        name: 'Tokyo',
        purpose: SavingsPurpose.trip,
        targetMinor: 50000,
        notes: 'Spring',
      );
      var current = provider.goalById(goal.id)!;
      expect(current.name, 'Tokyo');
      expect(current.targetMinor, 50000);
      expect(current.notes, 'Spring');
      expect(current.updatedAt.isAfter(goal.updatedAt), isTrue);

      await provider.pauseGoal(current);
      current = provider.goalById(goal.id)!;
      expect(current.isPaused, isTrue);
      expect(provider.summaryOf(SavingsOwnership.personal).pausedCount, 1);

      await provider.resumeGoal(current);
      current = provider.goalById(goal.id)!;
      expect(current.isActive, isTrue);

      await provider.completeGoal(current);
      current = provider.goalById(goal.id)!;
      expect(current.isCompleted, isTrue);
      expect(current.completedAt, now);
      expect(provider.summaryOf(SavingsOwnership.personal).completedCount, 1);

      await provider.resumeGoal(current);
      current = provider.goalById(goal.id)!;
      expect(current.isActive, isTrue);
      expect(current.completedAt, isNull);

      await provider.deleteGoal(current);
      expect(provider.goals, isEmpty);
    });

    test('a past target date may stay when it is not changed', () async {
      final goal = SavingsGoal(
        id: 'old',
        name: 'Old',
        purpose: SavingsPurpose.house,
        targetMinor: 100,
        targetDate: DateTime(2026, 1, 1),
        createdAt: DateTime(2025),
        updatedAt: DateTime(2025),
      );
      repo.goals.add(goal);
      await provider.load();
      await provider.updateGoal(
        goal,
        name: 'Renamed',
        purpose: SavingsPurpose.house,
        targetMinor: 100,
        targetDate: DateTime(2026, 1, 1),
      );
      expect(provider.goalById('old')!.name, 'Renamed');
    });
  });

  group('money', () {
    test('add and withdraw update the goal and totals', () async {
      final goal = await create();
      await provider.addMoney(goal, amountMinor: 30000, date: now);
      expect(provider.goalById(goal.id)!.savedMinor, 30000);
      expect(provider.personalSavedMinor, 30000);

      await provider.withdrawMoney(
        provider.goalById(goal.id)!,
        amountMinor: 10000,
        date: now,
        note: 'Visa fee',
      );
      expect(provider.personalSavedMinor, 20000);
      expect(
        provider.summaryOf(SavingsOwnership.personal).remainingActiveMinor,
        80000,
      );
      await provider.loadEntries(goal.id);
      expect(
        provider.entriesFor(goal.id)!.map((e) => e.signedMinor),
        unorderedEquals([30000, -10000]),
      );
    });

    test('a withdrawal larger than the balance is refused', () async {
      final goal = await create();
      await provider.addMoney(goal, amountMinor: 5000, date: now);
      final version = provider.localChangeVersion;
      await expectLater(
        provider.withdrawMoney(
          provider.goalById(goal.id)!,
          amountMinor: 5001,
          date: now,
        ),
        throwsA(isA<SavingsException>()),
      );
      expect(provider.personalSavedMinor, 5000);
      expect(provider.localChangeVersion, version);
    });

    test('invalid amounts and future dates are refused', () async {
      final goal = await create();
      for (final amount in [0, -100]) {
        await expectLater(
          provider.addMoney(goal, amountMinor: amount, date: now),
          throwsA(isA<SavingsException>()),
        );
      }
      await expectLater(
        provider.addMoney(
          goal,
          amountMinor: 100,
          date: now.add(const Duration(days: 1)),
        ),
        throwsA(isA<SavingsException>()),
      );
      expect(repo.entries, isEmpty);
    });

    test('paused and completed goals take no new money', () async {
      final goal = await create();
      await provider.addMoney(goal, amountMinor: 1000, date: now);
      await provider.pauseGoal(provider.goalById(goal.id)!);
      final paused = provider.goalById(goal.id)!;
      await expectLater(
        provider.addMoney(paused, amountMinor: 1, date: now),
        throwsA(isA<SavingsException>()),
      );
      // Money can still be taken back out.
      await provider.withdrawMoney(paused, amountMinor: 400, date: now);
      expect(provider.personalSavedMinor, 600);
    });

    test('deleting a goal returns its money to available', () async {
      final goal = await create();
      await provider.addMoney(goal, amountMinor: 7000, date: now);
      await provider.deleteGoal(provider.goalById(goal.id)!);
      expect(provider.personalSavedMinor, 0);
    });
  });

  group('available balance', () {
    PeriodTotals emptyTotals() => PeriodTotals(
      range: PeriodUtils.monthRange(now),
      incomeMinor: 100000,
      expenseMinor: 20000,
    );

    DashboardData data({required int balance, int saved = 0}) => DashboardData(
      balanceMinor: balance,
      week: emptyTotals(),
      month: emptyTotals(),
      previousWeekExpenseMinor: 0,
      previousMonthExpenseMinor: 0,
      weekDailyExpenses: const [],
      recentTransactions: const <TransactionModel>[],
      monthCategoryShares: const [],
      savedMinor: saved,
    );

    test('allocating moves money from available to savings 1:1', () {
      // Income 1000, expenses 200 => balance 800.
      final before = data(balance: 80000);
      expect(before.availableMinor, 80000);

      final saved = before.withSaved(30000);
      expect(saved.availableMinor, 50000);
      expect(saved.savedMinor, 30000);
      // Balance (income - expenses) and the month's figures are unchanged:
      // a savings allocation is not an expense.
      expect(saved.balanceMinor, 80000);
      expect(saved.month.expenseMinor, before.month.expenseMinor);
      expect(saved.availableMinor + saved.savedMinor, saved.balanceMinor);

      // Withdrawing 100 returns it to available, not as income.
      final withdrawn = saved.withSaved(20000);
      expect(withdrawn.availableMinor, 60000);
      expect(withdrawn.month.incomeMinor, before.month.incomeMinor);
    });
  });
}
