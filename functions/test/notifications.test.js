'use strict';

// Notification handlers against the Firestore emulator, with a fake FCM
// sender:   npm test

const test = require('node:test');
const assert = require('node:assert/strict');

const PROJECT = 'demo-moneymate';
const emulated = !!process.env.FIRESTORE_EMULATOR_HOST;
const skip = emulated ? false : 'needs the Firestore emulator (npm test)';

const HID = 'house-1';
const OMAR = 'omar-uid';
const SARA = 'sara-uid';
const EVE = 'eve-uid';

let db;
let n;
let sent;
/** Tokens the fake FCM treats as uninstalled. */
let deadTokens;

async function send(messages) {
  sent.push(...messages);
  return messages.map((m) =>
    deadTokens.has(m.token)
      ? {
          success: false,
          error: { code: 'messaging/registration-token-not-registered' },
        }
      : { success: true },
  );
}

const deps = { now: () => 1_700_000_000_000 };

async function clear() {
  await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`,
    { method: 'DELETE' },
  );
}

function device(token, extra = {}) {
  return {
    deviceId: token,
    token,
    platform: 'android',
    currencyCode: 'AED',
    householdActivity: true,
    householdBudgets: true,
    savingsUpdates: true,
    updatedAt: 1,
    ...extra,
  };
}

const sharedTx = (extra = {}) => ({
  id: 't1',
  scope: 'shared',
  householdId: HID,
  type: 'expense',
  amountMinor: 9900,
  categoryId: 'exp_groceries',
  category: { name: 'Groceries' },
  date: 1,
  note: 'Weekly shop',
  paymentMethod: 'card',
  createdBy: SARA,
  createdByName: 'Sara',
  updatedBy: SARA,
  deleted: false,
  ...extra,
});

test.describe('notification handlers', { skip }, () => {
  test.before(() => {
    const { initializeApp } = require('firebase-admin/app');
    const { getFirestore } = require('firebase-admin/firestore');
    initializeApp({ projectId: PROJECT }, 'notifications-test');
    const { getApp } = require('firebase-admin/app');
    db = getFirestore(getApp('notifications-test'));
    n = require('../src/notifications');
  });

  test.beforeEach(async () => {
    sent = [];
    deadTokens = new Set();
    await clear();
    await db.doc(`households/${HID}`).set({ name: 'Khan family', status: 'active' });
    for (const [uid, name, status] of [
      [OMAR, 'Omar Khan', 'active'],
      [SARA, 'Sara Khan', 'active'],
      [EVE, 'Eve', 'removed'],
    ]) {
      await db
        .doc(`households/${HID}/members/${uid}`)
        .set({ uid, displayName: name, status, role: uid === OMAR ? 'owner' : 'member' });
    }
    await db.doc(`users/${OMAR}/devices/phone`).set(device('omar-phone', { currencyCode: 'USD' }));
    await db.doc(`users/${OMAR}/devices/tablet`).set(device('omar-tablet', { householdActivity: false }));
    await db.doc(`users/${SARA}/devices/phone`).set(device('sara-phone'));
    await db.doc(`users/${EVE}/devices/phone`).set(device('eve-phone'));
  });

  test('a shared transaction notifies the other members only', async () => {
    const count = await n.onHouseholdTransaction(db, send, {
      params: { householdId: HID, transactionId: 't1' },
      before: undefined,
      after: sharedTx(),
    });
    assert.equal(count, 1);
    assert.equal(sent.length, 1);
    const [m] = sent;
    // Omar's phone, in Omar's currency; his tablet opted out; Sara made
    // the change; Eve was removed.
    assert.equal(m.token, 'omar-phone');
    assert.deepEqual(m.notification, {
      title: 'Sara added an expense',
      body: '$99.00 · Groceries · Weekly shop',
    });
    assert.equal(m.android.notification.channelId, 'household_activity');
    assert.equal(m.android.notification.tag, 'tx-t1');
    assert.equal(m.data.type, 'household_transaction');
    assert.equal(m.data.change, 'added');
    assert.ok(Object.values(m.data).every((v) => typeof v === 'string'));
  });

  test('unchanged re-uploads and writes by non-members are silent', async () => {
    await n.onHouseholdTransaction(db, send, {
      params: { householdId: HID, transactionId: 't1' },
      before: sharedTx(),
      after: { ...sharedTx(), serverUpdatedAt: 5 },
    });
    await n.onHouseholdTransaction(db, send, {
      params: { householdId: HID, transactionId: 't1' },
      before: undefined,
      after: sharedTx({ createdBy: EVE, updatedBy: EVE }),
    });
    assert.equal(sent.length, 0);
  });

  test('edits are attributed to the editor', async () => {
    await n.onHouseholdTransaction(db, send, {
      params: { householdId: HID, transactionId: 't1' },
      before: sharedTx(),
      after: sharedTx({ amountMinor: 12000, updatedBy: OMAR }),
    });
    assert.deepEqual(
      sent.map((m) => [m.token, m.notification.title]),
      [['sara-phone', 'Omar edited an expense']],
    );
  });

  test('dead tokens are removed', async () => {
    deadTokens.add('omar-phone');
    const count = await n.onHouseholdTransaction(db, send, {
      params: { householdId: HID, transactionId: 't1' },
      before: undefined,
      after: sharedTx(),
    });
    assert.equal(count, 0);
    assert.equal((await db.doc(`users/${OMAR}/devices/phone`).get()).exists, false);
    assert.equal((await db.doc(`users/${OMAR}/devices/tablet`).get()).exists, true);
  });

  test('members joining, leaving and being removed', async () => {
    await n.onHouseholdMember(db, send, {
      params: { householdId: HID, memberUid: SARA },
      before: undefined,
      after: { displayName: 'Sara Khan', status: 'active' },
    });
    assert.deepEqual(
      sent.map((m) => [m.token, m.notification.title]),
      [['omar-phone', 'Sara joined Khan family']],
    );

    sent = [];
    await db.doc(`households/${HID}/members/${SARA}`).update({ status: 'removed' });
    await n.onHouseholdMember(db, send, {
      params: { householdId: HID, memberUid: SARA },
      before: { displayName: 'Sara Khan', status: 'active' },
      after: { displayName: 'Sara Khan', status: 'removed' },
    });
    assert.deepEqual(
      sent.map((m) => [m.token, m.notification.title]),
      [
        ['omar-phone', 'Sara was removed from Khan family'],
        ['sara-phone', 'You were removed from Khan family'],
      ],
    );

    sent = [];
    await n.onHouseholdMember(db, send, {
      params: { householdId: HID, memberUid: OMAR },
      before: { status: 'active', role: 'member' },
      after: { status: 'active', role: 'owner' },
    });
    assert.equal(sent.length, 0);
  });

  test('household budget alerts go to the other members', async () => {
    const alert = {
      id: 'monthly.20231101.warning',
      key: 'monthly.20231101',
      level: 'warning',
      title: 'Budget warning',
      message: '92% of the shared monthly budget used. AED 120.00 left.',
      createdBy: SARA,
      createdAt: 1,
      periodEnd: deps.now() + 1000,
    };
    await n.onHouseholdBudgetAlert(
      db,
      send,
      { params: { householdId: HID, alertId: alert.id }, after: alert },
      deps,
    );
    assert.deepEqual(
      sent.map((m) => [m.token, m.notification.title, m.android.notification.channelId]),
      [
        ['omar-phone', 'Household budget warning', 'budget_alerts'],
        ['omar-tablet', 'Household budget warning', 'budget_alerts'],
      ],
    );

    // Stale (written offline long after the period ended).
    sent = [];
    await n.onHouseholdBudgetAlert(
      db,
      send,
      {
        params: { householdId: HID, alertId: 'x' },
        after: { ...alert, periodEnd: 0 },
      },
      deps,
    );
    assert.equal(sent.length, 0);
  });

  test('household savings contributions and reaching a goal', async () => {
    const goalPath = `households/${HID}/savingsGoals/g1`;
    await db.doc(goalPath).set({
      name: 'Japan trip',
      targetMinor: 100000,
      savedMinor: 40000,
      lastEntryId: 'e1',
      deleted: false,
    });
    const entry = {
      goalId: 'g1',
      type: 'deposit',
      amountMinor: 10000,
      userUid: SARA,
      userName: 'Sara Khan',
      deleted: false,
    };
    await n.onHouseholdSavingsEntry(db, send, {
      params: { householdId: HID, entryId: 'e1' },
      after: entry,
    });
    assert.deepEqual(
      sent.map((m) => [m.token, m.notification.title, m.notification.body]),
      [
        ['omar-phone', 'Sara added to Japan trip', '$100.00 saved · $400.00 of $1,000.00 (40%).'],
        // The tablet only turned household activity off.
        ['omar-tablet', 'Sara added to Japan trip', 'AED 100.00 saved · AED 400.00 of AED 1,000.00 (40%).'],
      ],
    );

    sent = [];
    await db.doc(goalPath).update({ savedMinor: 100000, lastEntryId: 'e2' });
    await n.onHouseholdSavingsEntry(db, send, {
      params: { householdId: HID, entryId: 'e2' },
      after: { ...entry, amountMinor: 60000 },
    });
    assert.equal(sent.length, 2);
    assert.match(sent[0].notification.title, /Japan trip reached its target/);
    assert.equal(sent[0].data.reached, 'true');
  });

  test('shared goal entries notify the goal members', async () => {
    await db.doc('sharedGoals/sg1').set({
      name: 'Wedding gift',
      targetMinor: 50000,
      savedMinor: 5000,
      lastEntryId: 'e1',
      deleted: false,
    });
    await db.doc(`sharedGoals/sg1/members/${OMAR}`).set({ uid: OMAR, status: 'active' });
    await db.doc(`sharedGoals/sg1/members/${EVE}`).set({ uid: EVE, status: 'active' });
    await db.doc(`sharedGoals/sg1/members/${SARA}`).set({ uid: SARA, status: 'left' });
    await n.onSharedGoalEntry(db, send, {
      params: { goalId: 'sg1', entryId: 'e1' },
      after: {
        goalId: 'sg1',
        type: 'deposit',
        amountMinor: 5000,
        userUid: EVE,
        userName: 'Eve',
        deleted: false,
      },
    });
    assert.deepEqual(
      sent.map((m) => [m.token, m.notification.title]),
      [
        ['omar-phone', 'Eve added to Wedding gift'],
        ['omar-tablet', 'Eve added to Wedding gift'],
      ],
    );

    // Someone who left cannot announce entries.
    sent = [];
    await n.onSharedGoalEntry(db, send, {
      params: { goalId: 'sg1', entryId: 'e9' },
      after: { goalId: 'sg1', type: 'deposit', amountMinor: 1, userUid: SARA },
    });
    assert.equal(sent.length, 0);
  });
});
