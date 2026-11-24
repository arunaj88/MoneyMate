'use strict';

/**
 * Push notification handlers (Firebase Cloud Messaging), run by Firestore
 * triggers in index.js.
 *
 * Each app installation registers itself at users/{uid}/devices/{deviceId}
 * with its FCM token, the user's display currency and which notifications
 * it wants (see notify_logic.PREFS). The handlers find the people a change
 * concerns, never notify the person who made it, and remove tokens FCM
 * reports as dead.
 *
 * Handlers take (db, send, event, deps) so they are tested against the
 * Firestore emulator with a fake sender:
 *   db    – admin Firestore instance
 *   send  – (messages: object[]) => Promise<{success, error}[]>, one result
 *           per message (getMessaging().sendEach in production)
 *   event – {params, before, after}: the trigger's path parameters and the
 *           document data before and after the write (undefined if absent)
 *   deps  – {now(): number}
 */

const logic = require('./notify_logic');

const { PREFS, CHANNELS } = logic;

const USERS = 'users';
const DEVICES = 'devices';
const HOUSEHOLDS = 'households';
const MEMBERS = 'members';
const SHARED_GOALS = 'sharedGoals';

/** FCM accepts at most 500 messages per sendEach call. */
const SEND_BATCH = 500;

/** Active member documents of a household or shared goal. */
async function activeMembers(collectionRef) {
  const snap = await collectionRef.where('status', '==', 'active').get();
  return snap.docs.map((d) => ({ uid: d.id, ...d.data() }));
}

async function devicesOf(db, uid) {
  const snap = await db.collection(USERS).doc(uid).collection(DEVICES).get();
  return snap.docs.map((d) => ({ ref: d.ref, data: d.data() }));
}

/**
 * Sends one notification per device of [uids] that wants [pref]. [build]
 * receives the device's currency and returns {title, body}, so amounts are
 * shown in each person's own currency setting.
 * @returns {Promise<number>} how many messages FCM accepted
 */
async function notifyUsers(db, send, { uids, pref, channel, tag, data, build }) {
  const unique = [...new Set(uids)].filter(Boolean);
  if (unique.length === 0) return 0;
  const targets = (
    await Promise.all(unique.map((uid) => devicesOf(db, uid)))
  ).flatMap((devices) => logic.targetsFor(devices, pref));
  if (targets.length === 0) return 0;

  const messages = targets.map((t) => {
    const { title, body } = build(t.currencyCode);
    return {
      token: t.token,
      notification: { title, body },
      data: stringValues({ ...data, channel }),
      android: {
        priority: 'high',
        notification: { channelId: channel, tag, icon: 'ic_stat_notify' },
      },
      apns: { payload: { aps: { 'thread-id': tag, sound: 'default' } } },
    };
  });

  let delivered = 0;
  const dead = [];
  for (let i = 0; i < messages.length; i += SEND_BATCH) {
    const batch = messages.slice(i, i + SEND_BATCH);
    const results = await send(batch);
    results.forEach((r, j) => {
      if (r.success) delivered++;
      else if (logic.isDeadTokenError(r.error)) dead.push(targets[i + j].ref);
    });
  }
  // A token FCM rejects belongs to an uninstalled app or a signed-out
  // device: forget it so it is not tried again.
  await Promise.all(dead.map((ref) => ref.delete()));
  return delivered;
}

/** FCM data payloads must be string to string. */
function stringValues(object) {
  return Object.fromEntries(
    Object.entries(object)
      .filter(([, v]) => v !== undefined && v !== null)
      .map(([k, v]) => [k, String(v)]),
  );
}

async function householdName(db, hid) {
  const snap = await db.collection(HOUSEHOLDS).doc(hid).get();
  return snap.exists ? snap.get('name') : null;
}

// --------------------------------------------------------- transactions

/** households/{householdId}/transactions/{transactionId} written. */
async function onHouseholdTransaction(db, send, { params, before, after }) {
  const change = logic.transactionChange(before, after);
  if (!change) return 0;
  const actor = after.updatedBy || after.createdBy;
  const { householdId, transactionId } = params;
  const members = await activeMembers(
    db.collection(HOUSEHOLDS).doc(householdId).collection(MEMBERS),
  );
  const author = members.find((m) => m.uid === actor);
  // Only members' own writes are announced (rules guarantee this; a write
  // by someone who has since left is not news to the others).
  if (!author) return 0;
  const actorName =
    author.displayName ||
    (actor === after.createdBy ? after.createdByName : null) ||
    (author.email ?? '').split('@')[0];
  return notifyUsers(db, send, {
    uids: members.map((m) => m.uid).filter((uid) => uid !== actor),
    pref: PREFS.householdActivity,
    channel: CHANNELS.household,
    // A later edit replaces the earlier notification for the same entry.
    tag: `tx-${transactionId}`,
    data: { type: 'household_transaction', change, householdId, transactionId },
    build: (currency) =>
      logic.transactionMessage(change, after, actorName, currency),
  });
}

// --------------------------------------------------------------- members

/** households/{householdId}/members/{memberUid} written. */
async function onHouseholdMember(db, send, { params, before, after }) {
  const change = logic.memberChange(before, after);
  if (!change) return 0;
  const { householdId, memberUid } = params;
  const member = after ?? before;
  const name =
    member.displayName || (member.email ?? '').split('@')[0] || null;
  const house = await householdName(db, householdId);
  const others = (
    await activeMembers(
      db.collection(HOUSEHOLDS).doc(householdId).collection(MEMBERS),
    )
  )
    .map((m) => m.uid)
    .filter((uid) => uid !== memberUid);

  const message = logic.memberMessage(change, name, house);
  let sent = await notifyUsers(db, send, {
    uids: others,
    pref: PREFS.householdActivity,
    channel: CHANNELS.household,
    tag: `member-${householdId}-${memberUid}`,
    data: { type: 'household_member', change, householdId, memberUid },
    build: () => message,
  });
  if (change === 'removed') {
    const removed = logic.removedYouMessage(house);
    sent += await notifyUsers(db, send, {
      uids: [memberUid],
      pref: PREFS.householdActivity,
      channel: CHANNELS.household,
      tag: `member-${householdId}-${memberUid}`,
      data: { type: 'household_removed', householdId },
      build: () => removed,
    });
  }
  return sent;
}

// --------------------------------------------------------------- budgets

/** households/{householdId}/budgetAlerts/{alertId} created by a member. */
async function onHouseholdBudgetAlert(db, send, { params, after }, deps) {
  if (!after) return 0;
  const message = logic.budgetAlertMessage(after, deps.now());
  if (!message) return 0;
  const { householdId, alertId } = params;
  const members = await activeMembers(
    db.collection(HOUSEHOLDS).doc(householdId).collection(MEMBERS),
  );
  if (!members.some((m) => m.uid === after.createdBy)) return 0;
  return notifyUsers(db, send, {
    // The member whose app raised it already saw it in the app.
    uids: members.map((m) => m.uid).filter((uid) => uid !== after.createdBy),
    pref: PREFS.householdBudgets,
    channel: CHANNELS.budgets,
    // A higher level for the same budget and period replaces a lower one.
    tag: `budget-${householdId}-${String(after.key ?? alertId)}`,
    data: { type: 'household_budget', householdId, level: after.level },
    build: () => message,
  });
}

// --------------------------------------------------------------- savings

async function notifySavingsEntry(db, send, { entry, goalRef, membersRef, data }) {
  if (!entry || entry.deleted === true) return 0;
  const [goalSnap, members] = await Promise.all([
    goalRef.get(),
    activeMembers(membersRef),
  ]);
  const goal = goalSnap.exists ? goalSnap.data() : undefined;
  if (!goal || goal.deleted === true) return 0;
  if (!members.some((m) => m.uid === entry.userUid)) return 0;
  const reached = logic.goalReachedBy(entry, goal);
  return notifyUsers(db, send, {
    uids: members.map((m) => m.uid).filter((uid) => uid !== entry.userUid),
    pref: PREFS.savings,
    channel: CHANNELS.savings,
    tag: reached ? `goal-reached-${goalRef.id}` : `goal-${goalRef.id}`,
    data: { ...data, goalId: goalRef.id, reached },
    build: (currency) => logic.savingsMessage(entry, goal, currency),
  });
}

/** households/{householdId}/savingsEntries/{entryId} created. */
async function onHouseholdSavingsEntry(db, send, { params, after }) {
  const household = db.collection(HOUSEHOLDS).doc(params.householdId);
  return notifySavingsEntry(db, send, {
    entry: after && { id: params.entryId, ...after },
    goalRef: household.collection('savingsGoals').doc(String(after?.goalId ?? '-')),
    membersRef: household.collection(MEMBERS),
    data: { type: 'household_savings', householdId: params.householdId },
  });
}

/** sharedGoals/{goalId}/entries/{entryId} created. */
async function onSharedGoalEntry(db, send, { params, after }) {
  const goalRef = db.collection(SHARED_GOALS).doc(params.goalId);
  return notifySavingsEntry(db, send, {
    entry: after && { id: params.entryId, ...after },
    goalRef,
    membersRef: goalRef.collection(MEMBERS),
    data: { type: 'shared_goal' },
  });
}

module.exports = {
  notifyUsers,
  onHouseholdTransaction,
  onHouseholdMember,
  onHouseholdBudgetAlert,
  onHouseholdSavingsEntry,
  onSharedGoalEntry,
};
