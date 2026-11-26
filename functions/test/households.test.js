'use strict';

// Household handlers against the Firestore emulator:
//   npm test   (runs `firebase emulators:exec --only firestore,storage ...`)

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const PROJECT = 'demo-moneymate';
const emulated = !!process.env.FIRESTORE_EMULATOR_HOST;

const skip = emulated ? false : 'needs the Firestore emulator (npm test)';

let db;
let h;
let clock = 1_700_000_000_000;
const deps = {
  now: () => clock,
  randomBytes: (n) => crypto.randomBytes(n),
};

const owner = {
  uid: 'owner-uid',
  token: { name: 'Omar', email: 'omar@example.com', email_verified: true },
};
const partner = {
  uid: 'partner-uid',
  token: { name: 'Sara', email: 'sara@example.com', email_verified: true },
};
const stranger = {
  uid: 'stranger-uid',
  token: { name: 'Eve', email: 'eve@example.com', email_verified: true },
};

async function clear() {
  await fetch(
    `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`,
    { method: 'DELETE' },
  );
}

async function rejects(promise, code) {
  await assert.rejects(promise, (e) => {
    assert.equal(e.code, code, e.message);
    return true;
  });
}

test.describe('household functions', { skip }, () => {
  test.before(() => {
    const { initializeApp } = require('firebase-admin/app');
    const { getFirestore } = require('firebase-admin/firestore');
    initializeApp({ projectId: PROJECT });
    db = getFirestore();
    h = require('../src/households');
  });

  test.beforeEach(async () => {
    clock = 1_700_000_000_000;
    await clear();
  });

  async function householdWithPartner() {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: 'Khan family' },
      deps,
    );
    const { code } = await h.createInvitation(db, owner, { householdId }, deps);
    await h.acceptInvitation(db, partner, { code }, deps);
    return householdId;
  }

  test('creating a household makes the creator its owner', async () => {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: '  Khan family ' },
      deps,
    );
    const household = await db.doc(`households/${householdId}`).get();
    assert.equal(household.get('name'), 'Khan family');
    assert.equal(household.get('ownerUid'), owner.uid);
    const member = await db
      .doc(`households/${householdId}/members/${owner.uid}`)
      .get();
    assert.equal(member.get('role'), 'owner');
    assert.equal(member.get('status'), 'active');
    assert.equal(member.get('displayName'), 'Omar');
    const membership = await db
      .doc(`users/${owner.uid}/memberships/${householdId}`)
      .get();
    assert.equal(membership.get('status'), 'active');
  });

  test('a user cannot create a second household', async () => {
    await h.createHousehold(db, owner, { name: 'One' }, deps);
    await rejects(
      h.createHousehold(db, owner, { name: 'Two' }, deps),
      'failed-precondition',
    );
  });

  test('requests without sign-in are refused', async () => {
    await rejects(
      h.createHousehold(db, null, { name: 'X' }, deps),
      'unauthenticated',
    );
  });

  test('accounts with an unverified email are refused', async () => {
    const unverified = {
      uid: 'new-uid',
      token: { email: 'new@example.com', email_verified: false },
    };
    await rejects(
      h.createHousehold(db, unverified, { name: 'X' }, deps),
      'permission-denied',
    );
    const noClaim = { uid: 'new-uid', token: { email: 'new@example.com' } };
    await rejects(
      h.createHousehold(db, noClaim, { name: 'X' }, deps),
      'permission-denied',
    );
  });

  test('an invitation is accepted once and creates an active member', async () => {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: 'Khan family' },
      deps,
    );
    const invite = await h.createInvitation(db, owner, { householdId }, deps);
    assert.equal(invite.code.length, 10);

    const preview = await h.previewInvitation(
      db,
      partner,
      { code: `${invite.code.slice(0, 5)}-${invite.code.slice(5)}` },
      deps,
    );
    assert.equal(preview.householdName, 'Khan family');
    assert.equal(preview.invitedByName, 'Omar');

    const result = await h.acceptInvitation(
      db,
      partner,
      { code: invite.code },
      deps,
    );
    assert.equal(result.householdId, householdId);
    const member = await db
      .doc(`households/${householdId}/members/${partner.uid}`)
      .get();
    assert.equal(member.get('role'), 'member');
    assert.equal(member.get('status'), 'active');
    const invitation = await db
      .doc(`households/${householdId}/invitations/${invite.invitationId}`)
      .get();
    assert.equal(invitation.get('status'), 'accepted');
    assert.equal(invitation.get('acceptedBy'), partner.uid);

    // One-time: the code no longer works for anyone.
    await rejects(
      h.acceptInvitation(db, stranger, { code: invite.code }, deps),
      'not-found',
    );
    const household = await db.doc(`households/${householdId}`).get();
    assert.equal(household.get('memberCount'), 2);
  });

  test('expired invitations are rejected and marked expired', async () => {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: 'Home' },
      deps,
    );
    const invite = await h.createInvitation(
      db,
      owner,
      { householdId, expiresInDays: 1 },
      deps,
    );
    clock += 24 * 60 * 60 * 1000;
    await rejects(
      h.acceptInvitation(db, partner, { code: invite.code }, deps),
      'deadline-exceeded',
    );
    const invitation = await db
      .doc(`households/${householdId}/invitations/${invite.invitationId}`)
      .get();
    assert.equal(invitation.get('status'), 'expired');
    const member = await db
      .doc(`households/${householdId}/members/${partner.uid}`)
      .get();
    assert.equal(member.exists, false);
  });

  test('revoked invitations cannot be used', async () => {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: 'Home' },
      deps,
    );
    const invite = await h.createInvitation(db, owner, { householdId }, deps);
    await h.revokeInvitation(
      db,
      owner,
      { householdId, invitationId: invite.invitationId },
      deps,
    );
    await rejects(
      h.acceptInvitation(db, partner, { code: invite.code }, deps),
      'not-found',
    );
  });

  test('email-bound invitations only work for the invited account', async () => {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: 'Home' },
      deps,
    );
    const invite = await h.createInvitation(
      db,
      owner,
      { householdId, email: 'Sara@Example.com' },
      deps,
    );
    await rejects(
      h.acceptInvitation(db, stranger, { code: invite.code }, deps),
      'permission-denied',
    );
    await h.acceptInvitation(db, partner, { code: invite.code }, deps);
  });

  test('members cannot manage invitations or members', async () => {
    const householdId = await householdWithPartner();
    await rejects(
      h.createInvitation(db, partner, { householdId }, deps),
      'permission-denied',
    );
    await rejects(
      h.removeMember(db, partner, { householdId, memberUid: owner.uid }, deps),
      'permission-denied',
    );
    await rejects(
      h.transferOwnership(
        db,
        partner,
        { householdId, newOwnerUid: owner.uid },
        deps,
      ),
      'permission-denied',
    );
    await rejects(
      h.updateHousehold(db, partner, { householdId, name: 'Mine' }, deps),
      'permission-denied',
    );
    await rejects(
      h.deleteHousehold(db, partner, { householdId }, deps),
      'permission-denied',
    );
  });

  test('outsiders cannot act on a household', async () => {
    const householdId = await householdWithPartner();
    await rejects(
      h.createInvitation(db, stranger, { householdId }, deps),
      'permission-denied',
    );
    await rejects(
      h.leaveHousehold(db, stranger, { householdId }, deps),
      'permission-denied',
    );
  });

  test('a member cannot join twice', async () => {
    const householdId = await householdWithPartner();
    const again = await h.createInvitation(db, owner, { householdId }, deps);
    await rejects(
      h.acceptInvitation(db, partner, { code: again.code }, deps),
      'already-exists',
    );
  });

  test('a user in another household cannot join', async () => {
    const householdId = await householdWithPartner();
    await h.createHousehold(db, stranger, { name: 'Other' }, deps);
    const invite = await h.createInvitation(db, owner, { householdId }, deps);
    await rejects(
      h.acceptInvitation(db, stranger, { code: invite.code }, deps),
      'failed-precondition',
    );
  });

  test('removing a member revokes access but keeps the household data', async () => {
    const householdId = await householdWithPartner();
    await db
      .doc(`households/${householdId}/transactions/t1`)
      .set({ id: 't1', amountMinor: 100 });
    await h.removeMember(
      db,
      owner,
      { householdId, memberUid: partner.uid },
      deps,
    );
    const member = await db
      .doc(`households/${householdId}/members/${partner.uid}`)
      .get();
    assert.equal(member.get('status'), 'removed');
    const membership = await db
      .doc(`users/${partner.uid}/memberships/${householdId}`)
      .get();
    assert.equal(membership.exists, false);
    const tx = await db.doc(`households/${householdId}/transactions/t1`).get();
    assert.equal(tx.exists, true);

    // A removed member can be invited back without a duplicate member.
    const invite = await h.createInvitation(db, owner, { householdId }, deps);
    await h.acceptInvitation(db, partner, { code: invite.code }, deps);
    const members = await db
      .collection(`households/${householdId}/members`)
      .get();
    assert.equal(members.size, 2);
  });

  test('a member refreshes only their own profile from their account', async () => {
    const householdId = await householdWithPartner();
    const photo = 'https://firebasestorage.googleapis.com/v0/b/x/o/p.jpg';
    const accounts = {
      [partner.uid]: { displayName: 'Sara K', email: 'sara@example.com', photoURL: photo },
    };
    const withUsers = { ...deps, getUser: async (uid) => accounts[uid] ?? {} };

    await h.refreshMemberProfile(db, partner, { householdId }, withUsers);
    const member = await db
      .doc(`households/${householdId}/members/${partner.uid}`)
      .get();
    assert.equal(member.get('photoUrl'), photo);
    assert.equal(member.get('displayName'), 'Sara K');
    assert.equal(member.get('role'), 'member');
    assert.equal(member.get('status'), 'active');

    // A removed photo is cleared too.
    accounts[partner.uid] = { displayName: 'Sara K', email: 'sara@example.com' };
    await h.refreshMemberProfile(db, partner, { householdId }, withUsers);
    const cleared = await db
      .doc(`households/${householdId}/members/${partner.uid}`)
      .get();
    assert.equal(cleared.get('photoUrl'), null);

    // The owner's document is untouched, and outsiders are refused.
    const ownerDoc = await db
      .doc(`households/${householdId}/members/${owner.uid}`)
      .get();
    assert.equal(ownerDoc.get('displayName'), 'Omar');
    await rejects(
      h.refreshMemberProfile(db, stranger, { householdId }, withUsers),
      'permission-denied',
    );
    await rejects(
      h.refreshMemberProfile(db, null, { householdId }, withUsers),
      'unauthenticated',
    );
  });

  test('the owner must transfer ownership before leaving', async () => {
    const householdId = await householdWithPartner();
    await rejects(
      h.leaveHousehold(db, owner, { householdId }, deps),
      'failed-precondition',
    );
    await h.transferOwnership(
      db,
      owner,
      { householdId, newOwnerUid: partner.uid },
      deps,
    );
    const household = await db.doc(`households/${householdId}`).get();
    assert.equal(household.get('ownerUid'), partner.uid);
    const oldOwner = await db
      .doc(`households/${householdId}/members/${owner.uid}`)
      .get();
    assert.equal(oldOwner.get('role'), 'member');

    await h.leaveHousehold(db, owner, { householdId }, deps);
    const left = await db
      .doc(`households/${householdId}/members/${owner.uid}`)
      .get();
    assert.equal(left.get('status'), 'left');
  });

  test('a household with other members cannot be deleted', async () => {
    const householdId = await householdWithPartner();
    await rejects(
      h.deleteHousehold(db, owner, { householdId }, deps),
      'failed-precondition',
    );
  });

  test('deleting a household removes it and its shared data', async () => {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: 'Home' },
      deps,
    );
    const invite = await h.createInvitation(db, owner, { householdId }, deps);
    await db
      .doc(`households/${householdId}/transactions/t1`)
      .set({ id: 't1', amountMinor: 100 });
    await h.deleteHousehold(db, owner, { householdId }, deps);
    assert.equal((await db.doc(`households/${householdId}`).get()).exists, false);
    assert.equal(
      (await db.doc(`households/${householdId}/transactions/t1`).get()).exists,
      false,
    );
    assert.equal(
      (await db.doc(`invitationCodes/${invite.code}`).get()).exists,
      false,
    );
    assert.equal(
      (await db.doc(`users/${owner.uid}/memberships/${householdId}`).get())
        .exists,
      false,
    );
  });

  test('too many open invitations are refused', async () => {
    const { householdId } = await h.createHousehold(
      db,
      owner,
      { name: 'Home' },
      deps,
    );
    for (let i = 0; i < 10; i++) {
      await h.createInvitation(db, owner, { householdId }, deps);
    }
    await rejects(
      h.createInvitation(db, owner, { householdId }, deps),
      'resource-exhausted',
    );
  });
});
