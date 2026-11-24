'use strict';

// firestore.rules against the documents the app actually writes:
//   npm test   (runs `firebase emulators:exec --only firestore ...`)

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

function db(uid) {
  return uid
    ? env.authenticatedContext(uid).firestore()
    : env.unauthenticatedContext().firestore();
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
});
