import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/providers/household_provider.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_household_service.dart';
import '../helpers/fake_profile_photo.dart';
import '../helpers/fakes.dart';

const googleUser = AppUser(
  uid: 'uid-1',
  email: 'sam.lee@example.com',
  displayName: 'Sam Lee',
  photoUrl: 'https://lh3.googleusercontent.com/sam',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late FakeAuthService authService;
  late FakeProfilePhotoService photos;
  late AuthProvider auth;
  final jpeg = Uint8List.fromList(List.filled(2048, 7));

  AppUser? cached() => AppUser.fromJson(prefs.getString(PrefKeys.userProfile));

  Future<void> start(AppUser user, {bool withPhotos = true}) async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    authService = FakeAuthService(signedIn: user);
    photos = FakeProfilePhotoService(user);
    auth = AuthProvider(
      authService,
      prefs,
      photoService: withPhotos ? photos : null,
    );
    await pumpEventQueue();
  }

  tearDown(() => auth.dispose());

  test('photo changes are only offered with a photo service', () async {
    await start(testUser, withPhotos: false);
    expect(auth.canChangePhoto, isFalse);
    expect(await auth.updatePhoto(jpeg), isFalse);
    expect(auth.error, 'Sign in to change your profile photo.');

    auth.dispose();
    await start(testUser);
    expect(auth.canChangePhoto, isTrue);
  });

  test('uploading updates the user and the cached profile at once', () async {
    await start(testUser);
    final progress = <double?>[];
    auth.addListener(() => progress.add(auth.photoProgress));

    expect(await auth.updatePhoto(jpeg), isTrue);

    expect(photos.uploaded, jpeg);
    expect(auth.user!.photoUrl, startsWith(FakeProfilePhotoService.urlPrefix));
    expect(auth.user!.displayName, 'Sam Lee');
    expect(cached()!.photoUrl, auth.user!.photoUrl);
    expect(auth.error, isNull);
    expect(auth.isBusy, isFalse);
    // Progress is reported while uploading and cleared afterwards.
    expect(progress, containsAllInOrder([0.0, 0.5, 1.0]));
    expect(auth.photoProgress, isNull);
  });

  test(
    'Google users keep their Google photo until they choose another',
    () async {
      await start(googleUser);
      expect(auth.user!.photoUrl, googleUser.photoUrl);

      // A later auth event without the photo (e.g. before Firebase has loaded
      // the profile) does not drop it.
      authService.googleUser = const AppUser(uid: 'uid-1');
      await auth.signInWithGoogle();
      expect(auth.user!.photoUrl, googleUser.photoUrl);

      expect(await auth.updatePhoto(jpeg), isTrue);
      expect(auth.user!.photoUrl, isNot(googleUser.photoUrl));
    },
  );

  test('removing a photo is not undone by the cached profile', () async {
    await start(googleUser);
    expect(cached()!.photoUrl, googleUser.photoUrl);

    expect(await auth.removePhoto(), isTrue);
    expect(photos.removals, 1);
    expect(auth.user!.hasPhoto, isFalse);
    expect(auth.user!.name, 'Sam Lee');
    expect(cached()!.hasPhoto, isFalse);

    // The next auth event (Firebase now has no photo) keeps it removed.
    authService.googleUser = const AppUser(
      uid: 'uid-1',
      email: 'sam.lee@example.com',
    );
    await auth.signInWithGoogle();
    expect(auth.user!.hasPhoto, isFalse);
    expect(auth.user!.displayName, 'Sam Lee');
  });

  test('failures keep the current photo and report a message', () async {
    await start(googleUser);
    photos.error = const ProfilePhotoException(
      'You are offline or the connection is too slow. Try again when you '
      'are connected.',
      code: 'retry-limit-exceeded',
    );

    expect(await auth.updatePhoto(jpeg), isFalse);
    expect(auth.error, contains('offline'));
    expect(auth.user!.photoUrl, googleUser.photoUrl);
    expect(cached()!.photoUrl, googleUser.photoUrl);
    expect(auth.isBusy, isFalse);
    expect(auth.photoProgress, isNull);

    expect(await auth.removePhoto(), isFalse);
    expect(auth.user!.photoUrl, googleUser.photoUrl);
  });

  test('oversized uploads are refused before reaching the server', () async {
    await start(testUser);
    final huge = Uint8List(ProfilePhotoLimits.maxUploadBytes + 1);
    expect(await auth.updatePhoto(huge), isFalse);
    expect(auth.error, contains('too large'));
    expect(photos.uploads, 0);
  });

  test('only one request runs at a time', () async {
    await start(testUser);
    photos.gate = Completer<void>();
    final first = auth.updatePhoto(jpeg);
    expect(auth.isRunning(AuthAction.updatePhoto), isTrue);
    expect(await auth.removePhoto(), isFalse);
    expect(await auth.signOut(), isFalse);
    photos.gate!.complete();
    expect(await first, isTrue);
    expect(photos.uploads, 1);
    expect(photos.removals, 0);
  });

  group('household member profile', () {
    late FakeHouseholdService households;
    late HouseholdProvider household;

    Future<void> joinHousehold(AppUser user) async {
      await start(user);
      households = FakeHouseholdService(uid: user.uid)
        ..account = () => photos.user;
      household = HouseholdProvider(service: households, preferences: prefs);
      auth.addListener(() => household.updateAuth(auth));
      household.updateAuth(auth);
      await pumpEventQueue();
      await household.createHousehold('Lee family');
      await pumpEventQueue();
    }

    tearDown(() => household.dispose());

    test('a new photo is copied to the member document', () async {
      await joinHousehold(testUser);
      households.calls.clear();
      expect(await auth.updatePhoto(jpeg), isTrue);
      await pumpEventQueue();

      expect(households.calls, ['refreshProfile']);
      final me = household.members.single;
      expect(me.photoUrl, auth.user!.photoUrl);

      // Up to date: no further requests.
      household.updateAuth(auth);
      await pumpEventQueue();
      expect(households.calls, ['refreshProfile']);
    });

    test('a removed photo is cleared for other members too', () async {
      await joinHousehold(googleUser);
      await pumpEventQueue();
      // Joining copied the Google photo to the member document.
      expect(households.members.single.photoUrl, googleUser.photoUrl);
      households.calls.clear();

      expect(await auth.removePhoto(), isTrue);
      await pumpEventQueue();

      expect(households.calls, ['refreshProfile']);
      expect(household.members.single.photoUrl, isNull);
    });

    test('a failed refresh is retried on the next change', () async {
      await joinHousehold(testUser);
      households.offline = true;
      households.calls.clear();
      await auth.updatePhoto(jpeg);
      await pumpEventQueue();
      expect(households.calls, ['refreshProfile']);
      expect(household.members.single.photoUrl, isNull);

      households.offline = false;
      household.updateAuth(auth);
      await pumpEventQueue();
      expect(households.calls, ['refreshProfile', 'refreshProfile']);
      expect(household.members.single.photoUrl, auth.user!.photoUrl);
      expect(household.members.single.role, HouseholdRole.owner);
    });
  });
}
