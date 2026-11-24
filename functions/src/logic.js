'use strict';

/**
 * Pure helpers for household management. No Firebase access, so they are
 * unit-tested without an emulator.
 */

/** Unambiguous characters (no 0/O, 1/I/L): 31 symbols, ~49 bits per code. */
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 10;

const DEFAULT_INVITE_DAYS = 7;
const MAX_INVITE_DAYS = 30;
const MAX_PENDING_INVITATIONS = 10;
const MAX_NAME_LENGTH = 40;

class ValidationError extends Error {
  /**
   * @param {string} code Callable error code (e.g. 'invalid-argument').
   * @param {string} message Message shown to the user.
   */
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

/**
 * A random one-time code from [randomBytes] (crypto.randomBytes in
 * production). Uses rejection sampling so every symbol is equally likely.
 * @param {(n: number) => Uint8Array} randomBytes
 * @returns {string}
 */
function generateCode(randomBytes) {
  const n = CODE_ALPHABET.length;
  const limit = 256 - (256 % n);
  let code = '';
  while (code.length < CODE_LENGTH) {
    for (const byte of randomBytes(CODE_LENGTH * 2)) {
      if (byte >= limit) continue;
      code += CODE_ALPHABET[byte % n];
      if (code.length === CODE_LENGTH) break;
    }
  }
  return code;
}

/** Uppercases and removes spaces / dashes. */
function normalizeCode(input) {
  return String(input ?? '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}

function isWellFormedCode(code) {
  return (
    code.length === CODE_LENGTH &&
    [...code].every((c) => CODE_ALPHABET.includes(c))
  );
}

function validateHouseholdName(name) {
  const trimmed = String(name ?? '').trim();
  if (!trimmed) {
    throw new ValidationError('invalid-argument', 'Enter a household name.');
  }
  if (trimmed.length > MAX_NAME_LENGTH) {
    throw new ValidationError(
      'invalid-argument',
      `Use ${MAX_NAME_LENGTH} characters or fewer.`,
    );
  }
  return trimmed;
}

function normalizeEmail(email) {
  if (email === undefined || email === null || String(email).trim() === '') {
    return null;
  }
  const trimmed = String(email).trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(trimmed) || trimmed.length > 254) {
    throw new ValidationError('invalid-argument', 'Enter a valid email address.');
  }
  return trimmed;
}

function inviteDays(value) {
  if (value === undefined || value === null) return DEFAULT_INVITE_DAYS;
  const days = Number(value);
  if (!Number.isInteger(days) || days < 1 || days > MAX_INVITE_DAYS) {
    throw new ValidationError(
      'invalid-argument',
      `Invitations can be valid for 1 to ${MAX_INVITE_DAYS} days.`,
    );
  }
  return days;
}

/**
 * Effective state of an invitation at [nowMs]: a pending one past its
 * expiry is 'expired'.
 * @param {{status: string, expiresAtMs: number}} invitation
 */
function invitationState(invitation, nowMs) {
  if (invitation.status === 'pending' && nowMs >= invitation.expiresAtMs) {
    return 'expired';
  }
  return invitation.status;
}

/**
 * Checks that [auth] may use [invitation]. Throws a ValidationError with a
 * user-facing message otherwise.
 */
function checkInvitationUsable(invitation, auth, nowMs) {
  const state = invitationState(invitation, nowMs);
  if (state === 'expired') {
    throw new ValidationError(
      'deadline-exceeded',
      'This invitation has expired. Ask for a new code.',
    );
  }
  if (state === 'revoked') {
    throw new ValidationError(
      'failed-precondition',
      'This invitation was revoked. Ask for a new code.',
    );
  }
  if (state !== 'pending') {
    throw new ValidationError(
      'failed-precondition',
      'This invitation has already been used.',
    );
  }
  if (invitation.invitedEmail) {
    const email = String(auth.token?.email ?? '').toLowerCase();
    if (email !== invitation.invitedEmail) {
      throw new ValidationError(
        'permission-denied',
        'This invitation is for a different email address. Sign in with ' +
          'the invited account.',
      );
    }
  }
}

const MAX_PHOTO_URL_LENGTH = 2048;

/**
 * A profile photo URL other members' apps may load: https only, bounded
 * length. Anything else is dropped (avatars fall back to initials).
 */
function safePhotoUrl(value) {
  if (typeof value !== 'string' || value.length > MAX_PHOTO_URL_LENGTH) {
    return null;
  }
  try {
    return new URL(value).protocol === 'https:' ? value : null;
  } catch {
    return null;
  }
}

/** Public profile fields stored on a member document. */
function memberProfile(auth) {
  const token = auth.token ?? {};
  return {
    displayName: typeof token.name === 'string' ? token.name : null,
    email: typeof token.email === 'string' ? token.email : null,
    photoUrl: safePhotoUrl(token.picture),
  };
}

/**
 * The same fields from a Firebase Auth user record, which reflects profile
 * changes immediately (ID token claims only change on the next refresh).
 */
function accountProfile(record) {
  return {
    displayName:
      typeof record?.displayName === 'string' ? record.displayName : null,
    email: typeof record?.email === 'string' ? record.email : null,
    photoUrl: safePhotoUrl(record?.photoURL),
  };
}

function displayName(auth) {
  const profile = memberProfile(auth);
  return profile.displayName || (profile.email ?? '').split('@')[0] || null;
}

module.exports = {
  CODE_ALPHABET,
  CODE_LENGTH,
  DEFAULT_INVITE_DAYS,
  MAX_INVITE_DAYS,
  MAX_PENDING_INVITATIONS,
  ValidationError,
  generateCode,
  normalizeCode,
  isWellFormedCode,
  validateHouseholdName,
  normalizeEmail,
  inviteDays,
  invitationState,
  checkInvitationUsable,
  safePhotoUrl,
  memberProfile,
  accountProfile,
  displayName,
};
