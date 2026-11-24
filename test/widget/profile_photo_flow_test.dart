import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/models/household_models.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/shared/widgets/user_avatar.dart';
import 'package:provider/provider.dart';

import '../helpers/app_harness.dart';
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
  late FakeProfilePhotoService photos;
  late FakePhotoPicker picker;

  Future<void> openSettings(
    WidgetTester tester, {
    AppUser user = testUser,
    bool withPhotos = true,
    FakeHouseholdService? households,
    Size logicalSize = const Size(390, 844),
  }) async {
    photos = FakeProfilePhotoService(user);
    picker = FakePhotoPicker(photo: tinyPng);
    await TestHarness(
      user: user,
      households: households,
      photos: withPhotos ? photos : null,
      photoPicker: withPhotos ? picker : null,
    ).pump(tester, logicalSize: logicalSize);
    await openTab(tester, 'Settings');
  }

  AppUser? currentUser(WidgetTester tester) => tester
      .element(find.byKey(const Key('accountTile')))
      .read<AuthProvider>()
      .user;

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('choosing a gallery photo previews, uploads and updates every '
      'avatar', (tester) async {
    await openSettings(tester);
    expect(find.text('Add a profile photo'), findsOneWidget);

    await tapKey(tester, 'changePhotoTile');
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(find.text('Take a photo'), findsOneWidget);
    // No photo yet, so nothing to remove.
    expect(find.byKey(const Key('removePhoto')), findsNothing);

    await tapKey(tester, 'photoFromGallery');
    expect(find.text('New profile photo'), findsOneWidget);
    expect(find.byKey(const Key('photoPreview')), findsOneWidget);

    // Hold the upload to see its progress.
    photos.gate = Completer<void>();
    await tester.tap(find.byKey(const Key('usePhotoButton')));
    await tester.pump();
    expect(find.byKey(const Key('photoProgress')), findsOneWidget);
    expect(find.text('Uploading… 50%'), findsOneWidget);

    photos.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photoProgress')), findsNothing);
    expect(find.text('Profile photo updated'), findsOneWidget);
    expect(find.text('Change profile photo'), findsOneWidget);
    expect(photos.uploaded, tinyPng);
    expect(picker.picks.single.name, 'gallery');

    final url = currentUser(tester)!.photoUrl;
    expect(url, startsWith(FakeProfilePhotoService.urlPrefix));
    // The dashboard avatar shows the same user.
    await openTab(tester, 'Dashboard');
    final avatars = tester.widgetList<UserAvatar>(find.byType(UserAvatar));
    expect(avatars, isNotEmpty);
    expect(avatars.every((a) => a.user?.photoUrl == url), isTrue);
  });

  testWidgets('removing a Google photo asks first, then shows initials', (
    tester,
  ) async {
    await openSettings(tester, user: googleUser);
    await tapKey(tester, 'accountTile');
    await tapKey(tester, 'removePhoto');
    expect(find.text('Remove profile photo?'), findsOneWidget);

    // Cancel keeps it.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(photos.removals, 0);
    expect(currentUser(tester)!.photoUrl, googleUser.photoUrl);

    await tapKey(tester, 'changePhotoTile');
    await tapKey(tester, 'removePhoto');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(photos.removals, 1);
    expect(currentUser(tester)!.hasPhoto, isFalse);
    expect(find.text('Profile photo removed'), findsOneWidget);
    expect(find.text('Add a profile photo'), findsOneWidget);
    expect(find.text('SL'), findsOneWidget);
  });

  testWidgets('offline uploads show a clear error and keep the photo', (
    tester,
  ) async {
    await openSettings(tester, user: googleUser);
    photos.error = ProfilePhotoException(
      storageErrorMessage('retry-limit-exceeded'),
      code: 'retry-limit-exceeded',
    );
    await tapKey(tester, 'changePhotoTile');
    await tapKey(tester, 'photoFromGallery');
    await tapKey(tester, 'usePhotoButton');

    expect(
      find.textContaining('You are offline or the connection is too slow'),
      findsOneWidget,
    );
    expect(currentUser(tester)!.photoUrl, googleUser.photoUrl);
    expect(find.text('Change profile photo'), findsOneWidget);
  });

  testWidgets('denied photo access is explained', (tester) async {
    await openSettings(tester);
    picker.error = const ProfilePhotoException(
      'MoneyMate is not allowed to open your photos. Allow photo access in '
      'your device settings and try again.',
      code: 'photo_access_denied',
    );
    await tapKey(tester, 'changePhotoTile');
    await tapKey(tester, 'photoFromGallery');
    expect(find.textContaining('not allowed to open your photos'), findsOne);
    expect(photos.uploads, 0);
  });

  testWidgets('an unusable photo is reported in the preview', (tester) async {
    await openSettings(tester);
    picker.prepareError = const ProfilePhotoException(
      'That photo is too large. Choose one under 25 MB.',
      code: 'too-large',
    );
    await tapKey(tester, 'changePhotoTile');
    await tapKey(tester, 'photoFromGallery');
    expect(find.byKey(const Key('photoPreviewError')), findsOneWidget);
    expect(find.byKey(const Key('usePhotoButton')), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(photos.uploads, 0);
  });

  testWidgets('cancelling the picker changes nothing', (tester) async {
    await openSettings(tester);
    picker.photo = null;
    picker.camera = false;
    await tapKey(tester, 'changePhotoTile');
    expect(find.byKey(const Key('photoFromCamera')), findsNothing);
    await tapKey(tester, 'photoFromGallery');
    expect(find.text('New profile photo'), findsNothing);
    expect(photos.uploads, 0);
  });

  testWidgets('without photo storage the option is hidden', (tester) async {
    await openSettings(tester, withPhotos: false);
    expect(find.byKey(const Key('changePhotoTile')), findsNothing);
    await tester.tap(find.byKey(const Key('accountTile')));
    await tester.pumpAndSettle();
    expect(find.text('Profile photo'), findsNothing);
  });

  testWidgets('the sheet and preview fit a small phone', (tester) async {
    await openSettings(tester, logicalSize: const Size(320, 568));
    await tapKey(tester, 'changePhotoTile');
    await tapKey(tester, 'photoFromGallery');
    expect(find.byKey(const Key('usePhotoButton')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('household members see the new photo', (tester) async {
    final households = FakeHouseholdService(uid: testUser.uid)
      ..membershipIds = ['house-1']
      ..household = const Household(
        id: 'house-1',
        name: 'Lee family',
        ownerUid: 'uid-1',
      )
      ..members = const [
        HouseholdMember(
          uid: 'uid-1',
          role: HouseholdRole.owner,
          status: MembershipStatus.active,
          displayName: 'Sam Lee',
          email: 'sam.lee@example.com',
        ),
      ];
    await openSettings(tester, households: households);
    households.account = () => photos.user;

    await tapKey(tester, 'changePhotoTile');
    await tapKey(tester, 'photoFromGallery');
    await tapKey(tester, 'usePhotoButton');
    final url = currentUser(tester)!.photoUrl;

    // The member document (what other members read) is refreshed by the
    // server, and the member list shows the new photo.
    expect(households.calls, contains('refreshProfile'));
    expect(households.members.single.photoUrl, url);
    await tapKey(tester, 'householdTile');
    final row = find.byKey(const ValueKey('member-uid-1'));
    final avatar = tester.widget<UserAvatar>(
      find.descendant(of: row, matching: find.byType(UserAvatar)),
    );
    expect(avatar.user!.photoUrl, url);
  });

  group('permission', () {
    testWidgets('the app explains and asks before opening the gallery', (
      tester,
    ) async {
      await openSettings(tester);
      picker.access = PhotoAccess.denied;
      await tapKey(tester, 'changePhotoTile');
      await tapKey(tester, 'photoFromGallery');

      expect(find.text('Allow access to your photos?'), findsOneWidget);
      // Nothing is opened before the user agrees.
      expect(picker.requests, isEmpty);
      expect(picker.picks, isEmpty);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(picker.requests, [PhotoSource.gallery]);
      expect(picker.picks, [PhotoSource.gallery]);
      expect(find.text('New profile photo'), findsOneWidget);
    });

    testWidgets('once allowed, the gallery opens without asking again', (
      tester,
    ) async {
      await openSettings(tester);
      await tapKey(tester, 'changePhotoTile');
      await tapKey(tester, 'photoFromGallery');
      expect(find.text('Allow access to your photos?'), findsNothing);
      expect(picker.requests, isEmpty);
      expect(picker.picks, [PhotoSource.gallery]);
    });

    testWidgets('choosing Cancel asks nothing and opens nothing', (
      tester,
    ) async {
      await openSettings(tester);
      picker.access = PhotoAccess.denied;
      await tapKey(tester, 'changePhotoTile');
      await tapKey(tester, 'photoFromGallery');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(picker.requests, isEmpty);
      expect(picker.picks, isEmpty);
    });

    testWidgets('denying the system prompt is explained', (tester) async {
      await openSettings(tester);
      picker
        ..access = PhotoAccess.denied
        ..answer = PhotoAccess.denied;
      await tapKey(tester, 'changePhotoTile');
      await tapKey(tester, 'photoFromGallery');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'MoneyMate was not allowed to use your photos, so no photo was '
          'chosen.',
        ),
        findsOneWidget,
      );
      expect(picker.picks, isEmpty);
      expect(photos.uploads, 0);
    });

    testWidgets('access turned off for good points to the device settings', (
      tester,
    ) async {
      await openSettings(tester);
      picker.access = PhotoAccess.permanentlyDenied;
      await tapKey(tester, 'changePhotoTile');
      await tapKey(tester, 'photoFromGallery');

      expect(find.text('Photo access is off'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(picker.settingsOpened, 1);
      expect(picker.requests, isEmpty);
      expect(picker.picks, isEmpty);
    });

    testWidgets('the camera has its own explanation', (tester) async {
      await openSettings(tester);
      picker.access = PhotoAccess.denied;
      await tapKey(tester, 'changePhotoTile');
      await tapKey(tester, 'photoFromCamera');
      expect(find.text('Allow camera access?'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(picker.requests, [PhotoSource.camera]);
      expect(picker.picks, [PhotoSource.camera]);
    });
  });
}
