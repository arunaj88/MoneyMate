'use strict';

// storage.rules against the profile photo uploads the app makes:
//   npm test   (runs `firebase emulators:exec --only firestore,storage ...`)

const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const PROJECT = 'demo-moneymate';
const emulated = !!process.env.FIREBASE_STORAGE_EMULATOR_HOST;
const skip = emulated ? false : 'needs the Storage emulator (npm test)';

let env;
let assertSucceeds;
let assertFails;

const OWNER = 'owner-uid';
const OTHER = 'other-uid';
const avatar = (uid) => `users/${uid}/profile/avatar.jpg`;
const jpeg = (bytes = 1024) => new Uint8Array(bytes).fill(0xff);
const JPEG = { contentType: 'image/jpeg' };

function storage(uid) {
  return uid
    ? env.authenticatedContext(uid).storage()
    : env.unauthenticatedContext().storage();
}

test.describe('storage rules', { skip }, () => {
  test.before(async () => {
    const rut = require('@firebase/rules-unit-testing');
    require('firebase/compat/storage');
    ({ assertSucceeds, assertFails } = rut);
    const [host, port] = process.env.FIREBASE_STORAGE_EMULATOR_HOST.split(':');
    env = await rut.initializeTestEnvironment({
      projectId: PROJECT,
      storage: {
        host,
        port: Number(port),
        rules: fs.readFileSync(
          path.join(__dirname, '..', '..', 'storage.rules'),
          'utf8',
        ),
      },
    });
  });

  test.after(async () => env?.cleanup());

  test.beforeEach(async () => env.clearStorage());

  test('a user uploads, replaces and deletes their own photo', async () => {
    const ref = storage(OWNER).ref(avatar(OWNER));
    await assertSucceeds(ref.put(jpeg(), JPEG));
    await assertSucceeds(ref.put(jpeg(2048), JPEG));
    await assertSucceeds(ref.getDownloadURL());
    await assertSucceeds(ref.delete());
  });

  test("nobody writes another user's photo", async () => {
    await assertFails(storage(OTHER).ref(avatar(OWNER)).put(jpeg(), JPEG));
    await assertFails(storage(null).ref(avatar(OWNER)).put(jpeg(), JPEG));

    await storage(OWNER).ref(avatar(OWNER)).put(jpeg(), JPEG);
    await assertFails(storage(OTHER).ref(avatar(OWNER)).delete());
  });

  test('signed-in users can read photos; signed-out users cannot', async () => {
    await storage(OWNER).ref(avatar(OWNER)).put(jpeg(), JPEG);
    await assertSucceeds(storage(OTHER).ref(avatar(OWNER)).getDownloadURL());
    await assertFails(storage(null).ref(avatar(OWNER)).getDownloadURL());
  });

  test('only JPEGs under 1 MB are accepted', async () => {
    const ref = storage(OWNER).ref(avatar(OWNER));
    await assertFails(ref.put(jpeg(), { contentType: 'image/png' }));
    await assertFails(ref.put(jpeg(), { contentType: 'text/html' }));
    await assertFails(ref.put(jpeg(1024 * 1024), JPEG));
    await assertFails(ref.put(new Uint8Array(0), JPEG));
  });

  test('no other paths are readable or writable', async () => {
    const own = storage(OWNER);
    await assertFails(own.ref(`users/${OWNER}/profile/other.jpg`).put(jpeg(), JPEG));
    await assertFails(own.ref(`users/${OWNER}/backup.json`).put(jpeg(), JPEG));
    await assertFails(own.ref('public/avatar.jpg').put(jpeg(), JPEG));
  });
});
