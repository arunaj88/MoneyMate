import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/models/app_user.dart';

Matcher throwsPhotoError(String code) =>
    throwsA(isA<ProfilePhotoException>().having((e) => e.code, 'code', code));

void main() {
  group('prepareProfilePhoto', () {
    test('centre-crops, downscales and compresses to a square JPEG', () {
      // Landscape photo: red left third, green middle, blue right third.
      final source = img.Image(width: 1800, height: 1200);
      for (var x = 0; x < source.width; x++) {
        final color = x < 600
            ? img.ColorRgb8(255, 0, 0)
            : x < 1200
            ? img.ColorRgb8(0, 255, 0)
            : img.ColorRgb8(0, 0, 255);
        for (var y = 0; y < source.height; y++) {
          source.setPixel(x, y, color);
        }
      }
      final png = img.encodePng(source);

      final jpeg = prepareProfilePhoto(Uint8List.fromList(png));

      expect(jpeg.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
      expect(jpeg.length, lessThan(ProfilePhotoLimits.maxUploadBytes));
      final out = img.decodeJpg(jpeg)!;
      expect(out.width, ProfilePhotoLimits.size);
      expect(out.height, ProfilePhotoLimits.size);
      // The square comes from the middle: mostly green, no blue at the
      // centre.
      final centre = out.getPixel(256, 256);
      expect(centre.g, greaterThan(200));
      expect(centre.b, lessThan(60));
    });

    test('transparent images are flattened onto white', () {
      final source = img.Image(width: 64, height: 64, numChannels: 4)
        ..clear(img.ColorRgba8(0, 0, 0, 0));
      final jpeg = prepareProfilePhoto(
        Uint8List.fromList(img.encodePng(source)),
      );
      final pixel = img.decodeJpg(jpeg)!.getPixel(10, 10);
      expect(pixel.r, greaterThan(240));
      expect(pixel.g, greaterThan(240));
      expect(pixel.b, greaterThan(240));
    });

    test('rejects files that are not images', () {
      expect(
        () => prepareProfilePhoto(Uint8List.fromList(List.filled(500, 42))),
        throwsPhotoError('unsupported'),
      );
    });

    test('rejects files that are too large to process', () {
      expect(
        () => prepareProfilePhoto(
          Uint8List(ProfilePhotoLimits.maxSourceBytes + 1),
        ),
        throwsPhotoError('too-large'),
      );
    });
  });

  test('error messages explain offline, permission and size problems', () {
    expect(storageErrorMessage('retry-limit-exceeded'), contains('offline'));
    expect(storageErrorMessage('unauthorized'), contains('1 MB'));
    expect(
      storageErrorMessage('bucket-not-found'),
      'Photo storage is not set up for this app yet.',
    );
    expect(pickerErrorMessage('photo_access_denied'), contains('photo access'));
    expect(
      pickerErrorMessage('camera_access_denied'),
      contains('camera access'),
    );
    expect(pickerErrorMessage('no_available_camera'), contains('No camera'));
  });

  test('withPhotoUrl replaces or clears only the photo', () {
    const user = AppUser(
      uid: 'u',
      email: 'a@b.c',
      displayName: 'Ana',
      photoUrl: 'https://old',
    );
    expect(user.withPhotoUrl('https://new').photoUrl, 'https://new');
    expect(user.withPhotoUrl(null).hasPhoto, isFalse);
    expect(user.withPhotoUrl('  ').photoUrl, isNull);
    expect(user.withPhotoUrl(null).displayName, 'Ana');
    expect(user.withPhotoUrl(null).email, 'a@b.c');
  });

  test('storage path is per user', () {
    expect(
      FirebaseProfilePhotoService.pathFor('abc'),
      'users/abc/profile/avatar.jpg',
    );
  });
}
