'use strict';

/**
 * Household management handlers. Every change to households, members and
 * invitations happens here with admin rights; the security rules give
 * clients no write access to those documents.
 *
 * Each handler takes (db, auth, data, deps) so it can be tested against the
 * Firestore emulator without deploying:
 *   db    – admin Firestore instance
 *   auth  – the callable request's auth ({uid, token})
 *   data  – the request payload
 *   deps  – {now(): number, randomBytes(n): Uint8Array}
 */

const { FieldValue, Timestamp } = require('firebase-admin/firestore');
const logic = require('./logic');

const { ValidationError } = logic;

const HOUSEHOLDS = 'households';
const MEMBERS = 'members';
const INVITATIONS = 'invitations';
const USERS = 'users';
const MEMBERSHIPS = 'memberships';
const INVITATION_CODES = 'invitationCodes';

function fail(code, message) {
  return new ValidationError(code, message);
}

function requireAuth(auth) {
  if (!auth || !auth.uid) {
    throw fail('unauthenticated', 'Please sign in to continue.');
  }
  return auth.uid;
}

function requireString(value, name) {
  if (typeof value !== 'string' || !value || value.length > 128) {
    throw fail('invalid-argument', `Missing or invalid ${name}.`);
  }
  return value;
}

const refs = (db) => ({
  household: (hid) => db.collection(HOUSEHOLDS).doc(hid),
  member: (hid, uid) =>
    db.collection(HOUSEHOLDS).doc(hid).collection(MEMBERS).doc(uid),
  members: (hid) => db.collection(HOUSEHOLDS).doc(hid).collection(MEMBERS),
  invitation: (hid, id) =>
    db.collection(HOUSEHOLDS).doc(hid).collection(INVITATIONS).doc(id),
  invitations: (hid) =>
    db.collection(HOUSEHOLDS).doc(hid).collection(INVITATIONS),
  membership: (uid, hid) =>
    db.collection(USERS).doc(uid).collection(MEMBERSHIPS).doc(hid),
  memberships: (uid) => db.collection(USERS).doc(uid).collection(MEMBERSHIPS),
  code: (code) => db.collection(INVITATION_CODES).doc(code),
});

/**
 * Loads the household and the caller's member document inside [tx] and
 * checks the caller is an active member (and the owner, when [owner]).
 */
async function requireMember(tx, db, hid, uid, { owner = false } = {}) {
  const r = refs(db);
  const [household, member] = await Promise.all([
    tx.get(r.household(hid)),
    tx.get(r.member(hid, uid)),
  ]);
  if (!household.exists || household.get('status') !== 'active') {
    throw fail('not-found', 'This household no longer exists.');
  }
  if (!member.exists || member.get('status') !== 'active') {
    throw fail('permission-denied', 'You are not a member of this household.');
  }
  if (owner && household.get('ownerUid') !== uid) {
    throw fail(
      'permission-denied',
      'Only the household owner can do this.',
    );
  }
  return { household, member };
}

/** The caller's other active households (at most one is allowed). */
async function activeMemberships(tx, db, uid) {
  const snap = await tx.get(
    refs(db).memberships(uid).where('status', '==', 'active').limit(5),
  );
  return snap.docs.map((d) => d.id);
}

// -------------------------------------------------------------- households

async function createHousehold(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const name = logic.validateHouseholdName(data?.name);
  const r = refs(db);
  const now = Timestamp.fromMillis(deps.now());
  const ref = db.collection(HOUSEHOLDS).doc();

  await db.runTransaction(async (tx) => {
    if ((await activeMemberships(tx, db, uid)).length > 0) {
      throw fail(
        'failed-precondition',
        'You are already in a household. Leave it before creating a new one.',
      );
    }
    tx.set(ref, {
      id: ref.id,
      name,
      ownerUid: uid,
      status: 'active',
      memberCount: 1,
      createdAt: now,
      updatedAt: now,
    });
    tx.set(r.member(ref.id, uid), {
      uid,
      role: 'owner',
      status: 'active',
      ...logic.memberProfile(auth),
      joinedAt: now,
      updatedAt: now,
    });
    tx.set(r.membership(uid, ref.id), {
      householdId: ref.id,
      householdName: name,
      role: 'owner',
      status: 'active',
      joinedAt: now,
    });
  });
  return { householdId: ref.id };
}

async function updateHousehold(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const hid = requireString(data?.householdId, 'household');
  const name = logic.validateHouseholdName(data?.name);
  const r = refs(db);
  const now = Timestamp.fromMillis(deps.now());

  await db.runTransaction(async (tx) => {
    await requireMember(tx, db, hid, uid, { owner: true });
    const members = await tx.get(
      r.members(hid).where('status', '==', 'active'),
    );
    tx.update(r.household(hid), { name, updatedAt: now });
    for (const m of members.docs) {
      tx.set(
        r.membership(m.id, hid),
        { householdName: name },
        { merge: true },
      );
    }
  });
  return { ok: true };
}

// ------------------------------------------------------------- invitations

async function createInvitation(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const hid = requireString(data?.householdId, 'household');
  const email = logic.normalizeEmail(data?.email);
  const days = logic.inviteDays(data?.expiresInDays);
  const r = refs(db);
  const nowMs = deps.now();
  const now = Timestamp.fromMillis(nowMs);
  const expiresAt = Timestamp.fromMillis(nowMs + days * 24 * 60 * 60 * 1000);
  const invitationRef = r.invitations(hid).doc();

  const code = await db.runTransaction(async (tx) => {
    const { household } = await requireMember(tx, db, hid, uid, {
      owner: true,
    });
    const pending = await tx.get(
      r.invitations(hid).where('status', '==', 'pending'),
    );
    const live = pending.docs.filter(
      (d) => d.get('expiresAt').toMillis() > nowMs,
    );
    if (live.length >= logic.MAX_PENDING_INVITATIONS) {
      throw fail(
        'resource-exhausted',
        'Too many open invitations. Revoke some before creating more.',
      );
    }
    // Codes are random; retry on the (very unlikely) collision.
    let candidate = null;
    for (let i = 0; i < 5 && candidate === null; i++) {
      const next = logic.generateCode(deps.randomBytes);
      if (!(await tx.get(r.code(next))).exists) candidate = next;
    }
    if (candidate === null) {
      throw fail('aborted', 'Could not create a code. Please try again.');
    }
    tx.set(invitationRef, {
      id: invitationRef.id,
      householdId: hid,
      householdName: household.get('name'),
      code: candidate,
      status: 'pending',
      invitedEmail: email,
      createdBy: uid,
      createdByName: logic.displayName(auth),
      createdAt: now,
      expiresAt,
    });
    tx.set(r.code(candidate), {
      householdId: hid,
      invitationId: invitationRef.id,
      expiresAt,
    });
    return candidate;
  });
  return {
    invitationId: invitationRef.id,
    code,
    expiresAt: expiresAt.toMillis(),
  };
}

async function revokeInvitation(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const hid = requireString(data?.householdId, 'household');
  const invitationId = requireString(data?.invitationId, 'invitation');
  const r = refs(db);

  await db.runTransaction(async (tx) => {
    await requireMember(tx, db, hid, uid, { owner: true });
    const invitation = await tx.get(r.invitation(hid, invitationId));
    if (!invitation.exists) {
      throw fail('not-found', 'Invitation not found.');
    }
    if (invitation.get('status') !== 'pending') {
      throw fail(
        'failed-precondition',
        'This invitation is no longer pending.',
      );
    }
    tx.update(invitation.ref, {
      status: 'revoked',
      revokedBy: uid,
      revokedAt: Timestamp.fromMillis(deps.now()),
    });
    tx.delete(r.code(invitation.get('code')));
  });
  return { ok: true };
}

/** Reads the invitation behind [code] (outside or inside a transaction). */
async function loadInvitation(get, db, code) {
  const r = refs(db);
  const codeDoc = await get(r.code(code));
  if (!codeDoc.exists) {
    throw fail('not-found', 'This invitation code is not valid.');
  }
  const hid = codeDoc.get('householdId');
  const invitation = await get(r.invitation(hid, codeDoc.get('invitationId')));
  if (!invitation.exists) {
    throw fail('not-found', 'This invitation code is not valid.');
  }
  return { hid, codeDoc, invitation };
}

function invitationView(invitation) {
  return {
    status: invitation.get('status'),
    expiresAtMs: invitation.get('expiresAt').toMillis(),
    invitedEmail: invitation.get('invitedEmail') ?? null,
  };
}

function checkedCode(data) {
  const code = logic.normalizeCode(data?.code);
  if (!logic.isWellFormedCode(code)) {
    throw fail('invalid-argument', 'This invitation code is not valid.');
  }
  return code;
}

/** Marks an expired invitation as such and frees its code. */
async function expireInvitation(db, hid, invitation, code) {
  const r = refs(db);
  const batch = db.batch();
  batch.update(invitation.ref, { status: 'expired' });
  batch.delete(r.code(code));
  await batch.commit();
}

async function previewInvitation(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const code = checkedCode(data);
  const r = refs(db);
  const { hid, invitation } = await loadInvitation((ref) => ref.get(), db, code);
  const view = invitationView(invitation);
  if (logic.invitationState(view, deps.now()) === 'expired') {
    await expireInvitation(db, hid, invitation, code);
  }
  logic.checkInvitationUsable(view, auth, deps.now());

  const [household, member] = await Promise.all([
    r.household(hid).get(),
    r.member(hid, uid).get(),
  ]);
  if (!household.exists || household.get('status') !== 'active') {
    throw fail('not-found', 'This household no longer exists.');
  }
  if (member.exists && member.get('status') === 'active') {
    throw fail('already-exists', 'You are already a member of this household.');
  }
  return {
    householdName: household.get('name'),
    invitedByName: invitation.get('createdByName') ?? null,
    expiresAt: view.expiresAtMs,
  };
}

async function acceptInvitation(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const code = checkedCode(data);
  const r = refs(db);
  const nowMs = deps.now();
  const now = Timestamp.fromMillis(nowMs);

  const result = await db.runTransaction(async (tx) => {
    const { hid, invitation } = await loadInvitation(
      (ref) => tx.get(ref),
      db,
      code,
    );
    const view = invitationView(invitation);
    if (logic.invitationState(view, nowMs) === 'expired') {
      return { expired: { hid, invitation } };
    }
    // One-time use, email binding: validated inside the transaction, so
    // two people cannot accept the same code concurrently.
    logic.checkInvitationUsable(view, auth, nowMs);

    const [household, member, others] = await Promise.all([
      tx.get(r.household(hid)),
      tx.get(r.member(hid, uid)),
      activeMemberships(tx, db, uid),
    ]);
    if (!household.exists || household.get('status') !== 'active') {
      throw fail('not-found', 'This household no longer exists.');
    }
    if (member.exists && member.get('status') === 'active') {
      throw fail(
        'already-exists',
        'You are already a member of this household.',
      );
    }
    if (others.some((id) => id !== hid)) {
      throw fail(
        'failed-precondition',
        'You are already in a household. Leave it before joining another.',
      );
    }

    tx.set(r.member(hid, uid), {
      uid,
      role: 'member',
      status: 'active',
      ...logic.memberProfile(auth),
      invitedBy: invitation.get('createdBy'),
      invitationId: invitation.id,
      joinedAt: now,
      updatedAt: now,
    });
    tx.set(r.membership(uid, hid), {
      householdId: hid,
      householdName: household.get('name'),
      role: 'member',
      status: 'active',
      joinedAt: now,
    });
    tx.update(invitation.ref, {
      status: 'accepted',
      acceptedBy: uid,
      acceptedByName: logic.displayName(auth),
      acceptedAt: now,
    });
    tx.delete(r.code(code));
    tx.update(r.household(hid), {
      memberCount: FieldValue.increment(1),
      updatedAt: now,
    });
    return { householdId: hid };
  });

  if (result.expired) {
    await expireInvitation(db, result.expired.hid, result.expired.invitation, code);
    throw fail(
      'deadline-exceeded',
      'This invitation has expired. Ask for a new code.',
    );
  }
  return result;
}

// ----------------------------------------------------------------- members

async function removeMember(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const hid = requireString(data?.householdId, 'household');
  const target = requireString(data?.memberUid, 'member');
  if (target === uid) {
    throw fail(
      'failed-precondition',
      'You cannot remove yourself. Transfer ownership first, or delete the ' +
        'household.',
    );
  }
  const r = refs(db);
  const now = Timestamp.fromMillis(deps.now());

  await db.runTransaction(async (tx) => {
    await requireMember(tx, db, hid, uid, { owner: true });
    const member = await tx.get(r.member(hid, target));
    if (!member.exists || member.get('status') !== 'active') {
      throw fail('not-found', 'This person is not an active member.');
    }
    tx.update(member.ref, {
      status: 'removed',
      removedBy: uid,
      updatedAt: now,
    });
    tx.delete(r.membership(target, hid));
    tx.update(r.household(hid), {
      memberCount: FieldValue.increment(-1),
      updatedAt: now,
    });
  });
  return { ok: true };
}

async function leaveHousehold(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const hid = requireString(data?.householdId, 'household');
  const r = refs(db);
  const now = Timestamp.fromMillis(deps.now());

  await db.runTransaction(async (tx) => {
    const { household } = await requireMember(tx, db, hid, uid);
    if (household.get('ownerUid') === uid) {
      throw fail(
        'failed-precondition',
        'Make another member the owner before leaving, or delete the ' +
          'household.',
      );
    }
    tx.update(r.member(hid, uid), { status: 'left', updatedAt: now });
    tx.delete(r.membership(uid, hid));
    tx.update(r.household(hid), {
      memberCount: FieldValue.increment(-1),
      updatedAt: now,
    });
  });
  return { ok: true };
}

async function transferOwnership(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const hid = requireString(data?.householdId, 'household');
  const target = requireString(data?.newOwnerUid, 'member');
  if (target === uid) {
    throw fail('invalid-argument', 'You are already the owner.');
  }
  const r = refs(db);
  const now = Timestamp.fromMillis(deps.now());

  await db.runTransaction(async (tx) => {
    await requireMember(tx, db, hid, uid, { owner: true });
    const member = await tx.get(r.member(hid, target));
    if (!member.exists || member.get('status') !== 'active') {
      throw fail('not-found', 'Only an active member can become the owner.');
    }
    tx.update(r.household(hid), { ownerUid: target, updatedAt: now });
    tx.update(member.ref, { role: 'owner', updatedAt: now });
    tx.update(r.member(hid, uid), { role: 'member', updatedAt: now });
    tx.set(r.membership(target, hid), { role: 'owner' }, { merge: true });
    tx.set(r.membership(uid, hid), { role: 'member' }, { merge: true });
  });
  return { ok: true };
}

/**
 * Deletes the household and all its shared data. Only the owner may do it,
 * and only when no other member is left (so nobody loses shared data they
 * still rely on). Safe to call again if a previous attempt stopped midway.
 */
async function deleteHousehold(db, auth, data, deps) {
  const uid = requireAuth(auth);
  const hid = requireString(data?.householdId, 'household');
  const r = refs(db);
  const now = Timestamp.fromMillis(deps.now());

  await db.runTransaction(async (tx) => {
    const household = await tx.get(r.household(hid));
    if (!household.exists) {
      throw fail('not-found', 'This household no longer exists.');
    }
    if (household.get('ownerUid') !== uid) {
      throw fail('permission-denied', 'Only the household owner can do this.');
    }
    if (household.get('status') === 'deleted') return; // Finish the cleanup.
    const active = await tx.get(
      r.members(hid).where('status', '==', 'active'),
    );
    if (active.docs.some((d) => d.id !== uid)) {
      throw fail(
        'failed-precondition',
        'Remove the other members before deleting the household.',
      );
    }
    tx.update(household.ref, { status: 'deleted', updatedAt: now });
    tx.update(r.member(hid, uid), { status: 'left', updatedAt: now });
    tx.delete(r.membership(uid, hid));
  });

  // Access has ended (status deleted); now remove the data itself.
  const codes = await db
    .collection(INVITATION_CODES)
    .where('householdId', '==', hid)
    .get();
  const batch = db.batch();
  codes.docs.forEach((d) => batch.delete(d.ref));
  await batch.commit();
  await db.recursiveDelete(r.household(hid));
  return { ok: true };
}

module.exports = {
  createHousehold,
  updateHousehold,
  createInvitation,
  revokeInvitation,
  previewInvitation,
  acceptInvitation,
  removeMember,
  leaveHousehold,
  transferOwnership,
  deleteHousehold,
};
