'use strict';

/**
 * MoneyMate Cloud Functions: trusted household and invitation management,
 * and push notifications (Firebase Cloud Messaging) for shared activity.
 *
 * Clients cannot write households, members, memberships or invitations
 * (see firestore.rules); every such change goes through these callable
 * functions, which validate the caller with admin rights.
 */

const crypto = require('node:crypto');
const { initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const {
  onDocumentCreated,
  onDocumentWritten,
} = require('firebase-functions/v2/firestore');
const { setGlobalOptions } = require('firebase-functions/v2');
const logger = require('firebase-functions/logger');

const accounts = require('./src/accounts');
const households = require('./src/households');
const notifications = require('./src/notifications');
const { ValidationError } = require('./src/logic');

initializeApp();
setGlobalOptions({ region: 'us-central1', maxInstances: 10 });

const deps = {
  now: () => Date.now(),
  randomBytes: (n) => crypto.randomBytes(n),
  getUser: (uid) => getAuth().getUser(uid),
  updateUser: (uid, props) => getAuth().updateUser(uid, props),
};

/** Wraps a handler as a callable function with consistent errors. */
function callable(name, handler) {
  return onCall({ enforceAppCheck: false }, async (request) => {
    try {
      return await handler(getFirestore(), request.auth, request.data, deps);
    } catch (error) {
      if (error instanceof ValidationError) {
        throw new HttpsError(error.code, error.message);
      }
      if (error instanceof HttpsError) throw error;
      logger.error(`${name} failed`, error);
      throw new HttpsError(
        'internal',
        'Something went wrong. Please try again.',
      );
    }
  });
}

exports.createHousehold = callable('createHousehold', households.createHousehold);
exports.updateHousehold = callable('updateHousehold', households.updateHousehold);
exports.createInvitation = callable(
  'createInvitation',
  households.createInvitation,
);
exports.revokeInvitation = callable(
  'revokeInvitation',
  households.revokeInvitation,
);
exports.previewInvitation = callable(
  'previewInvitation',
  households.previewInvitation,
);
exports.acceptInvitation = callable(
  'acceptInvitation',
  households.acceptInvitation,
);
exports.removeMember = callable('removeMember', households.removeMember);
exports.leaveHousehold = callable('leaveHousehold', households.leaveHousehold);
exports.refreshMemberProfile = callable(
  'refreshMemberProfile',
  households.refreshMemberProfile,
);
exports.transferOwnership = callable(
  'transferOwnership',
  households.transferOwnership,
);
exports.deleteHousehold = callable('deleteHousehold', households.deleteHousehold);

// Accounts created before email verification was required skip it.
exports.exemptExistingAccount = callable(
  'exemptExistingAccount',
  accounts.exemptExistingAccount,
);

// ------------------------------------------------------ push notifications

/** Sends with FCM, one result per message (see notifications.js). */
async function sendWithFcm(messages) {
  const response = await getMessaging().sendEach(messages);
  return response.responses;
}

/**
 * Firestore triggers must run where the database is (asia-south1). The
 * callable functions stay in us-central1, where the app calls them.
 */
const FIRESTORE_REGION = 'asia-south1';

/**
 * Wraps a notification handler as a Firestore trigger. Failures are logged,
 * never retried: a late duplicate notification is worse than a missed one.
 */
function trigger(name, document, handler, { createdOnly = false } = {}) {
  const on = createdOnly ? onDocumentCreated : onDocumentWritten;
  return on({ document, region: FIRESTORE_REGION, retry: false }, async (event) => {
    const change = event.data;
    const before = createdOnly ? undefined : change?.before?.data();
    const after = createdOnly ? change?.data() : change?.after?.data();
    try {
      await handler(
        getFirestore(),
        sendWithFcm,
        { params: event.params, before, after },
        deps,
      );
    } catch (error) {
      logger.error(`${name} failed`, error);
    }
  });
}

exports.notifyHouseholdTransaction = trigger(
  'notifyHouseholdTransaction',
  'households/{householdId}/transactions/{transactionId}',
  notifications.onHouseholdTransaction,
);
exports.notifyHouseholdMember = trigger(
  'notifyHouseholdMember',
  'households/{householdId}/members/{memberUid}',
  notifications.onHouseholdMember,
);
exports.notifyHouseholdBudgetAlert = trigger(
  'notifyHouseholdBudgetAlert',
  'households/{householdId}/budgetAlerts/{alertId}',
  notifications.onHouseholdBudgetAlert,
  { createdOnly: true },
);
exports.notifyHouseholdSavings = trigger(
  'notifyHouseholdSavings',
  'households/{householdId}/savingsEntries/{entryId}',
  notifications.onHouseholdSavingsEntry,
  { createdOnly: true },
);
exports.notifySharedGoal = trigger(
  'notifySharedGoal',
  'sharedGoals/{goalId}/entries/{entryId}',
  notifications.onSharedGoalEntry,
  { createdOnly: true },
);
