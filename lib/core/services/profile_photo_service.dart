import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/core/services/auth_service.dart';

/// A profile photo request that failed, with a message for the user.
class ProfilePhotoException implements Exception {
  const ProfilePhotoException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'ProfilePhotoException($code): $message';
}

/// Limits for profile photos. Keep [maxUploadBytes] in step with
/// `storage.rules`.
abstract final class ProfilePhotoLimits {
  /// Side of the square JPEG that is uploaded.
  static const int size = 512;
  static const int jpegQuality = 85;

  /// Largest file accepted from the picker, before it is processed.
  static const int maxSourceBytes = 25 * 1024 * 1024;

  /// Largest image (in pixels) decoded on the device.
  static const int maxSourcePixels = 50 * 1000 * 1000;

  /// Largest upload the storage rules accept.
  static const int maxUploadBytes = 1024 * 1024;
}

/// Turns a JPEG, PNG, WebP, GIF or BMP image into a [ProfilePhotoLimits.size] square JPEG: rotated upright,
/// centre-cropped, downscaled and compressed. Runs synchronously; call it
/// through `compute` to keep the UI responsive.
///
/// Throws [ProfilePhotoException] for files that are too large or are not
/// images.
Uint8List prepareProfilePhoto(Uint8List source) {
  if (source.length > ProfilePhotoLimits.maxSourceBytes) {
    throw const ProfilePhotoException(
      'That photo is too large. Choose one under 25 MB.',
      code: 'too-large',
    );
  }
  final decoder = img.findDecoderForData(source);
  final info = decoder?.startDecode(source);
  if (decoder == null || info == null) {
    throw const ProfilePhotoException(
      'That file is not a supported image. Choose a JPEG or PNG photo.',
      code: 'unsupported',
    );
  }
  if (info.width * info.height > ProfilePhotoLimits.maxSourcePixels) {
    throw const ProfilePhotoException(
      'That photo is too large. Choose a smaller one.',
      code: 'too-large',
    );
  }
  final decoded = img.decodeImage(source);
  if (decoded == null) {
    throw const ProfilePhotoException(
      'That file is not a supported image. Choose a JPEG or PNG photo.',
      code: 'unsupported',
    );
  }
  final upright = img.bakeOrientation(decoded);
  final square = img.copyResizeCropSquare(
    upright,
    size: ProfilePhotoLimits.size,
    interpolation: img.Interpolation.average,
  );
  // JPEG has no alpha: put transparent pixels (PNG logos) on white.
  final flat = square.hasAlpha
      ? img.compositeImage(
          img.Image(width: square.width, height: square.height)
            ..clear(img.ColorRgb8(255, 255, 255)),
          square,
        )
      : square;
  final jpeg = img.encodeJpg(flat, quality: ProfilePhotoLimits.jpegQuality);
  if (jpeg.length > ProfilePhotoLimits.maxUploadBytes) {
    throw const ProfilePhotoException(
      'That photo is too large to upload. Try a different one.',
      code: 'too-large',
    );
  }
  return jpeg;
}

/// Stores the signed-in user's profile photo so it follows them to every
/// device, and keeps the account's photo URL pointing at it.
abstract class ProfilePhotoService {
  /// Uploads [jpeg] (from [prepareProfilePhoto]) as the photo of the
  /// signed-in user and returns their updated profile. [onProgress]
  /// receives the uploaded fraction (0–1).
  Future<AppUser> uploadPhoto(
    Uint8List jpeg, {
    void Function(double progress)? onProgress,
  });

  /// Deletes the uploaded photo (if any) and clears the account's photo,
  /// including one that came from Google sign-in.
  Future<AppUser> removePhoto();
}

/// [ProfilePhotoService] backed by Firebase Storage and Authentication.
///
/// The photo lives at `users/{uid}/profile/avatar.jpg`; only its owner can
/// write it (see `storage.rules`). The account's `photoURL` is set to the
/// download URL, so every device and every sign-in shows the same photo.
class FirebaseProfilePhotoService implements ProfilePhotoService {
  FirebaseProfilePhotoService({
    FirebaseAuth? auth,
    FirebaseStorage? storage,
    Duration? timeout,
  }) : _auth = auth ?? FirebaseAuth.instance,
       _storage = storage ?? FirebaseStorage.instance,
       _timeout = timeout ?? const Duration(seconds: 45) {
    // Fail fast when offline instead of retrying for minutes.
    _storage
      ..setMaxUploadRetryTime(_timeout)
      ..setMaxOperationRetryTime(const Duration(seconds: 20));
  }

  final FirebaseAuth _auth;
  final FirebaseStorage _storage;
  final Duration _timeout;

  static String pathFor(String uid) => 'users/$uid/profile/avatar.jpg';

  User _requireUser() {
    final user = _auth.currentUser;
    if (user == null) {
      throw const ProfilePhotoException(
        'Please sign in again to change your photo.',
        code: 'unauthenticated',
      );
    }
    return user;
  }

  @override
  Future<AppUser> uploadPhoto(
    Uint8List jpeg, {
    void Function(double progress)? onProgress,
  }) => _guard(() async {
    final user = _requireUser();
    final previous = user.photoURL;
    final ref = _storage.ref(pathFor(user.uid));
    final task = ref.putData(
      jpeg,
      SettableMetadata(
        contentType: 'image/jpeg',
        cacheControl: 'private, max-age=86400',
      ),
    );
    final progress = task.snapshotEvents.listen((s) {
      if (s.totalBytes > 0) onProgress?.call(s.bytesTransferred / s.totalBytes);
    }, onError: (_) {});
    try {
      await task.timeout(
        _timeout,
        onTimeout: () {
          unawaited(task.cancel());
          throw TimeoutException('Upload timed out');
        },
      );
    } finally {
      await progress.cancel();
    }
    final url = await ref.getDownloadURL().timeout(_timeout);
    await user.updatePhotoURL(url).timeout(_timeout);
    await _reload(user);
    // The download URL may be unchanged after an overwrite; drop any cached
    // copy so avatars show the new photo.
    _evict(previous);
    _evict(url);
    return (appUserFromFirebase(_auth.currentUser) ??
            appUserFromFirebase(user)!)
        .withPhotoUrl(url);
  });

  @override
  Future<AppUser> removePhoto() => _guard(() async {
    final user = _requireUser();
    final previous = user.photoURL;
    try {
      await _storage.ref(pathFor(user.uid)).delete().timeout(_timeout);
    } on FirebaseException catch (e) {
      // Nothing uploaded (e.g. the photo came from Google): just clear it.
      if (e.code != 'object-not-found') rethrow;
    }
    await user.updatePhotoURL(null).timeout(_timeout);
    await _reload(user);
    _evict(previous);
    return (appUserFromFirebase(_auth.currentUser) ??
            appUserFromFirebase(user)!)
        .withPhotoUrl(null);
  });

  Future<void> _reload(User user) async {
    try {
      await user.reload().timeout(_timeout);
    } catch (e) {
      // The change is saved; a stale local copy is refreshed next launch.
      debugPrint('Reloading the user after a photo change failed: $e');
    }
  }

  static void _evict(String? url) {
    if (url == null || url.isEmpty) return;
    unawaited(NetworkImage(url).evict());
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on ProfilePhotoException {
      rethrow;
    } on FirebaseAuthException catch (e) {
      throw ProfilePhotoException(firebaseAuthMessage(e.code), code: e.code);
    } on FirebaseException catch (e) {
      debugPrint('Profile photo request failed: ${e.code} ${e.message}');
      throw ProfilePhotoException(storageErrorMessage(e.code), code: e.code);
    } on TimeoutException {
      throw const ProfilePhotoException(
        'You are offline or the connection is too slow. Try again when you '
        'are connected.',
        code: 'timeout',
      );
    }
  }
}

/// User-facing message for a Firebase Storage error code.
String storageErrorMessage(String code) {
  switch (code) {
    case 'retry-limit-exceeded':
    case 'network-request-failed':
    case 'unavailable':
      return 'You are offline or the connection is too slow. Try again when '
          'you are connected.';
    case 'unauthorized':
    case 'permission-denied':
      return 'The photo was not accepted. Choose a JPEG or PNG under 1 MB.';
    case 'unauthenticated':
      return 'Please sign in again to change your photo.';
    case 'quota-exceeded':
      return 'Photo storage is full right now. Please try again later.';
    case 'canceled':
      return 'The upload was cancelled.';
    case 'bucket-not-found':
    case 'project-not-found':
      return 'Photo storage is not set up for this app yet.';
    default:
      return 'Your photo could not be saved. Please try again.';
  }
}
