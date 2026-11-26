'use strict';

// firestore.rules against the documents the app actually writes:
//   npm test   (runs `firebase emulators:exec --only firestore,storage ...`)

const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const PROJECT = 'demo-moneymate';
const emulated = !!process.env.FIRESTORE_EMULATOR_HOST;
const skip = emulated ? false : 'needs the Firestore emulator (npm test)';

let env;
let firebase;
let assertSucceeds;
let assertFails;

const HID = 'house-1';
const OWNER = 'owner-uid';
const PARTNER = 'partner-uid';
const REMOVED = 'removed-uid';
const STRANGER = 'stranger-uid';

const now = () => firebase.firestore.FieldValue.serverTimestamp();

/** A personal transaction exactly as the app's toCloudMap writes it. */
function personalTx(uid, id, extra = {}) {
  return {
    schemaVersion: 2,
    scope: 'personal',
    ownerUid: uid,
    createdBy: uid,
    id,
    type: 'expense',
    amountMinor: 2500,
    categoryId: 'exp_food',
    date: 1_700_000_000_000,
    note: 'Lunch',
    paymentMethod: 'card',
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000,
    deleted: false,
    deletedAt: null,
    category: {
      id: 'exp_food',
      name: 'Food',
      type: 'expense',
      iconKey: 'food',
      colorValue: 4293881431,
    },
    serverUpdatedAt: now(),
    ...extra,
  };
}

/** A shared transaction as written by [uid]. */
function sharedTx(uid, id, extra = {}) {
  return {
    schemaVersion: 2,
    scope: 'shared',
    householdId: HID,
    createdBy: uid,
    createdByName: 'Someone',
    updatedBy: uid,
    id,
    type: 'expense',
    amountMinor: 9900,
    categoryId: 'exp_groceries',
    date: 1_700_000_000_000,
    note: 'Weekly shop',
    paymentMethod: 'card',
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000,
    deleted: false,
    deletedAt: null,
    serverUpdatedAt: now(),
    ...extra,
  };
}

/** A client signed in as [uid] with a verified email. */
function db(uid) {
  return uid
    ? env.authenticatedContext(uid, { email_verified: true }).firestore()
    : env.unauthenticatedContext().firestore();
}

/** A client signed in as [uid] whose email is not verified yet. */
function unverifiedDb(uid) {
  return env
    .authenticatedContext(uid, { email: `${uid}@example.com`, email_verified: false })
    .firestore();
}

test.describe('firestore.rules', { skip }, () => {
  test.before(async () => {
    const rut = require('@firebase/rules-unit-testing');
    firebase = require('firebase/compat/app');
    require('firebase/compat/firestore');
    assertSucceeds = rut.assertSucceeds;
    assertFails = rut.assertFails;
    const [host, port] = process.env.FIRESTORE_EMULATOR_HOST.split(':');
    env = await rut.initializeTestEnvironment({
      projectId: PROJECT,
      firestore: {
        host,
        port: Number(port),
        rules: fs.readFileSync(
          path.join(__dirname, '..', '..', 'firestore.rules'),
          'utf8',
        ),
      },
    });
  });

  test.after(async () => env?.cleanup());

  test.beforeEach(async () => {
    await env.clearFirestore();
    // Seed the household as Cloud Functions would.
    await env.withSecurityRulesDisabled(async (ctx) => {
      const admin = ctx.firestore();
      await admin.doc(`households/${HID}`).set({
        id: HID,
        name: 'Khan family',
        ownerUid: OWNER,
        status: 'active',
      });
      const members = {
        [OWNER]: { role: 'owner', status: 'active' },
        [PARTNER]: { role: 'member', status: 'active' },
        [REMOVED]: { role: 'member', status: 'removed' },
      };
      for (const [uid, m] of Object.entries(members)) {
        await admin.doc(`households/${HID}/members/${uid}`).set({ uid, ...m });
      }
      await admin
        .doc(`households/${HID}/invitations/inv-1`)
        .set({ id: 'inv-1', status: 'pending', code: 'ABCDEFGHJK' });
      await admin
        .doc('invitationCodes/ABCDEFGHJK')
        .set({ householdId: HID, invitationId: 'inv-1' });
      await admin
        .doc(`households/${HID}/transactions/existing`)
        .set({ ...sharedTx(OWNER, 'existing'), serverUpdatedAt: 1 });
      await admin
        .doc(`users/${OWNER}/transactions/legacy`)
        .set({
          id: 'legacy',
          type: 'expense',
          amountMinor: 100,
          categoryId: 'exp_food',
          date: 1,
          note: '',
          paymentMethod: 'cash',
          createdAt: 1,
          updatedAt: 1,
          deleted: true,
          serverUpdatedAt: 1,
        });
    });
  });

  // ------------------------------------------------------------ personal

  test('owner can write and read personal transactions', async () => {
    const ref = db(OWNER).doc(`users/${OWNER}/transactions/t1`);
    await assertSucceeds(ref.set(personalTx(OWNER, 't1')));
    await assertSucceeds(ref.get());
    await assertSucceeds(
      db(OWNER).collection(`users/${OWNER}/transactions`).orderBy('serverUpdatedAt').get(),
    );
  });

  // -------------------------------------------------- email verification

  test('accounts with an unverified email cannot use any financial data', async () => {
    // Owner and partner are active household members, but unverified here.
    const owner = unverifiedDb(OWNER);
    await assertFails(owner.doc(`users/${OWNER}`).get());
    await assertFails(owner.doc(`users/${OWNER}/transactions/legacy`).get());
    await assertFails(owner.collection(`users/${OWNER}/transactions`).get());
    await assertFails(owner.doc(`users/${OWNER}/transactions/t1`).set(personalTx(OWNER, 't1')));
    await assertFails(owner.collection(`users/${OWNER}/savingsGoals`).get());
    await assertFails(owner.collection(`users/${OWNER}/loans`).get());
    await assertFails(owner.collection(`users/${OWNER}/devices`).get());
    await assertFails(owner.doc(`households/${HID}`).get());
    await assertFails(owner.collection(`households/${HID}/transactions`).get());
    await assertFails(
      unverifiedDb(PARTNER)
        .doc(`households/${HID}/transactions/t2`)
        .set(sharedTx(PARTNER, 't2')),
    );
    await assertFails(owner.collection('sharedGoalInvitations').doc('ABC').get());
    // A token without the claim at all is treated as unverified.
    const noClaim = env.authenticatedContext(OWNER, { email: 'o@example.com' }).firestore();
    await assertFails(noClaim.doc(`users/${OWNER}/transactions/legacy`).get());
    // The same account once verified.
    await assertSucceeds(db(OWNER).doc(`users/${OWNER}/transactions/legacy`).get());
    await assertSucceeds(db(OWNER).doc(`households/${HID}/transactions/existing`).get());
  });

  test('personal transactions are private to their owner', async () => {
    await assertFails(db(PARTNER).doc(`users/${OWNER}/transactions/t1`).get());
    await assertFails(
      db(PARTNER).collection(`users/${OWNER}/transactions`).get(),
    );
    await assertFails(
      db(PARTNER)
        .doc(`users/${OWNER}/transactions/t1`)
        .set(personalTx(OWNER, 't1')),
    );
    await assertFails(db(null).doc(`users/${OWNER}/transactions/t1`).get());
  });

  test('personal documents must be marked personal and owned', async () => {
    const ref = db(OWNER).doc(`users/${OWNER}/transactions/t1`);
    await assertFails(ref.set(personalTx(OWNER, 't1', { scope: 'shared' })));
    await assertFails(ref.set(personalTx(OWNER, 't1', { ownerUid: PARTNER })));
    await assertFails(ref.set(personalTx(OWNER, 't1', { householdId: HID })));
    await assertFails(ref.set(personalTx(OWNER, 'other-id')));
    await assertFails(ref.set(personalTx(OWNER, 't1', { amountMinor: 0 })));
    await assertFails(ref.set(personalTx(OWNER, 't1', { serverUpdatedAt: 5 })));
    await assertFails(
      ref.set(personalTx(OWNER, 't1', { deleted: true, deletedAt: null })),
    );
  });

  test('updates keep createdAt and cloud records are never hard-deleted', async () => {
    const ref = db(OWNER).doc(`users/${OWNER}/transactions/t1`);
    await assertSucceeds(ref.set(personalTx(OWNER, 't1')));
    await assertFails(ref.set(personalTx(OWNER, 't1', { createdAt: 5 })));
    await assertSucceeds(
      ref.set(
        personalTx(OWNER, 't1', {
          deleted: true,
          deletedAt: 1_700_000_100_000,
          updatedAt: 1_700_000_100_000,
        }),
      ),
    );
    await assertFails(ref.delete());
  });

  test('the user document (reset marker) is read-only for its owner', async () => {
    await env.withSecurityRulesDisabled((ctx) =>
      ctx.firestore().doc(`users/${OWNER}`).set({ personalResetAt: 5 }),
    );
    await assertSucceeds(db(OWNER).doc(`users/${OWNER}`).get());
    await assertFails(db(PARTNER).doc(`users/${OWNER}`).get());
    await assertFails(db(null).doc(`users/${OWNER}`).get());
    await assertFails(
      db(OWNER).doc(`users/${OWNER}`).set({ personalResetAt: 1 }),
    );
    await assertFails(db(OWNER).doc(`users/${OWNER}`).delete());
  });

  test('legacy personal documents can be given their ownership fields', async () => {
    await assertSucceeds(
      db(OWNER).doc(`users/${OWNER}/transactions/legacy`).set(
        {
          schemaVersion: 2,
          scope: 'personal',
          ownerUid: OWNER,
          createdBy: OWNER,
          deletedAt: 1,
          serverUpdatedAt: now(),
        },
        { merge: true },
      ),
    );
  });

  test('personal budgets and categories are private', async () => {
    const budget = {
      id: 'target_weekly_1',
      kind: 'target',
      period: 'weekly',
      amountMinor: 50000,
      effectiveFrom: 1,
      updatedAt: 1,
      deleted: false,
      serverUpdatedAt: now(),
    };
    await assertSucceeds(
      db(OWNER).doc(`users/${OWNER}/personalBudgets/target_weekly_1`).set(budget),
    );
    await assertFails(
      db(PARTNER).doc(`users/${OWNER}/personalBudgets/target_weekly_1`).get(),
    );
    await assertFails(
      db(PARTNER)
        .doc(`users/${OWNER}/personalBudgets/target_weekly_1`)
        .set(budget),
    );
    const category = {
      id: 'c1',
      name: 'Hobbies',
      type: 'expense',
      iconKey: 'gift',
      colorValue: 1,
      updatedAt: 1,
      deleted: false,
      serverUpdatedAt: now(),
    };
    await assertSucceeds(
      db(OWNER).doc(`users/${OWNER}/personalCategories/c1`).set(category),
    );
    await assertFails(
      db(PARTNER).doc(`users/${OWNER}/personalCategories/c1`).get(),
    );
  });

  test('savings goals and entries are private and validated', async () => {
    // Exactly as FirestoreSavingsStore writes them.
    const goal = {
      id: 'g1',
      name: 'Japan trip',
      purpose: 'trip',
      customPurpose: '',
      targetMinor: 1_000_000,
      targetDate: null,
      notes: '',
      status: 'active',
      createdAt: 1,
      completedAt: null,
      updatedAt: 1,
      deleted: false,
      serverUpdatedAt: now(),
    };
    const entry = {
      id: 'e1',
      goalId: 'g1',
      type: 'deposit',
      amountMinor: 25_000,
      date: 1,
      note: '',
      createdAt: 1,
      updatedAt: 1,
      deleted: false,
      serverUpdatedAt: now(),
    };
    const goalPath = `users/${OWNER}/savingsGoals/g1`;
    const entryPath = `users/${OWNER}/savingsEntries/e1`;

    await assertSucceeds(db(OWNER).doc(goalPath).set(goal));
    await assertSucceeds(db(OWNER).doc(entryPath).set(entry));
    await assertSucceeds(db(OWNER).doc(goalPath).get());

    // Other users can neither read nor write them.
    await assertFails(db(PARTNER).doc(goalPath).get());
    await assertFails(db(PARTNER).doc(entryPath).get());
    await assertFails(db(PARTNER).doc(goalPath).set(goal));
    await assertFails(db(null).doc(goalPath).get());

    // Invalid documents are refused.
    await assertFails(
      db(OWNER).doc(goalPath).set({ ...goal, targetMinor: 0 }),
    );
    await assertFails(db(OWNER).doc(goalPath).set({ ...goal, name: '' }));
    await assertFails(
      db(OWNER).doc(goalPath).set({ ...goal, status: 'archived' }),
    );
    await assertFails(
      db(OWNER).doc(entryPath).set({ ...entry, amountMinor: -5 }),
    );
    await assertFails(
      db(OWNER).doc(entryPath).set({ ...entry, type: 'income' }),
    );
    await assertFails(
      db(OWNER).doc(`users/${OWNER}/savingsEntries/other`).set(entry),
    );

    // Soft deletion is allowed; hard deletion never.
    await assertSucceeds(
      db(OWNER).doc(goalPath).set({
        id: 'g1',
        deleted: true,
        updatedAt: 2,
        deletedAt: 2,
        serverUpdatedAt: now(),
      }),
    );
    await assertFails(db(OWNER).doc(entryPath).delete());
  });

  // -------------------------------------------------------------- shared

  test('active members read and create shared transactions', async () => {
    await assertSucceeds(db(PARTNER).doc(`households/${HID}/transactions/existing`).get());
    await assertSucceeds(
      db(PARTNER)
        .collection(`households/${HID}/transactions`)
        .orderBy('serverUpdatedAt')
        .get(),
    );
    await assertSucceeds(
      db(PARTNER)
        .doc(`households/${HID}/transactions/s1`)
        .set(sharedTx(PARTNER, 's1')),
    );
  });

  test('the creator must be the caller', async () => {
    await assertFails(
      db(PARTNER)
        .doc(`households/${HID}/transactions/s1`)
        .set(sharedTx(OWNER, 's1', { updatedBy: PARTNER })),
    );
    await assertFails(
      db(PARTNER)
        .doc(`households/${HID}/transactions/s1`)
        .set(sharedTx(PARTNER, 's1', { householdId: 'house-2' })),
    );
    await assertFails(
      db(PARTNER)
        .doc(`households/${HID}/transactions/s1`)
        .set(sharedTx(PARTNER, 's1', { scope: 'personal' })),
    );
  });

  test('members edit and soft-delete shared transactions, keeping the creator', async () => {
    const ref = db(PARTNER).doc(`households/${HID}/transactions/existing`);
    await assertSucceeds(
      ref.set(
        sharedTx(OWNER, 'existing', {
          updatedBy: PARTNER,
          amountMinor: 12000,
          updatedAt: 1_700_000_200_000,
        }),
      ),
    );
    await assertFails(
      ref.set(sharedTx(PARTNER, 'existing', { updatedAt: 1_700_000_300_000 })),
    );
    await assertSucceeds(
      ref.set(
        sharedTx(OWNER, 'existing', {
          updatedBy: PARTNER,
          deleted: true,
          deletedAt: 1_700_000_400_000,
          updatedAt: 1_700_000_400_000,
        }),
      ),
    );
    await assertFails(ref.delete());
  });

  test('non-members and removed members have no access to shared data', async () => {
    for (const uid of [STRANGER, REMOVED, null]) {
      await assertFails(db(uid).doc(`households/${HID}`).get());
      await assertFails(
        db(uid).doc(`households/${HID}/transactions/existing`).get(),
      );
      await assertFails(
        db(uid).collection(`households/${HID}/transactions`).get(),
      );
      await assertFails(db(uid).collection(`households/${HID}/members`).get());
      if (uid) {
        await assertFails(
          db(uid)
            .doc(`households/${HID}/transactions/x`)
            .set(sharedTx(uid, 'x')),
        );
      }
    }
  });

  test('shared budgets are readable and writable by members only', async () => {
    const budget = (uid) => ({
      id: 'target_monthly_1',
      kind: 'target',
      period: 'monthly',
      amountMinor: 300000,
      effectiveFrom: 1,
      updatedAt: 1,
      updatedBy: uid,
      deleted: false,
      serverUpdatedAt: now(),
    });
    const path = `households/${HID}/budgets/target_monthly_1`;
    await assertSucceeds(db(PARTNER).doc(path).set(budget(PARTNER)));
    await assertSucceeds(db(OWNER).doc(path).get());
    await assertFails(db(PARTNER).doc(path).set(budget(OWNER)));
    await assertFails(db(STRANGER).doc(path).set(budget(STRANGER)));
    await assertFails(db(STRANGER).doc(path).get());
  });

  // ---------------------------------------------------------- membership

  test('membership, roles and households cannot be written by clients', async () => {
    await assertFails(
      db(PARTNER)
        .doc(`households/${HID}/members/${PARTNER}`)
        .set({ uid: PARTNER, role: 'owner', status: 'active' }),
    );
    await assertFails(
      db(PARTNER)
        .doc(`households/${HID}/members/${PARTNER}`)
        .update({ role: 'owner' }),
    );
    await assertFails(
      db(STRANGER)
        .doc(`households/${HID}/members/${STRANGER}`)
        .set({ uid: STRANGER, role: 'member', status: 'active' }),
    );
    await assertFails(
      db(OWNER).doc(`households/${HID}`).update({ ownerUid: PARTNER }),
    );
    await assertFails(
      db(STRANGER)
        .doc('households/new-house')
        .set({ ownerUid: STRANGER, name: 'Mine', status: 'active' }),
    );
    await assertFails(
      db(STRANGER)
        .doc(`users/${STRANGER}/memberships/${HID}`)
        .set({ householdId: HID, status: 'active' }),
    );
    await assertSucceeds(
      db(OWNER).doc(`users/${OWNER}/memberships/${HID}`).get(),
    );
    await assertFails(
      db(PARTNER).doc(`users/${OWNER}/memberships/${HID}`).get(),
    );
  });

  test('only the owner can see invitations; codes are never readable', async () => {
    await assertSucceeds(
      db(OWNER).collection(`households/${HID}/invitations`).get(),
    );
    await assertFails(
      db(PARTNER).collection(`households/${HID}/invitations`).get(),
    );
    await assertFails(
      db(OWNER)
        .doc(`households/${HID}/invitations/inv-1`)
        .update({ status: 'accepted' }),
    );
    await assertFails(db(STRANGER).doc('invitationCodes/ABCDEFGHJK').get());
    await assertFails(db(OWNER).doc('invitationCodes/ABCDEFGHJK').get());
  });

  test('household settings: members read, owner writes', async () => {
    const path = `households/${HID}/settings/general`;
    const data = { updatedAt: 1, serverUpdatedAt: now() };
    await assertSucceeds(db(OWNER).doc(path).set(data));
    await assertFails(db(PARTNER).doc(path).set(data));
    await assertSucceeds(db(PARTNER).doc(path).get());
  });

  // ------------------------------------------------------ savings totals

  /** A goal document as the app writes it (household or shared). */
  function goalDoc(id, extra = {}) {
    return {
      id,
      name: 'Family trip',
      purpose: 'trip',
      customPurpose: '',
      targetMinor: 500_000,
      targetDate: null,
      notes: '',
      status: 'active',
      createdAt: 1,
      completedAt: null,
      updatedAt: 1,
      deleted: false,
      serverUpdatedAt: now(),
      ...extra,
    };
  }

  function entryDoc(id, goalId, uid, amount, type = 'deposit') {
    return {
      id,
      goalId,
      type,
      amountMinor: amount,
      date: 1,
      note: '',
      createdAt: 1,
      updatedAt: 1,
      userUid: uid,
      userName: 'Someone',
      deleted: false,
      serverUpdatedAt: now(),
    };
  }

  /** Writes an entry and the goal's new total together, as the app does. */
  function recordEntry(client, goalPath, entriesPath, entry, newTotal) {
    const batch = client.batch();
    batch.set(client.doc(`${entriesPath}/${entry.id}`), entry);
    batch.update(client.doc(goalPath), {
      savedMinor: newTotal,
      lastEntryId: entry.id,
    });
    return batch.commit();
  }

  test('household savings: members only, totals move with entries', async () => {
    const goalPath = `households/${HID}/savingsGoals/hg`;
    const entries = `households/${HID}/savingsEntries`;
    const household = (uid, extra = {}) =>
      goalDoc('hg', {
        ownership: 'household',
        householdId: HID,
        createdBy: uid,
        updatedBy: uid,
        ...extra,
      });

    await assertFails(db(STRANGER).doc(goalPath).set(household(STRANGER)));
    await assertFails(db(REMOVED).doc(goalPath).set(household(REMOVED)));
    // A goal cannot start with money in it.
    await assertFails(
      db(PARTNER).doc(goalPath).set(household(PARTNER, { savedMinor: 100 })),
    );
    await assertSucceeds(db(PARTNER).doc(goalPath).set(household(PARTNER)));
    await assertSucceeds(db(OWNER).doc(goalPath).get());
    await assertFails(db(STRANGER).doc(goalPath).get());
    await assertFails(db(REMOVED).doc(goalPath).get());

    // A contribution moves the total by exactly its amount.
    await assertSucceeds(
      recordEntry(db(OWNER), goalPath, entries, entryDoc('e1', 'hg', OWNER, 300), 300),
    );
    // Wrong total, someone else's name, or an existing entry ID: refused.
    await assertFails(
      recordEntry(db(OWNER), goalPath, entries, entryDoc('e2', 'hg', OWNER, 100), 999),
    );
    await assertFails(
      recordEntry(db(PARTNER), goalPath, entries, entryDoc('e3', 'hg', OWNER, 100), 400),
    );
    await assertFails(
      recordEntry(db(OWNER), goalPath, entries, entryDoc('e1', 'hg', OWNER, 300), 600),
    );
    // The total alone, or an entry alone, cannot be written.
    await assertFails(db(OWNER).doc(goalPath).update({ savedMinor: 10_000 }));
    await assertFails(
      db(OWNER).doc(`${entries}/e4`).set(entryDoc('e4', 'hg', OWNER, 50)),
    );
    // Withdrawals never take the total below zero.
    await assertFails(
      recordEntry(
        db(PARTNER), goalPath, entries,
        entryDoc('w1', 'hg', PARTNER, 301, 'withdrawal'), -1,
      ),
    );
    await assertSucceeds(
      recordEntry(
        db(PARTNER), goalPath, entries,
        entryDoc('w2', 'hg', PARTNER, 100, 'withdrawal'), 200,
      ),
    );
    // Entries are permanent.
    await assertFails(db(OWNER).doc(`${entries}/e1`).update({ amountMinor: 1 }));
    await assertFails(db(OWNER).doc(`${entries}/e1`).delete());
    // Editing details cannot touch the total.
    await assertFails(
      db(OWNER).doc(goalPath).set(
        household(PARTNER, { updatedBy: OWNER, savedMinor: 0 }),
        { merge: true },
      ),
    );
    await assertSucceeds(
      db(OWNER).doc(goalPath).set(
        { name: 'Bigger trip', updatedAt: 2, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    // A stale concurrent write: a withdrawal computed from the old total
    // (300) is refused now that the total is 200.
    await assertFails(
      recordEntry(
        db(OWNER), goalPath, entries,
        entryDoc('w3', 'hg', OWNER, 250, 'withdrawal'), 50,
      ),
    );
  });

  // -------------------------------------------------------- shared goals

  const FRIEND = 'friend-uid';
  const OTHER = 'other-uid';
  const friendDb = () =>
    env.authenticatedContext(FRIEND, { email: 'friend@example.com', email_verified: true }).firestore();
  const otherDb = () =>
    env.authenticatedContext(OTHER, { email: 'other@example.com', email_verified: true }).firestore();

  const SG = 'sharedGoals/sg';
  const SG_ENTRIES = `${SG}/entries`;
  const sharedGoal = (extra = {}) =>
    goalDoc('sg', {
      name: 'Friends trip',
      ownership: 'shared',
      ownerUid: OWNER,
      createdBy: OWNER,
      updatedBy: OWNER,
      savedMinor: 0,
      ...extra,
    });
  const member = (uid, extra = {}) => ({
    uid,
    role: 'member',
    status: 'active',
    canContribute: true,
    canWithdraw: false,
    displayName: uid,
    email: null,
    joinedAt: 1,
    serverUpdatedAt: now(),
    ...extra,
  });
  const invitation = (code, extra = {}) => ({
    id: code,
    goalId: 'sg',
    goalName: 'Friends trip',
    invitedEmail: null,
    invitedBy: OWNER,
    invitedByName: 'Owner',
    status: 'pending',
    createdAt: Date.now(),
    expiresAt: Date.now() + 86_400_000,
    updatedAt: Date.now(),
    serverUpdatedAt: now(),
    ...extra,
  });

  async function createSharedGoal() {
    const client = db(OWNER);
    const batch = client.batch();
    batch.set(client.doc(SG), sharedGoal());
    batch.set(
      client.doc(`${SG}/members/${OWNER}`),
      member(OWNER, { role: 'owner', canWithdraw: true }),
    );
    batch.set(client.doc(`users/${OWNER}/sharedGoalMemberships/sg`), {
      goalId: 'sg',
      joinedAt: 1,
    });
    await batch.commit();
  }

  function accept(client, uid, code, extra = {}) {
    const batch = client.batch();
    batch.update(client.doc(`sharedGoalInvitations/${code}`), {
      status: 'accepted',
      acceptedBy: uid,
      acceptedByName: uid,
      updatedAt: Date.now(),
      serverUpdatedAt: now(),
    });
    batch.set(client.doc(`${SG}/members/${uid}`), {
      ...member(uid),
      invitationId: code,
      ...extra,
    });
    batch.set(client.doc(`users/${uid}/sharedGoalMemberships/sg`), {
      goalId: 'sg',
      joinedAt: 1,
    });
    return batch.commit();
  }

  test('shared goals: creation and owner-only management', async () => {
    // Nobody can create a goal owned by someone else.
    const partner = db(PARTNER);
    const forged = partner.batch();
    forged.set(partner.doc(SG), sharedGoal());
    forged.set(partner.doc(`${SG}/members/${OWNER}`), member(OWNER, { role: 'owner' }));
    await assertFails(forged.commit());

    await assertSucceeds(createSharedGoal());
    await assertSucceeds(db(OWNER).doc(SG).get());
    // Independent of households: household members have no access.
    await assertFails(db(PARTNER).doc(SG).get());
    await assertFails(db(STRANGER).doc(`${SG}/members/${OWNER}`).get());
    // Nobody can make themselves a member without an invitation.
    await assertFails(
      db(STRANGER).doc(`${SG}/members/${STRANGER}`).set({
        ...member(STRANGER),
        invitationId: 'NOINVITATIONXXXX',
      }),
    );
    // The owner edits details.
    await assertSucceeds(
      db(OWNER).doc(SG).set(
        { name: 'Bali trip', updatedAt: 2, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
  });

  test('shared goals: email invitations, acceptance and permissions', async () => {
    await createSharedGoal();
    const code = 'ABCDEFGHJKMNPQRS';
    // Only the owner invites.
    await assertFails(
      db(STRANGER).doc(`sharedGoalInvitations/${code}`).set(
        invitation(code, { invitedBy: STRANGER }),
      ),
    );
    await assertSucceeds(
      db(OWNER).doc(`sharedGoalInvitations/${code}`).set(
        invitation(code, { invitedEmail: 'friend@example.com' }),
      ),
    );

    // The invitee sees it by email; someone else cannot list it.
    await assertSucceeds(
      friendDb()
        .collection('sharedGoalInvitations')
        .where('invitedEmail', '==', 'friend@example.com')
        .where('status', '==', 'pending')
        .get(),
    );
    await assertFails(
      otherDb()
        .collection('sharedGoalInvitations')
        .where('invitedEmail', '==', 'friend@example.com')
        .get(),
    );

    // Bound to the email: another account cannot accept it.
    await assertFails(accept(otherDb(), OTHER, code));
    // No extra powers can be taken while joining.
    await assertFails(accept(friendDb(), FRIEND, code, { canWithdraw: true }));
    await assertFails(accept(friendDb(), FRIEND, code, { role: 'owner' }));
    await assertSucceeds(accept(friendDb(), FRIEND, code));
    await assertSucceeds(friendDb().doc(SG).get());

    // The accepted invitation cannot be used again.
    await assertFails(accept(otherDb(), OTHER, code));

    // Members contribute in their own name only.
    await assertSucceeds(
      recordEntry(friendDb(), SG, SG_ENTRIES, entryDoc('f1', 'sg', FRIEND, 500), 500),
    );
    await assertFails(
      recordEntry(friendDb(), SG, SG_ENTRIES, entryDoc('f2', 'sg', OWNER, 100), 600),
    );
    // Members cannot withdraw unless allowed, nor edit the goal.
    await assertFails(
      recordEntry(
        friendDb(), SG, SG_ENTRIES,
        entryDoc('fw', 'sg', FRIEND, 100, 'withdrawal'), 400,
      ),
    );
    await assertFails(
      friendDb().doc(SG).set(
        { name: 'Mine now', updatedAt: 3, updatedBy: FRIEND, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    // Members cannot raise their own permissions.
    await assertFails(
      friendDb().doc(`${SG}/members/${FRIEND}`).update({ canWithdraw: true }),
    );
    // The owner grants withdrawal; then it works.
    await assertSucceeds(
      db(OWNER).doc(`${SG}/members/${FRIEND}`).update({
        status: 'active',
        canContribute: true,
        canWithdraw: true,
        serverUpdatedAt: now(),
      }),
    );
    await assertSucceeds(
      recordEntry(
        friendDb(), SG, SG_ENTRIES,
        entryDoc('fw', 'sg', FRIEND, 100, 'withdrawal'), 400,
      ),
    );

    // Removed members lose access, and cannot rejoin on their own.
    await assertSucceeds(
      db(OWNER).doc(`${SG}/members/${FRIEND}`).update({
        status: 'removed',
        canContribute: true,
        canWithdraw: true,
        serverUpdatedAt: now(),
      }),
    );
    await assertFails(friendDb().doc(SG).get());
    await assertFails(friendDb().doc(`${SG_ENTRIES}/f1`).get());
    await assertFails(
      recordEntry(friendDb(), SG, SG_ENTRIES, entryDoc('f3', 'sg', FRIEND, 10), 410),
    );
    await assertFails(
      friendDb().doc(`${SG}/members/${FRIEND}`).update({ status: 'active' }),
    );
    // The owner cannot bring them back without a new invitation either.
    await assertFails(
      db(OWNER).doc(`${SG}/members/${FRIEND}`).update({
        status: 'active',
        canContribute: true,
        canWithdraw: true,
        serverUpdatedAt: now(),
      }),
    );
  });

  test('shared goals: codes, rejection, revocation and expiry', async () => {
    await createSharedGoal();
    const open = 'CODEAAAAAAAAAAAA';
    const forFriend = 'CODEBBBBBBBBBBBB';
    const revoked = 'CODECCCCCCCCCCCC';
    const expired = 'CODEDDDDDDDDDDDD';
    for (const [code, extra] of [
      [open, {}],
      [forFriend, { invitedEmail: 'friend@example.com' }],
      [revoked, {}],
      [expired, { expiresAt: Date.now() - 1000 }],
    ]) {
      await assertSucceeds(
        db(OWNER).doc(`sharedGoalInvitations/${code}`).set(invitation(code, extra)),
      );
    }
    // Codes must be long.
    await assertFails(
      db(OWNER).doc('sharedGoalInvitations/SHORT').set(invitation('SHORT')),
    );

    // Anyone signed in with the code can read and use an open one, once.
    await assertSucceeds(otherDb().doc(`sharedGoalInvitations/${open}`).get());
    await assertFails(db(null).doc(`sharedGoalInvitations/${open}`).get());
    await assertSucceeds(accept(otherDb(), OTHER, open));

    // Only the addressee rejects; only the sender revokes.
    const status = (s) => ({ status: s, updatedAt: Date.now(), serverUpdatedAt: now() });
    await assertFails(
      otherDb().doc(`sharedGoalInvitations/${forFriend}`).update(status('rejected')),
    );
    await assertSucceeds(
      friendDb().doc(`sharedGoalInvitations/${forFriend}`).update(status('rejected')),
    );
    await assertFails(accept(friendDb(), FRIEND, forFriend));

    await assertFails(
      friendDb().doc(`sharedGoalInvitations/${revoked}`).update(status('revoked')),
    );
    await assertSucceeds(
      db(OWNER).doc(`sharedGoalInvitations/${revoked}`).update(status('revoked')),
    );
    await assertFails(accept(friendDb(), FRIEND, revoked));

    // Expired invitations cannot be accepted.
    await assertFails(accept(friendDb(), FRIEND, expired));

    // A member who leaves loses access.
    await assertSucceeds(
      otherDb().doc(`${SG}/members/${OTHER}`).update({
        status: 'left',
        canContribute: true,
        canWithdraw: false,
        serverUpdatedAt: now(),
      }),
    );
    await assertFails(otherDb().doc(SG).get());
  });
  // ---------------------------------------------------- notifications

  function device(id, extra = {}) {
    return {
      deviceId: id,
      token: 'fcm-token-1',
      platform: 'android',
      currencyCode: 'AED',
      householdActivity: true,
      householdBudgets: true,
      savingsUpdates: false,
      updatedAt: 1_700_000_000_000,
      serverUpdatedAt: now(),
      ...extra,
    };
  }

  test('device registrations are private to their owner', async () => {
    const ref = db(OWNER).doc(`users/${OWNER}/devices/d1`);
    await assertSucceeds(ref.set(device('d1')));
    await assertSucceeds(ref.get());
    await assertSucceeds(ref.set(device('d1', { token: 'rotated' })));
    await assertFails(db(PARTNER).doc(`users/${OWNER}/devices/d1`).get());
    await assertFails(
      db(PARTNER).doc(`users/${OWNER}/devices/d2`).set(device('d2')),
    );
    await assertFails(db(PARTNER).doc(`users/${OWNER}/devices/d1`).delete());
    // Signing out removes the registration.
    await assertSucceeds(ref.delete());
  });

  test('device registrations are validated', async () => {
    const ref = db(OWNER).doc(`users/${OWNER}/devices/d1`);
    await assertFails(ref.set(device('other')));
    await assertFails(ref.set(device('d1', { token: '' })));
    await assertFails(ref.set(device('d1', { platform: 'toaster' })));
    await assertFails(ref.set(device('d1', { currencyCode: 'DIRHAM' })));
    await assertFails(ref.set(device('d1', { householdActivity: 'yes' })));
    await assertFails(ref.set(device('d1', { serverUpdatedAt: 5 })));
    await assertFails(ref.set(device('d1', { admin: true })));
  });

  function budgetAlert(uid, id, extra = {}) {
    return {
      id,
      key: 'monthly.20261101',
      level: 'warning',
      title: 'Budget warning',
      message: '92% of the shared monthly budget used. AED 120.00 left.',
      createdBy: uid,
      createdByName: 'Omar',
      createdAt: 1_700_000_000_000,
      periodEnd: 1_700_100_000_000,
      serverCreatedAt: now(),
      ...extra,
    };
  }

  test('household budget alerts: members create once, nobody edits', async () => {
    const id = 'monthly.20261101.warning';
    const path = `households/${HID}/budgetAlerts/${id}`;
    await assertFails(db(STRANGER).doc(path).set(budgetAlert(STRANGER, id)));
    await assertFails(db(REMOVED).doc(path).set(budgetAlert(REMOVED, id)));
    await assertFails(db(OWNER).doc(path).set(budgetAlert(PARTNER, id)));
    await assertFails(
      db(OWNER).doc(path).set(budgetAlert(OWNER, id, { level: 'panic' })),
    );
    await assertFails(
      db(OWNER).doc(path).set(budgetAlert(OWNER, id, { extra: 1 })),
    );
    await assertFails(
      db(OWNER).doc(`households/${HID}/budgetAlerts/bad id!`).set(
        budgetAlert(OWNER, 'bad id!'),
      ),
    );
    await assertSucceeds(db(OWNER).doc(path).set(budgetAlert(OWNER, id)));
    await assertSucceeds(db(PARTNER).doc(path).get());
    await assertFails(db(STRANGER).doc(path).get());
    // The partner's app sees the same crossing later: already recorded.
    await assertFails(db(PARTNER).doc(path).set(budgetAlert(PARTNER, id)));
    await assertFails(db(OWNER).doc(path).delete());
  });

  // ------------------------------------------------------------ lending

  /** A loan exactly as Loan.toCloudMap + FirestoreLoanStore write it. */
  function loanDoc(id, uid, extra = {}) {
    return {
      borrowerName: 'John',
      borrowerPhone: '',
      borrowerEmail: '',
      principalMinor: 100000,
      interestRateBp: 0,
      interestMinor: 0,
      totalOwedMinor: 100000,
      lentDate: 1_700_000_000_000,
      repaymentType: 'oneTime',
      installmentMinor: null,
      firstDueDate: null,
      dueDay: null,
      endDate: null,
      dueDate: 1_710_000_000_000,
      notes: '',
      schedule: [
        { id: `${id}-1`, number: 1, dueDate: 1_710_000_000_000, expectedMinor: 100000 },
      ],
      createdAt: 1_700_000_000_000,
      createdBy: uid,
      createdByName: 'Someone',
      id,
      updatedAt: 1_700_000_000_000,
      deleted: false,
      updatedBy: uid,
      serverUpdatedAt: now(),
      ...extra,
    };
  }

  function repaymentDoc(id, loanId, uid, amount, extra = {}) {
    return {
      loanId,
      amountMinor: amount,
      date: 1_705_000_000_000,
      method: 'cash',
      note: '',
      installmentId: `${loanId}-1`,
      createdAt: 1_705_000_000_000,
      userUid: uid,
      userName: 'Someone',
      voided: false,
      voidedAt: null,
      voidedBy: null,
      voidReason: '',
      id,
      updatedAt: 1_705_000_000_000,
      deleted: false,
      serverUpdatedAt: now(),
      ...extra,
    };
  }

  function remindersDoc(loanId, uid, notifyUids, extra = {}) {
    return {
      loanId,
      enabled: true,
      paused: false,
      offsets: [-3, 0, 1, 3, 7],
      notifyUids,
      updatedBy: uid,
      id: loanId,
      updatedAt: 1_700_000_000_000,
      deleted: false,
      serverUpdatedAt: now(),
      ...extra,
    };
  }

  /** A repayment and the loan's new total, in one batch (like the app's
   * transaction). */
  function repay(client, base, loanId, repayment, newTotal) {
    const batch = client.batch();
    batch.set(client.doc(`${base}/loanRepayments/${repayment.id}`), repayment);
    batch.update(client.doc(`${base}/loans/${loanId}`), {
      receivedMinor: newTotal,
      lastRepaymentId: repayment.id,
      lastRepaymentOp: 'add',
    });
    return batch.commit();
  }

  function voidRepayment(client, base, loanId, repaymentId, uid, newTotal) {
    const batch = client.batch();
    batch.update(client.doc(`${base}/loanRepayments/${repaymentId}`), {
      voided: true,
      voidedAt: 1_706_000_000_000,
      voidedBy: uid,
      voidReason: 'Entered twice',
      updatedAt: 1_706_000_000_000,
      serverUpdatedAt: now(),
    });
    batch.update(client.doc(`${base}/loans/${loanId}`), {
      receivedMinor: newTotal,
      lastRepaymentId: repaymentId,
      lastRepaymentOp: 'void',
    });
    return batch.commit();
  }

  test('personal lending is private; totals move only with repayments', async () => {
    const base = `users/${OWNER}`;
    const loan = `${base}/loans/l1`;
    await assertFails(db(STRANGER).doc(loan).set(loanDoc('l1', STRANGER)));
    await assertFails(db(null).doc(loan).set(loanDoc('l1', OWNER)));
    // Cannot start repaid, owe a different total, or claim a household.
    await assertFails(
      db(OWNER).doc(loan).set(loanDoc('l1', OWNER, { receivedMinor: 10 })),
    );
    await assertFails(
      db(OWNER).doc(loan).set(loanDoc('l1', OWNER, { totalOwedMinor: 1 })),
    );
    await assertFails(
      db(OWNER).doc(loan).set(loanDoc('l1', OWNER, { householdId: HID })),
    );
    await assertFails(
      db(OWNER).doc(loan).set(loanDoc('l1', OWNER, { principalMinor: 0, totalOwedMinor: 0 })),
    );
    // Only known interest methods.
    await assertFails(
      db(OWNER).doc(loan).set(loanDoc('l1', OWNER, { interestMethod: 'compound' })),
    );
    await assertSucceeds(
      db(OWNER).doc(loan).set(
        loanDoc('l1', OWNER, {
          interestMethod: 'reducing',
          originalInstallmentMinor: 100000,
          originalTermMonths: 1,
        }),
        { merge: true },
      ),
    );
    await assertSucceeds(db(OWNER).doc(loan).get());
    await assertFails(db(STRANGER).doc(loan).get());

    // A repayment with the matching new total, and how it was applied.
    const allocation = {
      installmentNumber: 1,
      scheduledEmiMinor: 100000,
      appliedToInstallmentMinor: 30000,
      extraPrincipalMinor: 0,
      principalBeforeMinor: 100000,
      principalAfterMinor: 70000,
      remainingInstallments: 1,
      recalculatedAt: 1_705_000_000_000,
    };
    await assertFails(
      repay(db(OWNER), base, 'l1',
        repaymentDoc('r1', 'l1', OWNER, 30000, { allocation: 'text' }), 30000),
    );
    await assertSucceeds(
      repay(db(OWNER), base, 'l1',
        repaymentDoc('r1', 'l1', OWNER, 30000, { allocation }), 30000),
    );
    // Wrong total, another user's name, re-using an ID, or more than owed.
    await assertFails(
      repay(db(OWNER), base, 'l1', repaymentDoc('r2', 'l1', OWNER, 100), 999),
    );
    await assertFails(
      repay(db(OWNER), base, 'l1', repaymentDoc('r3', 'l1', STRANGER, 100), 30100),
    );
    await assertFails(
      repay(db(OWNER), base, 'l1', repaymentDoc('r1', 'l1', OWNER, 100), 30100),
    );
    await assertFails(
      repay(db(OWNER), base, 'l1', repaymentDoc('r4', 'l1', OWNER, 70001), 100001),
    );
    // Neither the repayment alone nor the total alone.
    await assertFails(
      db(OWNER).doc(`${base}/loanRepayments/r5`).set(repaymentDoc('r5', 'l1', OWNER, 10)),
    );
    await assertFails(db(OWNER).doc(loan).update({ receivedMinor: 100000 }));
    // Repayments are never edited or deleted.
    await assertFails(
      db(OWNER).doc(`${base}/loanRepayments/r1`).update({ amountMinor: 1 }),
    );
    await assertFails(db(OWNER).doc(`${base}/loanRepayments/r1`).delete());

    // Edits keep the total and can never owe less than was repaid.
    await assertSucceeds(
      db(OWNER).doc(loan).set(
        { borrowerName: 'John Smith', updatedAt: 2, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    await assertFails(
      db(OWNER).doc(loan).set(
        { principalMinor: 20000, totalOwedMinor: 20000, updatedAt: 3, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    await assertFails(
      db(OWNER).doc(loan).set(
        { receivedMinor: 0, updatedAt: 3, serverUpdatedAt: now() },
        { merge: true },
      ),
    );

    // Voiding lowers the total by the repayment's amount, once.
    await assertFails(voidRepayment(db(OWNER), base, 'l1', 'r1', OWNER, 10));
    await assertFails(voidRepayment(db(OWNER), base, 'l1', 'r1', STRANGER, 0));
    await assertSucceeds(voidRepayment(db(OWNER), base, 'l1', 'r1', OWNER, 0));
    await assertFails(voidRepayment(db(OWNER), base, 'l1', 'r1', OWNER, -30000));

    // Soft deletion, and a tombstone for a loan never uploaded.
    await assertSucceeds(
      db(OWNER).doc(loan).set(
        { id: 'l1', deleted: true, deletedAt: 4, updatedAt: 4, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    await assertSucceeds(
      db(OWNER).doc(`${base}/loans/never`).set(
        { id: 'never', deleted: true, deletedAt: 4, updatedAt: 4, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    await assertFails(db(OWNER).doc(loan).delete());
    // No repayments for a deleted loan.
    await assertFails(
      repay(db(OWNER), base, 'l1', repaymentDoc('r6', 'l1', OWNER, 10), 10),
    );

    // Reminder settings: owner only.
    const reminders = `${base}/loanReminders/l1`;
    await assertSucceeds(db(OWNER).doc(reminders).set(remindersDoc('l1', OWNER, [])));
    await assertFails(db(STRANGER).doc(reminders).get());
    await assertFails(
      db(STRANGER).doc(`users/${STRANGER}/loanReminders/l1`).set(
        remindersDoc('l1', OWNER, []),
      ),
    );
  });

  test('household lending: members record loans and repayments', async () => {
    const base = `households/${HID}`;
    const loan = `${base}/loans/h1`;
    const household = (uid, extra = {}) =>
      loanDoc('h1', uid, { householdId: HID, ...extra });

    await assertFails(db(STRANGER).doc(loan).set(household(STRANGER)));
    await assertFails(db(REMOVED).doc(loan).set(household(REMOVED)));
    // The creator and editor must be the caller.
    await assertFails(db(PARTNER).doc(loan).set(household(OWNER)));
    await assertSucceeds(
      db(PARTNER).doc(loan).set(household(PARTNER), { merge: true }),
    );
    await assertSucceeds(db(OWNER).doc(loan).get());
    await assertFails(db(STRANGER).doc(loan).get());
    await assertFails(db(REMOVED).doc(loan).get());

    // Any active member records a repayment, attributed to themselves.
    await assertSucceeds(
      repay(db(OWNER), base, 'h1', repaymentDoc('r1', 'h1', OWNER, 40000), 40000),
    );
    await assertFails(
      repay(db(STRANGER), base, 'h1', repaymentDoc('r2', 'h1', STRANGER, 100), 40100),
    );
    await assertFails(
      repay(db(PARTNER), base, 'h1', repaymentDoc('r3', 'h1', OWNER, 100), 40100),
    );
    // A stale concurrent write computed from an old total is refused.
    await assertFails(
      repay(db(PARTNER), base, 'h1', repaymentDoc('r4', 'h1', PARTNER, 60000), 60000),
    );
    await assertSucceeds(
      repay(db(PARTNER), base, 'h1', repaymentDoc('r4', 'h1', PARTNER, 60000), 100000),
    );
    // Paid in full: nothing more fits.
    await assertFails(
      repay(db(PARTNER), base, 'h1', repaymentDoc('r5', 'h1', PARTNER, 1), 100001),
    );
    await assertSucceeds(db(PARTNER).doc(`${base}/loanRepayments/r1`).get());
    await assertFails(db(REMOVED).doc(`${base}/loanRepayments/r1`).get());

    // Edits by any member keep the creator; only the creator or the owner
    // deletes.
    await assertSucceeds(
      db(OWNER).doc(loan).set(
        { notes: 'Car repair', updatedAt: 2, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    await assertFails(
      db(OWNER).doc(loan).set(
        { createdBy: OWNER, updatedAt: 3, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
    const ownersLoan = `${base}/loans/h2`;
    await assertSucceeds(
      db(OWNER).doc(ownersLoan).set(loanDoc('h2', OWNER, { householdId: HID })),
    );
    const deletion = (uid) => ({
      id: 'h2', deleted: true, deletedAt: 5, updatedAt: 5, updatedBy: uid, serverUpdatedAt: now(),
    });
    await assertFails(db(PARTNER).doc(ownersLoan).set(deletion(PARTNER), { merge: true }));
    await assertSucceeds(db(OWNER).doc(ownersLoan).set(deletion(OWNER), { merge: true }));
    await assertSucceeds(
      db(OWNER).doc(loan).set(
        { id: 'h1', deleted: true, deletedAt: 6, updatedAt: 6, updatedBy: OWNER, serverUpdatedAt: now() },
        { merge: true },
      ),
    );
  });

  test('household reminder recipients: the owner decides', async () => {
    const path = `households/${HID}/loanReminders/h1`;
    // A member recording a loan may only name the owner.
    await assertFails(
      db(PARTNER).doc(path).set(remindersDoc('h1', PARTNER, [PARTNER])),
    );
    await assertFails(
      db(PARTNER).doc(path).set(remindersDoc('h1', PARTNER, [OWNER, PARTNER])),
    );
    await assertFails(
      db(STRANGER).doc(path).set(remindersDoc('h1', STRANGER, [OWNER])),
    );
    await assertSucceeds(
      db(PARTNER).doc(path).set(remindersDoc('h1', PARTNER, [OWNER])),
    );
    // Members cannot add themselves (or pause) afterwards.
    await assertFails(
      db(PARTNER).doc(path).set(
        remindersDoc('h1', PARTNER, [OWNER, PARTNER], { updatedAt: 2 }),
      ),
    );
    await assertFails(
      db(PARTNER).doc(path).set(
        remindersDoc('h1', PARTNER, [OWNER], { paused: true, updatedAt: 2 }),
      ),
    );
    // Nor impersonate the owner.
    await assertFails(
      db(PARTNER).doc(path).set(
        remindersDoc('h1', OWNER, [OWNER, PARTNER], { updatedAt: 2 }),
      ),
    );
    // The owner selects, deselects, or turns everyone off.
    await assertSucceeds(
      db(OWNER).doc(path).set(
        remindersDoc('h1', OWNER, [OWNER, PARTNER], { updatedAt: 3 }),
      ),
    );
    await assertSucceeds(
      db(OWNER).doc(path).set(remindersDoc('h1', OWNER, [], { updatedAt: 4 })),
    );
    await assertSucceeds(db(PARTNER).doc(path).get());
    await assertFails(db(REMOVED).doc(path).get());
    await assertFails(db(STRANGER).doc(path).get());
    await assertFails(db(OWNER).doc(path).delete());
  });
});
