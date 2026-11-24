import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/notification_events.dart';
import 'package:money_mate/models/budget_model.dart';
import 'package:money_mate/models/transaction_model.dart';
import 'package:money_mate/providers/budget_provider.dart';

import '../helpers/fakes.dart';

void main() {
  // Wednesday 25 Nov 2026; week = Mon 23 – Sun 29 Nov.
  final now = DateTime(2026, 11, 25, 10);

  late InMemoryTransactionRepository transactions;
  late InMemoryBudgetRepository budgets;
  late InMemoryAppSettingsRepository appSettings;
  late BudgetProvider provider;

  setUp(() {
    transactions = InMemoryTransactionRepository();
    budgets = InMemoryBudgetRepository();
    appSettings = InMemoryAppSettingsRepository();
    provider = BudgetProvider(
      budgetRepository: budgets,
      transactionRepository: transactions,
      appSettingsRepository: appSettings,
      clock: () => now,
    );
  });

  test('weekly and monthly targets are independent', () async {
    await provider.setTarget(BudgetPeriod.weekly, 50000);
    await provider.setTarget(BudgetPeriod.monthly, 200000);
    expect(provider.weekly!.targetMinor, 50000);
    expect(provider.monthly!.targetMinor, 200000);

    await provider.removeTarget(BudgetPeriod.weekly);
    expect(provider.weekly!.hasTarget, isFalse);
    expect(provider.monthly!.targetMinor, 200000);
  });

  test(
    'the same expense counts toward both week and month; income never',
    () async {
      transactions.items.addAll([
        tx(id: 'e1', amountMinor: 10000, date: DateTime(2026, 11, 24)),
        // Earlier in the month but a previous week.
        tx(id: 'e2', amountMinor: 30000, date: DateTime(2026, 11, 10)),
        tx(
          id: 'i1',
          amountMinor: 900000,
          date: DateTime(2026, 11, 24),
          type: TransactionType.income,
          categoryId: 'inc_salary',
        ),
      ]);
      await provider.setTarget(BudgetPeriod.weekly, 20000);
      await provider.setTarget(BudgetPeriod.monthly, 80000);

      expect(provider.weekly!.spentMinor, 10000);
      expect(provider.weekly!.remainingMinor, 10000);
      expect(provider.weekly!.usagePercent, 50);
      expect(provider.monthly!.spentMinor, 40000);
      expect(provider.monthly!.usagePercent, 50);
    },
  );

  test('history keeps the target that applied to each period', () async {
    // Target set "last week" via a direct repository version.
    await budgets.setTarget(
      period: BudgetPeriod.weekly,
      amountMinor: 30000,
      effectiveFrom: DateTime(2026, 11, 16),
    );
    transactions.items.add(
      tx(id: 'past', amountMinor: 33000, date: DateTime(2026, 11, 18)),
    );
    await provider.setTarget(BudgetPeriod.weekly, 50000);

    final history = provider.weeklyHistory;
    expect(history.first.range.start, DateTime(2026, 11, 23));
    expect(history.first.targetMinor, 50000);
    expect(history[1].range.start, DateTime(2026, 11, 16));
    expect(history[1].targetMinor, 30000);
    expect(history[1].spentMinor, 33000);
    expect(history[1].alertLevel, BudgetAlertLevel.exceeded);
    expect(history[2].hasTarget, isFalse);
  });

  test('alerts fire once per threshold per period', () async {
    await provider.setTarget(BudgetPeriod.weekly, 10000);
    expect(provider.takePendingAlerts(), isEmpty);

    transactions.items.add(
      tx(id: 'a', amountMinor: 8000, date: DateTime(2026, 11, 24)),
    );
    await provider.refresh();
    final first = provider.takePendingAlerts();
    expect(first.single.level, BudgetAlertLevel.approaching);

    // Refreshing again must not repeat the same alert.
    await provider.refresh();
    await provider.refresh();
    expect(provider.takePendingAlerts(), isEmpty);

    transactions.items.add(
      tx(id: 'b', amountMinor: 1000, date: DateTime(2026, 11, 24)),
    );
    await provider.refresh();
    expect(provider.takePendingAlerts().single.level, BudgetAlertLevel.warning);

    transactions.items.add(
      tx(id: 'c', amountMinor: 1000, date: DateTime(2026, 11, 25)),
    );
    await provider.refresh();
    final exceeded = provider.takePendingAlerts().single;
    expect(exceeded.level, BudgetAlertLevel.exceeded);
    expect(exceeded.title, 'Budget exceeded');

    // A new provider instance (app restart) still remembers.
    final restarted = BudgetProvider(
      budgetRepository: budgets,
      transactionRepository: transactions,
      appSettingsRepository: appSettings,
      clock: () => now,
    );
    await restarted.refresh();
    expect(restarted.takePendingAlerts(), isEmpty);
  });

  test('new alerts also reach the notification sink', () async {
    final sink = _RecordingSink();
    final notifying = BudgetProvider(
      budgetRepository: budgets,
      transactionRepository: transactions,
      appSettingsRepository: appSettings,
      alertSink: sink,
      clock: () => now,
    );
    await notifying.setTarget(BudgetPeriod.weekly, 10000);
    transactions.items.add(
      tx(id: 'a', amountMinor: 9500, date: DateTime(2026, 11, 24)),
    );
    await notifying.refresh();
    await pumpEventQueue();

    final event = sink.events.single;
    expect(event.local!.level, BudgetAlertLevel.warning);
    expect(event.local!.message, contains('95%'));
    // Personal budgets are never shared.
    expect(event.household, isNull);

    await notifying.refresh();
    await pumpEventQueue();
    expect(sink.events, hasLength(1));
  });

  test('category budgets track spending in their category only', () async {
    transactions.items.addAll([
      tx(id: 'f1', amountMinor: 45000, date: DateTime(2026, 11, 5)),
      tx(
        id: 'g1',
        amountMinor: 99000,
        date: DateTime(2026, 11, 6),
        categoryId: 'exp_groceries',
      ),
    ]);
    await provider.saveCategoryBudget(
      categoryId: 'exp_food',
      period: BudgetPeriod.monthly,
      amountMinor: 50000,
    );
    final food = provider.categoryStatusesFor(BudgetPeriod.monthly).single;
    expect(food.status.spentMinor, 45000);
    expect(food.status.remainingMinor, 5000);
    expect(food.status.usagePercent, 90);

    // Updating replaces rather than duplicating.
    await provider.saveCategoryBudget(
      id: food.budget.id,
      categoryId: 'exp_food',
      period: BudgetPeriod.monthly,
      amountMinor: 90000,
    );
    expect(provider.categoryStatusesFor(BudgetPeriod.monthly).length, 1);
    expect(
      provider
          .categoryStatusesFor(BudgetPeriod.monthly)
          .single
          .status
          .usagePercent,
      50,
    );
  });

  test('rejects non-positive targets', () {
    expect(
      () => provider.setTarget(BudgetPeriod.weekly, 0),
      throwsArgumentError,
    );
  });
}

class _RecordingSink implements BudgetAlertSink {
  final List<BudgetAlertEvent> events = [];

  @override
  Future<void> budgetAlertRaised(BudgetAlertEvent event) async =>
      events.add(event);
}
