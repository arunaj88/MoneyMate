'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const logic = require('../src/logic');

test('generated codes are well formed and unique', () => {
  const seen = new Set();
  for (let i = 0; i < 2000; i++) {
    const code = logic.generateCode((n) => crypto.randomBytes(n));
    assert.equal(code.length, logic.CODE_LENGTH);
    assert.ok(logic.isWellFormedCode(code), code);
    seen.add(code);
  }
  assert.equal(seen.size, 2000);
});

test('codes never contain ambiguous characters', () => {
  for (let i = 0; i < 500; i++) {
    const code = logic.generateCode((n) => crypto.randomBytes(n));
    assert.doesNotMatch(code, /[01ILO]/);
  }
});

test('normalizeCode accepts the formatted form', () => {
  assert.equal(logic.normalizeCode(' k7qm2-xrp9d '), 'K7QM2XRP9D');
  assert.equal(logic.normalizeCode(null), '');
});

test('household names are trimmed and limited', () => {
  assert.equal(logic.validateHouseholdName('  Khan family '), 'Khan family');
  assert.throws(() => logic.validateHouseholdName('   '), /name/);
  assert.throws(() => logic.validateHouseholdName('x'.repeat(41)), /40/);
});

test('emails are optional, lower-cased and validated', () => {
  assert.equal(logic.normalizeEmail(''), null);
  assert.equal(logic.normalizeEmail(undefined), null);
  assert.equal(logic.normalizeEmail(' Sara@Example.COM '), 'sara@example.com');
  assert.throws(() => logic.normalizeEmail('not-an-email'), /valid email/);
});

test('invitation validity is limited to 1-30 days', () => {
  assert.equal(logic.inviteDays(undefined), 7);
  assert.equal(logic.inviteDays(30), 30);
  assert.throws(() => logic.inviteDays(0));
  assert.throws(() => logic.inviteDays(31));
  assert.throws(() => logic.inviteDays(2.5));
});

test('a pending invitation expires at its expiry time', () => {
  const inv = { status: 'pending', expiresAtMs: 1000 };
  assert.equal(logic.invitationState(inv, 999), 'pending');
  assert.equal(logic.invitationState(inv, 1000), 'expired');
  assert.equal(
    logic.invitationState({ status: 'accepted', expiresAtMs: 1000 }, 5000),
    'accepted',
  );
});

test('only pending, unexpired invitations can be used', () => {
  const auth = { uid: 'u', token: { email: 'sara@example.com' } };
  const base = { expiresAtMs: 10_000, invitedEmail: null };
  assert.doesNotThrow(() =>
    logic.checkInvitationUsable({ ...base, status: 'pending' }, auth, 1),
  );
  assert.throws(
    () => logic.checkInvitationUsable({ ...base, status: 'pending' }, auth, 10_000),
    (e) => e.code === 'deadline-exceeded',
  );
  assert.throws(
    () => logic.checkInvitationUsable({ ...base, status: 'accepted' }, auth, 1),
    (e) => e.code === 'failed-precondition' && /already been used/.test(e.message),
  );
  assert.throws(
    () => logic.checkInvitationUsable({ ...base, status: 'revoked' }, auth, 1),
    (e) => e.code === 'failed-precondition' && /revoked/.test(e.message),
  );
});

test('email-bound invitations only work for that account', () => {
  const invitation = {
    status: 'pending',
    expiresAtMs: 10_000,
    invitedEmail: 'sara@example.com',
  };
  assert.doesNotThrow(() =>
    logic.checkInvitationUsable(
      invitation,
      { uid: 'a', token: { email: 'Sara@Example.com' } },
      1,
    ),
  );
  assert.throws(
    () =>
      logic.checkInvitationUsable(
        invitation,
        { uid: 'b', token: { email: 'eve@example.com' } },
        1,
      ),
    (e) => e.code === 'permission-denied',
  );
  assert.throws(
    () => logic.checkInvitationUsable(invitation, { uid: 'c', token: {} }, 1),
    (e) => e.code === 'permission-denied',
  );
});

test('member profile comes from the ID token', () => {
  assert.deepEqual(
    logic.memberProfile({
      token: { name: 'Sara', email: 's@example.com', picture: 'https://p' },
    }),
    { displayName: 'Sara', email: 's@example.com', photoUrl: 'https://p' },
  );
  assert.equal(logic.displayName({ token: { email: 'omar@example.com' } }), 'omar');
});
