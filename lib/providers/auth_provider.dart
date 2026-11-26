import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/auth_service.dart';
import 'package:money_mate/core/services/profile_photo_service.dart';
import 'package:money_mate/models/app_user.dart';

enum AuthStatus {
  unknown,

  /// Signed in with a verified email: the app is usable.
  authenticated,

  /// Signed in with an email address that is not verified yet (email and
  /// password accounts). Only the verification screen is shown, no
  /// account data is opened and [AuthProvider.isAuthenticated] is false.
  verificationRequired,

  unauthenticated,
}

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
///
/// Email/password accounts must verify their address before they are
/// [AuthStatus.authenticated]. When such an account signs in (or
/// registers, or the app restarts signed in) the provider checks Firebase
/// for a verification done meanwhile and, unless this device already asked
/// for one recently, has Firebase email a verification link. Google
/// accounts arrive verified and never see this.
class AuthProvider extends ChangeNotifier {
  AuthProvider(
    this._service,
    this._preferences, {
    ProfilePhotoService? photoService,
    DateTime Function()? clock,
  }) : _photoService = photoService,
       _clock = clock ?? DateTime.now {
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
  final DateTime Function() _clock;
  late final StreamSubscription<AppUser?> _subscription;

  AuthStatus _status = AuthStatus.unknown;
  AppUser? _user;
  AuthAction? _pending;
  String? _error;
  double? _photoProgress;
  bool _disposed = false;

  AuthStatus get status => _status;

  /// Signed in with a verified email. Account data (and everything that
  /// reads or syncs it) is only available in this state.
  bool get isAuthenticated => _status == AuthStatus.authenticated;

  /// Signed in, but the email address still has to be verified.
  bool get needsEmailVerification => _status == AuthStatus.verificationRequired;
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
      _endVerification();
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
    _status = user.needsEmailVerification
        ? AuthStatus.verificationRequired
        : AuthStatus.authenticated;
    unawaited(_preferences.setString(PrefKeys.userProfile, user.toJson()));
    if (_status == AuthStatus.verificationRequired) {
      if (_verificationUid != user.uid) _beginVerification(user);
    } else {
      _endVerification();
    }
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

  // ------------------------------------------------- email verification

  /// Shortest time between two verification emails from this device.
  static const Duration resendCooldown = Duration(seconds: 60);

  /// A link this device asked for within this time is not sent again
  /// automatically after a restart (Firebase links stay valid for days).
  static const Duration _autoResendAfter = Duration(hours: 24);

  /// The account whose verification is in progress.
  String? _verificationUid;
  bool _sendingEmail = false;
  bool _checkingVerification = false;
  DateTime? _emailSentAt;
  DateTime? _resendAvailableAt;
  String? _verificationError;
  Future<bool>? _checking;

  /// A verification email is being requested.
  bool get isSendingVerificationEmail => _sendingEmail;

  /// The user asked to check whether the email is verified now.
  bool get isCheckingVerification => _checkingVerification;

  /// When this device last had a verification email sent, or null.
  DateTime? get verificationEmailSentAt => _emailSentAt;

  /// When another email may be requested, or null if one may be now.
  DateTime? get resendAvailableAt => _resendAvailableAt;

  /// Message from the last failed send or check.
  String? get verificationError => _verificationError;

  /// Whether the resend button may be used now.
  bool get canResendVerificationEmail {
    if (!needsEmailVerification || _sendingEmail) return false;
    final at = _resendAvailableAt;
    return at == null || !_clock().isBefore(at);
  }

  bool _isVerifying(String uid) =>
      !_disposed && needsEmailVerification && _verificationUid == uid;

  void _beginVerification(AppUser user) {
    _resetVerificationState();
    _verificationUid = user.uid;
    final recent = _restoreEmailSent(user);
    unawaited(_startVerification(user.uid, emailRecentlySent: recent));
  }

  Future<void> _startVerification(
    String uid, {
    required bool emailRecentlySent,
  }) async {
    // Picks up a link opened before a restart or on another device, so no
    // needless email is sent.
    await refreshVerification();
    if (!_isVerifying(uid) || emailRecentlySent) return;
    await _sendEmail();
  }

  void _endVerification() {
    if (_verificationUid == null) return;
    _verificationUid = null;
    _resetVerificationState();
    unawaited(_preferences.remove(PrefKeys.verificationEmailSent));
  }

  void _resetVerificationState() {
    _emailSentAt = null;
    _resendAvailableAt = null;
    _verificationError = null;
  }

  static String? _normalEmail(AppUser user) => user.email?.trim().toLowerCase();

  /// Restores an email this device asked for recently (after an app
  /// restart). Returns whether there was one.
  bool _restoreEmailSent(AppUser user) {
    final raw = _preferences.getString(PrefKeys.verificationEmailSent);
    if (raw == null) return false;
    try {
      final map = jsonDecode(raw);
      if (map is! Map ||
          map['uid'] != user.uid ||
          map['email'] != _normalEmail(user) ||
          map['sentAt'] is! int) {
        return false;
      }
      final sentAt = DateTime.fromMillisecondsSinceEpoch(map['sentAt'] as int);
      final now = _clock();
      if (sentAt.isAfter(now) || now.difference(sentAt) >= _autoResendAfter) {
        return false;
      }
      _emailSentAt = sentAt;
      _resendAvailableAt = sentAt.add(resendCooldown);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Emails a new verification link. Returns false while the cooldown runs
  /// or another email is being requested, so rapid taps send one email.
  Future<bool> resendVerificationEmail() async {
    if (!canResendVerificationEmail) return false;
    return _sendEmail();
  }

  Future<bool> _sendEmail() async {
    final user = _user;
    if (user == null || !_isVerifying(user.uid) || _sendingEmail) {
      return false;
    }
    _sendingEmail = true;
    _verificationError = null;
    _notify();
    try {
      await _service.sendEmailVerification();
      if (!_isVerifying(user.uid)) return false;
      final now = _clock();
      _emailSentAt = now;
      _resendAvailableAt = now.add(resendCooldown);
      unawaited(
        _preferences.setString(
          PrefKeys.verificationEmailSent,
          jsonEncode({
            'uid': user.uid,
            'email': _normalEmail(user),
            'sentAt': now.millisecondsSinceEpoch,
          }),
        ),
      );
      return true;
    } on AuthException catch (e) {
      if (!_isVerifying(user.uid)) return false;
      _verificationError = e.code == 'too-many-requests'
          ? 'Too many emails requested. Please wait a few minutes and try '
                'again.'
          : e.message;
      // Firebase limits how often it emails one account.
      if (e.code == 'too-many-requests') {
        _resendAvailableAt = _clock().add(resendCooldown);
      }
      return false;
    } catch (e, stack) {
      debugPrint('Sending the verification email failed: $e\n$stack');
      if (_isVerifying(user.uid)) {
        _verificationError = 'Something went wrong. Please try again.';
      }
      return false;
    } finally {
      _sendingEmail = false;
      _notify();
    }
  }

  /// Checks Firebase now ("I've verified my email"). Returns true, and the
  /// dashboard opens, once the link has been opened. Otherwise shows why.
  Future<bool> checkEmailVerified() async {
    final user = _user;
    if (user == null || !_isVerifying(user.uid) || _checkingVerification) {
      return false;
    }
    _checkingVerification = true;
    _verificationError = null;
    _notify();
    try {
      final verified = await _check(quiet: false);
      if (!verified && _isVerifying(user.uid)) {
        _verificationError ??=
            "Your email isn't verified yet. Open the link in the email we "
            'sent to ${user.email}, then try again.';
      }
      return verified;
    } finally {
      _checkingVerification = false;
      _notify();
    }
  }

  /// Checks Firebase quietly, e.g. when the app returns to the foreground
  /// after the user opened the link. Does nothing when offline.
  Future<void> refreshVerification() async {
    if (needsEmailVerification) await _check(quiet: true);
  }

  /// Reloads the account; concurrent checks share one request.
  Future<bool> _check({required bool quiet}) =>
      _checking ??= _reload(quiet: quiet).whenComplete(() => _checking = null);

  Future<bool> _reload({required bool quiet}) async {
    final uid = _verificationUid;
    if (uid == null) return false;
    try {
      final user = await _service.reloadUser();
      if (user == null || !_isVerifying(uid) || user.uid != uid) return false;
      _setUser(user);
      _notify();
      return !user.needsEmailVerification;
    } on AuthException catch (e) {
      // An ended session signs out (the auth stream follows).
      debugPrint('Checking email verification failed: ${e.code}');
      if (!quiet && _isVerifying(uid)) _verificationError = e.message;
      return false;
    } catch (e) {
      debugPrint('Checking email verification failed: $e');
      if (!quiet && _isVerifying(uid)) {
        _verificationError = 'Something went wrong. Please try again.';
      }
      return false;
    }
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
