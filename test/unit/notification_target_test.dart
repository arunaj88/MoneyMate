import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/notification_service.dart';
import 'package:money_mate/models/scope_models.dart';

void main() {
  NotificationTarget target(Map<String, String> data) =>
      NotificationTarget.fromData(data);

  test('pushes from the Cloud Functions open what they are about', () {
    expect(
      target({'type': 'household_transaction', 'householdId': 'h1'}),
      const NotificationTarget(
        NotificationDestination.transactions,
        scope: DataScope.household('h1'),
      ),
    );
    for (final type in ['household_member', 'household_removed']) {
      expect(
        target({'type': type, 'householdId': 'h1'}),
        const NotificationTarget(NotificationDestination.household),
      );
    }
    expect(
      target({
        'type': 'household_budget',
        'householdId': 'h1',
        'level': 'exceeded',
      }),
      const NotificationTarget(
        NotificationDestination.budget,
        scope: DataScope.household('h1'),
      ),
    );
    expect(
      target({'type': 'personal_budget'}),
      const NotificationTarget(
        NotificationDestination.budget,
        scope: DataScope.personal(),
      ),
    );
    expect(
      target({'type': 'household_savings', 'goalId': 'g1', 'reached': 'true'}),
      const NotificationTarget(NotificationDestination.goal, goalId: 'g1'),
    );
    expect(
      target({'type': 'shared_goal', 'goalId': 'g2'}),
      const NotificationTarget(NotificationDestination.goal, goalId: 'g2'),
    );
  });

  test('savings pushes without a goal open the right savings tab', () {
    expect(
      target({'type': 'household_savings'}),
      const NotificationTarget(
        NotificationDestination.savings,
        ownership: 'household',
      ),
    );
    expect(
      target({'type': 'shared_goal', 'goalId': ''}),
      const NotificationTarget(
        NotificationDestination.savings,
        ownership: 'shared',
      ),
    );
  });

  test('notifications made on this device go by their channel', () {
    expect(
      target({'channel': 'budget_alerts'}),
      const NotificationTarget(NotificationDestination.budget),
    );
    expect(
      target({'channel': 'recurring'}),
      const NotificationTarget(NotificationDestination.transactions),
    );
    expect(
      target({}),
      const NotificationTarget(NotificationDestination.dashboard),
    );
  });

  test('tap payloads survive the round trip through the system', () {
    const n = AppNotification(
      title: 't',
      body: 'b',
      channel: NotificationChannel.savingsUpdates,
      data: {'type': 'shared_goal', 'goalId': 'g1'},
    );
    expect(
      decodeTapPayload(
        '{"type":"shared_goal","goalId":"g1","channel":"savings_updates"}',
      ),
      n.tapData,
    );
    expect(decodeTapPayload(null), isNull);
    expect(decodeTapPayload('not json'), isNull);
    expect(decodeTapPayload('[1]'), isNull);
  });
}
