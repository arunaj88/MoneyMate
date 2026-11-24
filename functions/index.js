'use strict';

/**
 * MoneyMate Cloud Functions: trusted household and invitation management.
 *
 * Clients cannot write households, members, memberships or invitations
 * (see firestore.rules); every such change goes through these callable
 * functions, which validate the caller with admin rights.
 */

const crypto = require('node:crypto');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore } = require('firebase-admin/firestore');
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { setGlobalOptions } = require('firebase-functions/v2');
const logger = require('firebase-functions/logger');

const households = require('./src/households');
const { ValidationError } = require('./src/logic');

initializeApp();
setGlobalOptions({ region: 'us-central1', maxInstances: 10 });

const deps = {
  now: () => Date.now(),
  randomBytes: (n) => crypto.randomBytes(n),
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
exports.transferOwnership = callable(
  'transferOwnership',
  households.transferOwnership,
);
exports.deleteHousehold = callable('deleteHousehold', households.deleteHousehold);
