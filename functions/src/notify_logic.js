'use strict';

/**
 * Pure helpers for push notifications: what changed, who should hear about
 * it and what the notification says. No Firebase access, so they are
 * unit-tested without an emulator.
 */

/** Per-device preference fields on users/{uid}/devices/{deviceId}. */
const PREFS = Object.freeze({
  householdActivity: 'householdActivity',
  householdBudgets: 'householdBudgets',
  savings: 'savingsUpdates',
});

/** Android notification channels (created by the app, see LocalNotifier). */
const CHANNELS = Object.freeze({
  household: 'household_activity',
  budgets: 'budget_alerts',
  savings: 'savings_updates',
});

/**
 * Display symbols of the currencies the app offers (lib/core/constants/
 * currencies.dart). Every one has two decimal places.
 */
const CURRENCY_SYMBOLS = Object.freeze({
  AED: 'AED ',
  USD: '$',
  EUR: '€',
  GBP: '£',
  INR: '₹',
  SAR: 'SAR ',
  QAR: 'QAR ',
  PKR: 'Rs ',
  PHP: '₱',
  EGP: 'E£',
  CAD: 'CA$',
  AUD: 'A$',
  SGD: 'S$',
  CHF: 'CHF ',
});
const DEFAULT_CURRENCY = 'AED';

const BUDGET_LEVELS = Object.freeze(['approaching', 'warning', 'exceeded']);

/** Budget alerts written after their period ended (offline) are dropped. */
const BUDGET_ALERT_GRACE_MS = 24 * 60 * 60 * 1000;

/**
 * [amountMinor] (2 decimal places) as the app shows it, e.g. "AED 1,250.50".
 */
function formatMoney(amountMinor, currencyCode) {
  const code = Object.hasOwn(CURRENCY_SYMBOLS, currencyCode)
    ? currencyCode
    : DEFAULT_CURRENCY;
  const minor = Math.abs(Math.trunc(Number(amountMinor) || 0));
  const major = Math.floor(minor / 100).toLocaleString('en-US');
  const cents = String(minor % 100).padStart(2, '0');
  return `${CURRENCY_SYMBOLS[code]}${major}.${cents}`;
}

/** Cuts [text] to [max] characters, ending with an ellipsis when cut. */
function truncate(text, max) {
  const value = String(text ?? '').trim().replace(/\s+/g, ' ');
  return value.length <= max ? value : `${value.slice(0, max - 1).trimEnd()}…`;
}

/** A person's first name for short notification text. */
function shortName(name, fallback = 'Someone') {
  const value = String(name ?? '').trim();
  if (!value) return fallback;
  return value.split(/\s+/)[0];
}

/** The fields a member sees in a shared transaction. */
const TRANSACTION_FIELDS = [
  'type',
  'amountMinor',
  'categoryId',
  'date',
  'note',
  'paymentMethod',
];

/**
 * What a write to households/{hid}/transactions/{id} means for the other
 * members: 'added', 'edited', 'deleted', or null when nothing they would
 * notice changed (a re-upload, a schema backfill, a restore).
 * @param {object|undefined} before
 * @param {object|undefined} after
 */
function transactionChange(before, after) {
  if (!after) return null; // Hard deletes do not happen (soft deletes only).
  const wasLive = !!before && before.deleted !== true;
  const isLive = after.deleted !== true;
  if (!wasLive && isLive) return 'added';
  if (wasLive && !isLive) return 'deleted';
  if (!wasLive && !isLive) return null;
  const changed = TRANSACTION_FIELDS.some(
    (f) => JSON.stringify(before[f] ?? null) !== JSON.stringify(after[f] ?? null),
  );
  return changed ? 'edited' : null;
}

/**
 * Notification for a shared transaction change by [actorName].
 * @param {'added'|'edited'|'deleted'} change
 */
function transactionMessage(change, tx, actorName, currencyCode) {
  const who = shortName(actorName);
  const amount = formatMoney(tx.amountMinor, currencyCode);
  const kind = tx.type === 'income' ? 'income' : 'expense';
  const category =
    typeof tx.category?.name === 'string' && tx.category.name.trim()
      ? tx.category.name.trim()
      : null;
  const verb = { added: 'added', edited: 'edited', deleted: 'deleted' }[change];
  const title = `${who} ${verb} ${kind === 'income' ? 'an income' : 'an expense'}`;
  const parts = [kind === 'income' ? `+${amount}` : amount];
  if (category) parts.push(category);
  const note = truncate(tx.note, 60);
  if (note) parts.push(note);
  return { title, body: parts.join(' · ') };
}

/**
 * What a write to households/{hid}/members/{uid} means: 'joined', 'left',
 * 'removed', or null.
 */
function memberChange(before, after) {
  const was = before?.status ?? null;
  const is = after?.status ?? null;
  if (is === 'active' && was !== 'active') return 'joined';
  if (was === 'active' && is === 'left') return 'left';
  if (was === 'active' && is === 'removed') return 'removed';
  return null;
}

function memberMessage(change, memberName, householdName) {
  const who = shortName(memberName);
  const house = truncate(householdName, 40) || 'your household';
  switch (change) {
    case 'joined':
      return {
        title: `${who} joined ${house}`,
        body: 'Shared expenses, budgets and savings are now visible to them.',
      };
    case 'left':
      return { title: `${who} left ${house}`, body: 'They no longer see shared data.' };
    case 'removed':
      return { title: `${who} was removed from ${house}`, body: 'They no longer see shared data.' };
    default:
      return null;
  }
}

/** Notification to a member who was removed by the owner. */
function removedYouMessage(householdName) {
  const house = truncate(householdName, 40) || 'a household';
  return {
    title: `You were removed from ${house}`,
    body: 'Your personal data is unchanged. Shared data is no longer synced.',
  };
}

/**
 * Notification for a new savings entry. When the entry took the goal to
 * its target, says so instead.
 * @param {object} entry the entry document
 * @param {object|undefined} goal the goal document after the entry
 */
function savingsMessage(entry, goal, currencyCode) {
  const who = shortName(entry.userName);
  const amount = formatMoney(entry.amountMinor, currencyCode);
  const goalName = truncate(goal?.name, 40) || 'a savings goal';
  if (goalReachedBy(entry, goal)) {
    return {
      title: `🎉 ${goalName} reached its target`,
      body: `${who} added ${amount}. ${formatMoney(goal.savedMinor, currencyCode)} saved of ${formatMoney(goal.targetMinor, currencyCode)}.`,
      reached: true,
    };
  }
  if (entry.type === 'withdrawal') {
    return {
      title: `${who} withdrew from ${goalName}`,
      body: `${amount} withdrawn${savedSuffix(goal, currencyCode)}`,
      reached: false,
    };
  }
  return {
    title: `${who} added to ${goalName}`,
    body: `${amount} saved${savedSuffix(goal, currencyCode)}`,
    reached: false,
  };
}

function savedSuffix(goal, currencyCode) {
  if (!goal || !Number.isInteger(goal.savedMinor) || !(goal.targetMinor > 0)) {
    return '.';
  }
  const percent = Math.min(999, Math.floor((goal.savedMinor / goal.targetMinor) * 100));
  return ` · ${formatMoney(goal.savedMinor, currencyCode)} of ${formatMoney(goal.targetMinor, currencyCode)} (${percent}%).`;
}

/**
 * True when [entry] is the goal's latest entry and moved its total from
 * below the target to at least the target.
 */
function goalReachedBy(entry, goal) {
  if (!goal || entry.type !== 'deposit') return false;
  if (goal.lastEntryId !== entry.id) return false;
  const target = goal.targetMinor;
  const after = goal.savedMinor;
  if (!Number.isInteger(target) || target <= 0 || !Number.isInteger(after)) {
    return false;
  }
  return after >= target && after - entry.amountMinor < target;
}

/**
 * Checks a household budget alert written by a member's app. Returns the
 * notification, or null when it is malformed or stale.
 */
function budgetAlertMessage(alert, nowMs) {
  if (!alert || !BUDGET_LEVELS.includes(alert.level)) return null;
  if (typeof alert.title !== 'string' || typeof alert.message !== 'string') {
    return null;
  }
  if (
    Number.isInteger(alert.periodEnd) &&
    nowMs > alert.periodEnd + BUDGET_ALERT_GRACE_MS
  ) {
    return null;
  }
  const title = `Household ${truncate(alert.title, 40).toLowerCase()}`;
  return { title, body: truncate(alert.message, 200) };
}

/**
 * Tokens of [devices] (device documents) that want [pref]. Duplicate
 * tokens (an app reinstalled under a new device ID) are sent once.
 * @returns {{token: string, ref: any, currencyCode: string}[]}
 */
function targetsFor(devices, pref) {
  const seen = new Set();
  const out = [];
  for (const d of devices) {
    const data = d.data;
    if (typeof data?.token !== 'string' || !data.token) continue;
    if (data[pref] === false) continue;
    if (seen.has(data.token)) continue;
    seen.add(data.token);
    out.push({
      token: data.token,
      ref: d.ref,
      currencyCode:
        typeof data.currencyCode === 'string' ? data.currencyCode : DEFAULT_CURRENCY,
    });
  }
  return out;
}

/** FCM error codes meaning the token will never work again. */
const DEAD_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/invalid-argument',
]);

function isDeadTokenError(error) {
  return !!error && DEAD_TOKEN_CODES.has(error.code);
}

module.exports = {
  PREFS,
  CHANNELS,
  CURRENCY_SYMBOLS,
  BUDGET_ALERT_GRACE_MS,
  formatMoney,
  truncate,
  shortName,
  transactionChange,
  transactionMessage,
  memberChange,
  memberMessage,
  removedYouMessage,
  savingsMessage,
  goalReachedBy,
  budgetAlertMessage,
  targetsFor,
  isDeadTokenError,
};
