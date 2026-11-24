'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const n = require('../src/notify_logic');

const tx = (extra = {}) => ({
  type: 'expense',
  amountMinor: 4550,
  categoryId: 'exp_groceries',
  date: 1,
  note: 'Weekly shop',
  paymentMethod: 'card',
  deleted: false,
  category: { name: 'Groceries' },
  ...extra,
});

test('formatMoney matches the app currency symbols', () => {
  assert.equal(n.formatMoney(4550, 'AED'), 'AED 45.50');
  assert.equal(n.formatMoney(123456789, 'USD'), '$1,234,567.89');
  assert.equal(n.formatMoney(5, 'INR'), '₹0.05');
  assert.equal(n.formatMoney(-2000, 'EUR'), '€20.00');
  // Unknown currencies fall back to the app default.
  assert.equal(n.formatMoney(100, 'XYZ'), 'AED 1.00');
  assert.equal(n.formatMoney(100, undefined), 'AED 1.00');
});

test('truncate and shortName', () => {
  assert.equal(n.truncate('  a   b ', 10), 'a b');
  assert.equal(n.truncate('abcdefghij', 5), 'abcd…');
  assert.equal(n.truncate(null, 5), '');
  assert.equal(n.shortName('Sara Khan'), 'Sara');
  assert.equal(n.shortName('  '), 'Someone');
  assert.equal(n.shortName(null, ''), '');
});

test('transactionChange ignores writes nobody would notice', () => {
  assert.equal(n.transactionChange(undefined, tx()), 'added');
  assert.equal(n.transactionChange(tx({ deleted: true }), tx()), 'added');
  assert.equal(n.transactionChange(tx(), tx({ deleted: true })), 'deleted');
  assert.equal(n.transactionChange(tx(), tx({ amountMinor: 1 })), 'edited');
  assert.equal(n.transactionChange(tx(), tx({ note: 'Other' })), 'edited');
  // Re-uploads, backfills and server timestamps only.
  assert.equal(
    n.transactionChange(tx(), tx({ serverUpdatedAt: 9, schemaVersion: 2 })),
    null,
  );
  assert.equal(
    n.transactionChange(tx({ deleted: true }), tx({ deleted: true, note: 'x' })),
    null,
  );
  assert.equal(n.transactionChange(tx(), undefined), null);
  // A brand new document that is already deleted is not news.
  assert.equal(n.transactionChange(undefined, tx({ deleted: true })), null);
});

test('transactionMessage', () => {
  assert.deepEqual(n.transactionMessage('added', tx(), 'Sara Khan', 'AED'), {
    title: 'Sara added an expense',
    body: 'AED 45.50 · Groceries · Weekly shop',
  });
  assert.deepEqual(
    n.transactionMessage(
      'deleted',
      tx({ type: 'income', note: '', category: undefined }),
      null,
      'USD',
    ),
    { title: 'Someone deleted an income', body: '+$45.50' },
  );
  const long = n.transactionMessage('edited', tx({ note: 'x'.repeat(200) }), 'Omar', 'AED');
  assert.ok(long.body.length < 100);
  assert.equal(long.title, 'Omar edited an expense');
});

test('memberChange and messages', () => {
  assert.equal(n.memberChange(undefined, { status: 'active' }), 'joined');
  assert.equal(n.memberChange({ status: 'left' }, { status: 'active' }), 'joined');
  assert.equal(n.memberChange({ status: 'active' }, { status: 'left' }), 'left');
  assert.equal(n.memberChange({ status: 'active' }, { status: 'removed' }), 'removed');
  assert.equal(n.memberChange({ status: 'active' }, { status: 'active', role: 'owner' }), null);
  assert.equal(n.memberChange({ status: 'removed' }, { status: 'removed' }), null);

  assert.equal(n.memberMessage('joined', 'Sara Khan', 'Khan family').title, 'Sara joined Khan family');
  assert.equal(n.memberMessage('left', null, null).title, 'Someone left your household');
  assert.equal(n.memberMessage('other', 'a', 'b'), null);
  assert.equal(n.removedYouMessage('Khan family').title, 'You were removed from Khan family');
});

test('savings messages and goal reached detection', () => {
  const entry = { id: 'e1', type: 'deposit', amountMinor: 5000, userName: 'Sara' };
  const goal = { name: 'Japan trip', targetMinor: 100000, savedMinor: 60000, lastEntryId: 'e1' };
  assert.deepEqual(n.savingsMessage(entry, goal, 'AED'), {
    title: 'Sara added to Japan trip',
    body: 'AED 50.00 saved · AED 600.00 of AED 1,000.00 (60%).',
    reached: false,
  });

  const reached = { ...goal, savedMinor: 102000 };
  assert.equal(n.goalReachedBy(entry, reached), true);
  assert.equal(n.savingsMessage(entry, reached, 'AED').reached, true);
  assert.match(n.savingsMessage(entry, reached, 'AED').title, /Japan trip reached its target/);
  // Already past the target before this entry.
  assert.equal(n.goalReachedBy(entry, { ...goal, savedMinor: 200000 }), false);
  // Another entry has been recorded since: the total no longer tells.
  assert.equal(n.goalReachedBy(entry, { ...reached, lastEntryId: 'e2' }), false);
  assert.equal(n.goalReachedBy({ ...entry, type: 'withdrawal' }, reached), false);

  const withdrawal = n.savingsMessage({ ...entry, type: 'withdrawal' }, goal, 'USD');
  assert.equal(withdrawal.title, 'Sara withdrew from Japan trip');
  assert.equal(withdrawal.body, '$50.00 withdrawn · $600.00 of $1,000.00 (60%).');
  assert.equal(n.savingsMessage(entry, undefined, 'AED').body, 'AED 50.00 saved.');
});

test('budgetAlertMessage validates and drops stale alerts', () => {
  const alert = {
    level: 'exceeded',
    title: 'Budget exceeded',
    message: '104% of the shared monthly budget used. Over by AED 40.00.',
    periodEnd: 1000,
  };
  assert.deepEqual(n.budgetAlertMessage(alert, 500), {
    title: 'Household budget exceeded',
    body: '104% of the shared monthly budget used. Over by AED 40.00.',
  });
  assert.equal(n.budgetAlertMessage(alert, 1000 + n.BUDGET_ALERT_GRACE_MS + 1), null);
  assert.equal(n.budgetAlertMessage({ ...alert, level: 'none' }, 500), null);
  assert.equal(n.budgetAlertMessage({ ...alert, title: 3 }, 500), null);
  assert.equal(n.budgetAlertMessage(undefined, 500), null);
});

test('targetsFor honours preferences and drops duplicate tokens', () => {
  const devices = [
    { ref: 'a', data: { token: 't1', householdActivity: true, currencyCode: 'USD' } },
    { ref: 'b', data: { token: 't1', householdActivity: true } },
    { ref: 'c', data: { token: 't2', householdActivity: false } },
    { ref: 'd', data: { token: '' } },
    { ref: 'e', data: { token: 't3' } },
  ];
  assert.deepEqual(n.targetsFor(devices, n.PREFS.householdActivity), [
    { token: 't1', ref: 'a', currencyCode: 'USD' },
    { token: 't3', ref: 'e', currencyCode: 'AED' },
  ]);
});

test('isDeadTokenError', () => {
  assert.equal(n.isDeadTokenError({ code: 'messaging/registration-token-not-registered' }), true);
  assert.equal(n.isDeadTokenError({ code: 'messaging/internal-error' }), false);
  assert.equal(n.isDeadTokenError(undefined), false);
});
