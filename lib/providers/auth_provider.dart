import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../core/services/auth_service.dart';
import '../core/services/profile_photo_service.dart';
import '../models/app_user.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Authentication requests the UI can start. Only one runs at a time.
enum AuthAction {
  signIn,
  register,
  google,
  resetPassword,
  signOut,
  updatePhoto,
  removePhoto,
}

/// Exposes the Firebase authentication state and auth actions to the UI.
///
/// The signed-in user's profile (UID, name, email and photo URL) is kept in
/// SharedPreferences so it is available offline and fills any field Firebase
/// has not delivered yet. Signing out clears only that profile; expense data
/// in SQLite is never touched.
///
/// With a [ProfilePhotoService] the user can also change or remove their
/// profile photo; the cached profile is updated at once so every avatar
/// shows the new photo.
class AuthProvider extends ChangeNotifier {
  AuthProvider(
    this._service,
    this._preferences, {
    ProfilePhotoService? photoService,
  }) : _photoService = photoService {
    _subscription = _service.authStateChanges().listen(
      _onAuthStateChanged,
      onError: (Object e) {
        debugPrint('Auth state stream error: $e');
        _onAuthStateChanged(null);
      },
    );
  }

  final AuthService _service;
  final SharedPreferences _preferences;
  final ProfilePhotoService? _photoService;
  late final StreamSubscription<AppUser?> _subscription;

  AuthStatus _status = AuthStatus.unknown;
  AppUser? _user;
  AuthAction? _pending;
  String? _error;
  double? _photoProgress;
  bool _disposed = false;

  AuthStatus get status => _status;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  AppUser? get user => _user;

  /// True while any auth request is running.
  bool get isBusy => _pending != null;
  bool isRunning(AuthAction action) => _pending == action;

  /// Whether this build can change the profile photo.
  bool get canChangePhoto => _photoService != null && isAuthenticated;

  /// Fraction of the photo uploaded (0–1) while [AuthAction.updatePhoto]
  /// runs, otherwise null.
  double? get photoProgress => _photoProgress;

  /// Message from the last failed request, or null.
  String? get error => _error;

  /// Profile saved for the most recent signed-in user.
  AppUser? get storedProfile =>
      AppUser.fromJson(_preferences.getString(PrefKeys.userProfile));

  void _onAuthStateChanged(AppUser? user) {
    if (user == null) {
      _user = null;
      _status = AuthStatus.unauthenticated;
      unawaited(_preferences.remove(PrefKeys.userProfile));
    } else {
      _setUser(user);
    }
    _notify();
  }

  void _setUser(AppUser user) {
    _store(user.mergeMissingFrom(_user).mergeMissingFrom(storedProfile));
  }

  void _store(AppUser user) {
    _user = user;
    _status = AuthStatus.authenticated;
    unawaited(_preferences.setString(PrefKeys.userProfile, user.toJson()));
  }

  /// Applies a photo change: the photo is taken from [updated] as is (so a
  /// removed photo is not filled back in from the cache), other fields are
  /// merged as usual.
  void _setPhoto(AppUser updated) {
    final current = _user;
    final base = current != null && current.uid == updated.uid
        ? updated.mergeMissingFrom(current)
        : updated;
    _store(base.withPhotoUrl(updated.photoUrl));
  }

  Future<bool> signIn({required String email, required String password}) =>
      _run(AuthAction.signIn, () async {
        _setUser(
          await _service.signInWithEmail(email: email, password: password),
        );
        return true;
      });

  Future<bool> register({
    required String name,
    required String email,
    required String password,
  }) => _run(AuthAction.register, () async {
    _setUser(
      await _service.registerWithEmail(
        name: name,
        email: email,
        password: password,
      ),
    );
    return true;
  });

  /// Returns false without an [error] when the user cancels.
  Future<bool> signInWithGoogle() => _run(AuthAction.google, () async {
    final user = await _service.signInWithGoogle();
    if (user == null) return false;
    _setUser(user);
    return true;
  });

  Future<bool> sendPasswordReset(String email) =>
      _run(AuthAction.resetPassword, () async {
        await _service.sendPasswordResetEmail(email);
        return true;
      });

  /// Work that needs the signed-in account and must run before it signs
  /// out, such as removing this device's push registration.
  final List<Future<void> Function(String uid)> _signOutHooks = [];

  /// Runs [hook] before each sign-out. Hooks get a few seconds; a slow or
  /// failing hook never blocks signing out.
  void addSignOutHook(Future<void> Function(String uid) hook) {
    if (!_signOutHooks.contains(hook)) _signOutHooks.add(hook);
  }

  void removeSignOutHook(Future<void> Function(String uid) hook) =>
      _signOutHooks.remove(hook);

  static const Duration _signOutHookTimeout = Duration(seconds: 5);

  Future<bool> signOut() => _run(AuthAction.signOut, () async {
    final uid = _user?.uid;
    if (uid != null) {
      await Future.wait(
        List.of(_signOutHooks).map(
          (hook) => hook(uid)
              .timeout(_signOutHookTimeout)
              .catchError((Object e) => debugPrint('Sign-out hook: $e')),
        ),
      );
    }
    await _service.signOut();
    return true;
  });

  /// Uploads [jpeg] (prepared by [prepareProfilePhoto]) as the user's
  /// profile photo. Progress is reported through [photoProgress].
  Future<bool> updatePhoto(Uint8List jpeg) =>
      _run(AuthAction.updatePhoto, () async {
        final service = _requirePhotoService();
        if (jpeg.length > ProfilePhotoLimits.maxUploadBytes) {
          throw const ProfilePhotoException(
            'That photo is too large to upload. Try a different one.',
            code: 'too-large',
          );
        }
        _photoProgress = 0;
        _notify();
        final updated = await service.uploadPhoto(
          jpeg,
          onProgress: (p) {
            _photoProgress = p.clamp(0, 1).toDouble();
            _notify();
          },
        );
        _setPhoto(updated);
        return true;
      });

  /// Removes the user's profile photo (uploaded or from Google); avatars
  /// fall back to initials.
  Future<bool> removePhoto() => _run(AuthAction.removePhoto, () async {
    _setPhoto(await _requirePhotoService().removePhoto());
    return true;
  });

  ProfilePhotoService _requirePhotoService() {
    final service = _photoService;
    if (service == null || !isAuthenticated) {
      throw const ProfilePhotoException(
        'Sign in to change your profile photo.',
      );
    }
    return service;
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  /// Runs [request] unless another request is already in progress.
  Future<bool> _run(AuthAction action, Future<bool> Function() request) async {
    if (_pending != null) return false;
    _pending = action;
    _error = null;
    _notify();
    try {
      return await request();
    } on AuthException catch (e) {
      _error = e.message;
      return false;
    } on ProfilePhotoException catch (e) {
      _error = e.message;
      return false;
    } catch (e, stack) {
      debugPrint('Auth request $action failed: $e\n$stack');
      _error = 'Something went wrong. Please try again.';
      return false;
    } finally {
      _pending = null;
      _photoProgress = null;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    super.dispose();
  }
}
