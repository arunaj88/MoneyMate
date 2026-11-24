import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/budget_calculator.dart';
import 'package:money_mate/core/utils/date_range.dart';
import 'package:money_mate/models/budget_model.dart';

void main() {
  final week = PeriodUtils.weekRange(DateTime(2026, 11, 23));

  group('BudgetCalculator formulas', () {
    test('remaining = target - expenses', () {
      expect(BudgetCalculator.remaining(50000, 12550), 37450);
      expect(BudgetCalculator.remaining(50000, 60000), -10000);
    });

    test('usage % = expenses / target * 100', () {
      expect(BudgetCalculator.usagePercent(50000, 25000), 50);
      expect(BudgetCalculator.usagePercent(30000, 33000), closeTo(110, 1e-9));
      expect(BudgetCalculator.usagePercent(0, 100), isNull);
    });
  });

  group('alert levels', () {
    test('thresholds at 80, 90 and 100 percent', () {
      expect(BudgetCalculator.alertLevelFor(null), BudgetAlertLevel.none);
      expect(BudgetCalculator.alertLevelFor(79.99), BudgetAlertLevel.none);
      expect(BudgetCalculator.alertLevelFor(80), BudgetAlertLevel.approaching);
      expect(
        BudgetCalculator.alertLevelFor(89.9),
        BudgetAlertLevel.approaching,
      );
      expect(BudgetCalculator.alertLevelFor(90), BudgetAlertLevel.warning);
      expect(BudgetCalculator.alertLevelFor(99.99), BudgetAlertLevel.warning);
      expect(BudgetCalculator.alertLevelFor(100), BudgetAlertLevel.exceeded);
      expect(BudgetCalculator.alertLevelFor(250), BudgetAlertLevel.exceeded);
    });

    test('levels are ordered', () {
      expect(BudgetAlertLevel.exceeded > BudgetAlertLevel.warning, isTrue);
      expect(BudgetAlertLevel.none < BudgetAlertLevel.approaching, isTrue);
    });
  });

  group('status', () {
    test('with a target', () {
      final s = BudgetCalculator.status(
        period: BudgetPeriod.weekly,
        range: week,
        targetMinor: 50000,
        spentMinor: 45000,
      );
      expect(s.hasTarget, isTrue);
      expect(s.remainingMinor, 5000);
      expect(s.usagePercent, 90);
      expect(s.alertLevel, BudgetAlertLevel.warning);
      expect(s.progress, 0.9);
    });

    test('progress is clamped when over budget', () {
      final s = BudgetCalculator.status(
        period: BudgetPeriod.monthly,
        range: week,
        targetMinor: 1000,
        spentMinor: 1500,
      );
      expect(s.progress, 1);
      expect(s.remainingMinor, -500);
      expect(s.isExceeded, isTrue);
    });

    test('without a target there is no remaining/usage', () {
      final s = BudgetCalculator.status(
        period: BudgetPeriod.weekly,
        range: week,
        targetMinor: null,
        spentMinor: 1200,
      );
      expect(s.hasTarget, isFalse);
      expect(s.remainingMinor, isNull);
      expect(s.usagePercent, isNull);
      expect(s.alertLevel, BudgetAlertLevel.none);
    });
  });

  group('targetFor (historical versions)', () {
    BudgetTarget v(DateTime from, int amount) => BudgetTarget(
      period: BudgetPeriod.monthly,
      amountMinor: amount,
      effectiveFrom: from,
      updatedAt: from,
    );

    final versions = [
      v(DateTime(2026, 9), 200000),
      v(DateTime(2026, 11), 150000),
      v(DateTime(2026, 6), 100000),
    ];

    test('uses latest version effective on or before period start', () {
      expect(BudgetCalculator.targetFor(versions, DateTime(2026, 6)), 100000);
      expect(BudgetCalculator.targetFor(versions, DateTime(2026, 10)), 200000);
      expect(BudgetCalculator.targetFor(versions, DateTime(2026, 11)), 150000);
      expect(BudgetCalculator.targetFor(versions, DateTime(2027, 3)), 150000);
    });

    test('no target before first version', () {
      expect(BudgetCalculator.targetFor(versions, DateTime(2026, 5)), isNull);
    });

    test('a zero version removes the target from then on', () {
      final withRemoval = [...versions, v(DateTime(2026, 12), 0)];
      expect(
        BudgetCalculator.targetFor(withRemoval, DateTime(2026, 12)),
        isNull,
      );
      expect(
        BudgetCalculator.targetFor(withRemoval, DateTime(2026, 11)),
        150000,
      );
    });
  });

  test('daily allowance divides remaining by days left including today', () {
    final s = BudgetCalculator.status(
      period: BudgetPeriod.weekly,
      range: week, // Mon 23 – Sun 29 Nov 2026
      targetMinor: 70000,
      spentMinor: 0,
    );
    expect(BudgetCalculator.dailyAllowance(s, DateTime(2026, 11, 23)), 10000);
    expect(BudgetCalculator.dailyAllowance(s, DateTime(2026, 11, 29)), 70000);
  });
}
