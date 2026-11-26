'use strict';

/**
 * Email verification for accounts that existed before it was introduced.
 *
 * New email/password accounts verify their address with Firebase's
 * verification link, and the security rules require a verified email.
 * Accounts created before [VERIFICATION_REQUIRED_FROM] are not asked to
 * verify: the app calls exemptExistingAccount, which marks such an account
 * verified with the Admin SDK so the rules let it in.
 *
 * The creation time comes from Firebase Authentication (the account's own
 * metadata), never from the request, so a new account cannot claim to be
 * an old one.
 *
 * Handlers take (db, auth, data, deps) like households.js:
 *   deps – {getUser(uid): Promise<UserRecord>,
 *           updateUser(uid, props): Promise<UserRecord>}
 */

const { ValidationError } = require('./logic');

/**
 * Accounts created before this moment (UTC) skip email verification.
 * Set it to when the version that requires verification is released.
 */
const VERIFICATION_REQUIRED_FROM = Date.parse('2026-11-28T00:00:00Z');

/** When the account was created (ms), or NaN if unknown. */
function creationTime(user) {
  return Date.parse(user?.metadata?.creationTime ?? '');
}

/** Whether [user] predates required verification. */
function isExistingAccount(user, cutoff = VERIFICATION_REQUIRED_FROM) {
  const created = creationTime(user);
  return Number.isFinite(created) && created < cutoff;
}

/**
 * Marks the caller's account verified if it was created before email
 * verification was required.
 * @returns {{status: 'verified'|'exempted'|'verification-required'}}
 */
async function exemptExistingAccount(_db, auth, _data, deps, cutoff) {
  if (!auth || !auth.uid) {
    throw new ValidationError(
      'unauthenticated',
      'Your session has expired. Please sign in again.',
    );
  }
  let user;
  try {
    user = await deps.getUser(auth.uid);
  } catch (error) {
    if (error?.code === 'auth/user-not-found') {
      throw new ValidationError(
        'unauthenticated',
        'Your session has expired. Please sign in again.',
      );
    }
    throw error;
  }
  if (user.emailVerified) return { status: 'verified' };
  if (!isExistingAccount(user, cutoff ?? VERIFICATION_REQUIRED_FROM)) {
    return { status: 'verification-required' };
  }
  await deps.updateUser(auth.uid, { emailVerified: true });
  return { status: 'exempted' };
}

module.exports = {
  VERIFICATION_REQUIRED_FROM,
  isExistingAccount,
  exemptExistingAccount,
};
