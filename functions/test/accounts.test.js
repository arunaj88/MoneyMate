'use strict';

// Existing-account exemption from email verification:
//   node --test test/accounts.test.js   (no emulator needed)

const test = require('node:test');
const assert = require('node:assert/strict');

const accounts = require('../src/accounts');

const CUTOFF = Date.parse('2026-11-28T00:00:00Z');

function fakeDeps(users) {
  const updates = [];
  return {
    updates,
    getUser: async (uid) => {
      const user = users[uid];
      if (!user) {
        const error = new Error('no user');
        error.code = 'auth/user-not-found';
        throw error;
      }
      return { uid, ...user };
    },
    updateUser: async (uid, props) => {
      updates.push({ uid, props });
      Object.assign(users[uid], props);
      return { uid, ...users[uid] };
    },
  };
}

const call = (uid, deps) =>
  accounts.exemptExistingAccount(null, uid ? { uid, token: {} } : null, {}, deps, CUTOFF);

test('accounts created before the cutoff are marked verified', async () => {
  const deps = fakeDeps({
    old: {
      emailVerified: false,
      metadata: { creationTime: 'Mon, 23 Nov 2026 10:00:00 GMT' },
    },
  });
  assert.deepEqual(await call('old', deps), { status: 'exempted' });
  assert.deepEqual(deps.updates, [{ uid: 'old', props: { emailVerified: true } }]);
  // Calling again changes nothing.
  assert.deepEqual(await call('old', deps), { status: 'verified' });
  assert.equal(deps.updates.length, 1);
});

test('accounts created on or after the cutoff must verify', async () => {
  const deps = fakeDeps({
    atCutoff: {
      emailVerified: false,
      metadata: { creationTime: 'Sat, 28 Nov 2026 00:00:00 GMT' },
    },
    later: {
      emailVerified: false,
      metadata: { creationTime: 'Tue, 01 Dec 2026 08:00:00 GMT' },
    },
    unknown: { emailVerified: false, metadata: {} },
  });
  for (const uid of ['atCutoff', 'later', 'unknown']) {
    assert.deepEqual(await call(uid, deps), { status: 'verification-required' });
  }
  assert.equal(deps.updates.length, 0);
});

test('the creation time comes from Firebase Auth, not the request', async () => {
  const deps = fakeDeps({
    fresh: {
      emailVerified: false,
      metadata: { creationTime: 'Tue, 01 Dec 2026 08:00:00 GMT' },
    },
  });
  const result = await accounts.exemptExistingAccount(
    null,
    { uid: 'fresh', token: {} },
    { creationTime: 'Mon, 01 Jan 2024 00:00:00 GMT' },
    deps,
    CUTOFF,
  );
  assert.deepEqual(result, { status: 'verification-required' });
  assert.equal(deps.updates.length, 0);
});

test('verified accounts (e.g. Google) are left alone', async () => {
  const deps = fakeDeps({
    google: {
      emailVerified: true,
      metadata: { creationTime: 'Tue, 01 Dec 2026 08:00:00 GMT' },
    },
  });
  assert.deepEqual(await call('google', deps), { status: 'verified' });
  assert.equal(deps.updates.length, 0);
});

test('requires sign-in and an existing account', async () => {
  const deps = fakeDeps({});
  for (const uid of [null, 'gone']) {
    await assert.rejects(call(uid, deps), (e) => {
      assert.equal(e.code, 'unauthenticated');
      return true;
    });
  }
});

test('the default cutoff is a valid date', () => {
  assert.ok(Number.isFinite(accounts.VERIFICATION_REQUIRED_FROM));
  assert.ok(
    accounts.isExistingAccount({ metadata: { creationTime: '2020-01-01T00:00:00Z' } }),
  );
});
