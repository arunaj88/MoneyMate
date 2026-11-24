import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:money_mate/core/services/profile_photo_service.dart';

/// Where a new photo comes from.
enum PhotoSource { gallery, camera }

/// Whether the app may open the gallery or camera.
enum PhotoAccess {
  /// Allowed (on Android 14+ this includes "selected photos only").
  granted,

  /// Not allowed yet; asking again shows the system prompt.
  denied,

  /// Turned off for good ("Don't allow" twice, or restricted): only the
  /// device settings can turn it back on.
  permanentlyDenied,
}

/// Lets the user choose or take a photo. Tests provide a fake.
abstract class PhotoPicker {
  /// Whether [source] works on this device (desktop has no camera picker).
  bool supports(PhotoSource source);

  /// Current permission for [source], without asking the user.
  Future<PhotoAccess> checkAccess(PhotoSource source);

  /// Shows the system permission prompt for [source] (if it can still be
  /// shown) and returns the result.
  Future<PhotoAccess> requestAccess(PhotoSource source);

  /// Opens this app's page in the device settings. Returns false when that
  /// is not possible.
  Future<bool> openSettings();

  /// The chosen photo's bytes, or null when the user cancels.
  ///
  /// Throws [ProfilePhotoException] when access is denied or no camera is
  /// available.
  Future<Uint8List?> pick(PhotoSource source);

  /// Turns a picked photo into the square JPEG that is uploaded (see
  /// [prepareProfilePhoto]). Throws [ProfilePhotoException].
  Future<Uint8List> prepare(Uint8List photo);
}

/// [PhotoPicker] backed by `image_picker`. On Android and iOS the platform
/// already downscales and compresses the photo; [prepareProfilePhoto]
/// finishes the job everywhere.
class ImagePickerPhotoPicker implements PhotoPicker {
  ImagePickerPhotoPicker([ImagePicker? picker])
    : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  static ImageSource _source(PhotoSource s) =>
      s == PhotoSource.camera ? ImageSource.camera : ImageSource.gallery;

  @override
  bool supports(PhotoSource source) {
    try {
      return _picker.supportsImageSource(_source(source));
    } catch (_) {
      return source == PhotoSource.gallery;
    }
  }

  /// Runtime permissions exist on Android and iOS only; elsewhere the
  /// system file dialog is the user's choice.
  static bool get _usesPermissions =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Gallery access is `READ_MEDIA_IMAGES` on Android 13+ ([Permission.photos])
  /// and `READ_EXTERNAL_STORAGE` before that ([Permission.storage]); the one
  /// that does not apply to the device always reports denied, so both are
  /// checked and either one grants access.
  static List<Permission> _permissions(PhotoSource source) =>
      source == PhotoSource.camera
      ? [Permission.camera]
      : defaultTargetPlatform == TargetPlatform.android
      ? [Permission.photos, Permission.storage]
      : [Permission.photos];

  static PhotoAccess _combine(Iterable<PermissionStatus> statuses) {
    if (statuses.any((s) => s.isGranted || s.isLimited)) {
      return PhotoAccess.granted;
    }
    if (statuses.any((s) => s.isPermanentlyDenied || s.isRestricted)) {
      return PhotoAccess.permanentlyDenied;
    }
    return PhotoAccess.denied;
  }

  @override
  Future<PhotoAccess> checkAccess(PhotoSource source) async {
    if (!_usesPermissions) return PhotoAccess.granted;
    final statuses = <PermissionStatus>[
      for (final p in _permissions(source)) await p.status,
    ];
    return _combine(statuses);
  }

  @override
  Future<PhotoAccess> requestAccess(PhotoSource source) async {
    if (!_usesPermissions) return PhotoAccess.granted;
    final result = await _permissions(source).request();
    return _combine(result.values);
  }

  @override
  Future<bool> openSettings() => openAppSettings();

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    try {
      final file = await _picker.pickImage(
        source: _source(source),
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
        preferredCameraDevice: CameraDevice.front,
        requestFullMetadata: false,
      );
      if (file == null) return null;
      if (await file.length() > ProfilePhotoLimits.maxSourceBytes) {
        throw const ProfilePhotoException(
          'That photo is too large. Choose one under 25 MB.',
          code: 'too-large',
        );
      }
      return await file.readAsBytes();
    } on PlatformException catch (e) {
      throw ProfilePhotoException(pickerErrorMessage(e.code), code: e.code);
    }
  }

  /// Decoding and encoding happen on a background isolate (where the
  /// platform has one) so the preview's progress indicator keeps moving.
  @override
  Future<Uint8List> prepare(Uint8List photo) =>
      compute(prepareProfilePhoto, photo, debugLabel: 'prepareProfilePhoto');
}

/// User-facing message for an `image_picker` error code.
String pickerErrorMessage(String code) {
  switch (code) {
    case 'photo_access_denied':
    case 'photo_access_restricted':
      return 'MoneyMate is not allowed to open your photos. Allow photo '
          'access in your device settings and try again.';
    case 'camera_access_denied':
    case 'camera_access_restricted':
      return 'MoneyMate is not allowed to use the camera. Allow camera '
          'access in your device settings and try again.';
    case 'no_available_camera':
      return 'No camera is available on this device.';
    case 'invalid_image':
      return 'That file is not a supported image. Choose a JPEG or PNG photo.';
    default:
      return 'The photo could not be opened. Please try again.';
  }
}
