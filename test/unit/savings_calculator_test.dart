import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/savings_calculator.dart';
import 'package:money_mate/models/savings_model.dart';

SavingsGoal goal({
  String id = 'g',
  int target = 10000,
  int saved = 0,
  SavingsGoalStatus status = SavingsGoalStatus.active,
  DateTime? firstEntry,
  DateTime? targetDate,
  SavingsPurpose purpose = SavingsPurpose.trip,
  String custom = '',
}) => SavingsGoal(
  id: id,
  name: 'Goal $id',
  purpose: purpose,
  customPurpose: custom,
  targetMinor: target,
  targetDate: targetDate,
  status: status,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  savedMinor: saved,
  firstEntryDate: firstEntry,
);

void main() {
  final now = DateTime(2026, 11, 24, 10);

  group('SavingsGoal', () {
    test('progress, percent and remaining', () {
      final g = goal(target: 20000, saved: 5000);
      expect(g.progress, 0.25);
      expect(g.percent, 25);
      expect(g.remainingMinor, 15000);
      expect(g.targetReached, isFalse);

      final over = goal(target: 10000, saved: 12500);
      expect(over.progress, 1.0);
      expect(over.percent, 125);
      expect(over.remainingMinor, 0);
      expect(over.targetReached, isTrue);
    });

    test('custom purpose label only for Other', () {
      expect(
        goal(purpose: SavingsPurpose.other, custom: 'Wedding').purposeLabel,
        'Wedding',
      );
      expect(goal(purpose: SavingsPurpose.other).purposeLabel, 'Other');
      expect(goal(purpose: SavingsPurpose.gold).purposeLabel, 'Gold');
    });

    test('unknown purpose and status fall back safely', () {
      expect(SavingsPurpose.fromName('spaceship'), SavingsPurpose.other);
      expect(SavingsGoalStatus.fromName(null), SavingsGoalStatus.active);
    });

    test('database and cloud round trips', () {
      final g = goal(targetDate: DateTime(2027, 6, 1), custom: 'x');
      final fromDb = SavingsGoal.fromMap(g.toMap());
      expect(fromDb.toMap(), g.toMap());

      final fromCloud = SavingsGoal.fromCloudMap(
        g.id,
        g.toCloudMap(),
        g.updatedAt.millisecondsSinceEpoch,
      )!;
      expect(fromCloud.toMap(), g.toMap());

      expect(
        SavingsGoal.fromCloudMap('x', {...g.toCloudMap(), 'targetMinor': 0}, 1),
        isNull,
      );
    });

    test('entry cloud parsing rejects invalid documents', () {
      final e = SavingsEntry(
        id: 'e',
        goalId: 'g',
        type: SavingsEntryType.withdrawal,
        amountMinor: 500,
        date: DateTime(2026, 5, 1),
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 5, 1),
      );
      final parsed = SavingsEntry.fromCloudMap('e', e.toCloudMap(), 7)!;
      expect(parsed.signedMinor, -500);
      expect(parsed.updatedAt.millisecondsSinceEpoch, 7);
      expect(
        SavingsEntry.fromCloudMap('e', {...e.toCloudMap(), 'type': 'x'}, 1),
        isNull,
      );
      expect(
        SavingsEntry.fromCloudMap('e', {
          ...e.toCloudMap(),
          'amountMinor': -1,
        }, 1),
        isNull,
      );
    });
  });

  group('summarize', () {
    test('totals across goals; remaining counts active goals only', () {
      final summary = SavingsCalculator.summarize([
        goal(id: 'a', target: 10000, saved: 4000),
        goal(id: 'b', target: 5000, saved: 6000), // over-saved
        goal(
          id: 'c',
          target: 8000,
          saved: 1000,
          status: SavingsGoalStatus.paused,
        ),
        goal(
          id: 'd',
          target: 2000,
          saved: 2000,
          status: SavingsGoalStatus.completed,
        ),
      ]);
      expect(summary.totalSavedMinor, 13000);
      expect(summary.totalTargetMinor, 25000);
      expect(summary.remainingActiveMinor, 6000); // a only (b is reached)
      expect(summary.activeCount, 2);
      expect(summary.pausedCount, 1);
      expect(summary.completedCount, 1);
      expect(summary.goalCount, 4);
    });

    test('empty', () {
      final s = SavingsCalculator.summarize(const []);
      expect(s.totalSavedMinor, 0);
      expect(s.overallProgress, 0);
    });
  });

  group('expectedCompletion', () {
    test('projects at the average pace since the first entry', () {
      // 3000 saved over 30 days = 100/day; 7000 left = 70 days.
      final g = goal(
        target: 10000,
        saved: 3000,
        firstEntry: DateTime(2026, 10, 25),
      );
      expect(
        SavingsCalculator.expectedCompletion(g, now),
        DateTime(2026, 11, 24 + 70),
      );
    });

    test('uses at least a week of history', () {
      final g = goal(target: 1400, saved: 700, firstEntry: now);
      // 700 / 7 days = 100/day; 700 left = 7 days.
      expect(
        SavingsCalculator.expectedCompletion(g, now),
        DateTime(2026, 12, 1),
      );
    });

    test('none for paused, reached or empty goals', () {
      final first = DateTime(2026, 1, 1);
      expect(
        SavingsCalculator.expectedCompletion(
          goal(saved: 10, firstEntry: first, status: SavingsGoalStatus.paused),
          now,
        ),
        isNull,
      );
      expect(
        SavingsCalculator.expectedCompletion(
          goal(saved: 10000, firstEntry: first),
          now,
        ),
        isNull,
      );
      expect(SavingsCalculator.expectedCompletion(goal(), now), isNull);
    });

    test('none when the pace is too slow to matter', () {
      final g = goal(
        target: 100000000,
        saved: 1,
        firstEntry: DateTime(2026, 1, 1),
      );
      expect(SavingsCalculator.expectedCompletion(g, now), isNull);
    });
  });

  test('monthlyNeeded spreads the remainder until the target date', () {
    final g = goal(
      target: 12000,
      saved: 0,
      targetDate: DateTime(2027, 11, 24), // 365 days ≈ 12 months
    );
    final monthly = SavingsCalculator.monthlyNeeded(g, now)!;
    expect(monthly, closeTo(1000, 5));
    expect(
      SavingsCalculator.monthlyNeeded(goal(targetDate: DateTime(2026)), now),
      isNull,
    );
    expect(SavingsCalculator.monthlyNeeded(goal(), now), isNull);
  });
}
