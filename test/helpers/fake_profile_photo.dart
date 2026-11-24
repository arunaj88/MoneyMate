import 'dart:async';
import 'dart:typed_data';

import 'package:money_mate/core/services/photo_picker.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/models/app_user.dart';

/// In-memory [ProfilePhotoService] for one signed-in [user]. Set [error] to
/// make the next requests fail, or [gate] to hold them like a slow network.
class FakeProfilePhotoService implements ProfilePhotoService {
  FakeProfilePhotoService(this.user);

  AppUser user;
  ProfilePhotoException? error;
  Completer<void>? gate;
  Uint8List? uploaded;
  int uploads = 0;
  int removals = 0;

  static const urlPrefix = 'https://storage.test/users';

  Future<void> _check() async {
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
  }

  @override
  Future<AppUser> uploadPhoto(
    Uint8List jpeg, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(0.5);
    await _check();
    onProgress?.call(1);
    uploads++;
    uploaded = jpeg;
    user = user.withPhotoUrl(
      '$urlPrefix/${user.uid}/profile/avatar.jpg?v=$uploads',
    );
    return user;
  }

  @override
  Future<AppUser> removePhoto() async {
    await _check();
    removals++;
    uploaded = null;
    user = user.withPhotoUrl(null);
    return user;
  }
}

/// [PhotoPicker] that returns [photo] (null: the user cancels), or throws
/// [error]. [prepare] returns the photo unchanged unless [prepareError] is
/// set.
class FakePhotoPicker implements PhotoPicker {
  FakePhotoPicker({this.photo, this.camera = true});

  Uint8List? photo;
  bool camera;
  ProfilePhotoException? error;
  ProfilePhotoException? prepareError;
  final List<PhotoSource> picks = [];

  /// Permission before asking, and the user's answer to the system prompt.
  PhotoAccess access = PhotoAccess.granted;
  PhotoAccess answer = PhotoAccess.granted;
  final List<PhotoSource> requests = [];
  int settingsOpened = 0;

  @override
  Future<PhotoAccess> checkAccess(PhotoSource source) async => access;

  @override
  Future<PhotoAccess> requestAccess(PhotoSource source) async {
    requests.add(source);
    if (access != PhotoAccess.permanentlyDenied) access = answer;
    return access;
  }

  @override
  Future<bool> openSettings() async {
    settingsOpened++;
    return true;
  }

  @override
  bool supports(PhotoSource source) => source == PhotoSource.gallery || camera;

  @override
  Future<Uint8List?> pick(PhotoSource source) async {
    picks.add(source);
    if (error != null) throw error!;
    return photo;
  }

  @override
  Future<Uint8List> prepare(Uint8List photo) async {
    if (prepareError != null) throw prepareError!;
    return photo;
  }
}

/// A valid 1x1 PNG, small enough to decode in widget tests.
final Uint8List tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);
