import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../core/services/auth_service.dart';
import '../models/app_user.dart';

enum AuthStatus { unknown, authenticated, unauthenticated }

/// Authentication requests the UI can start. Only one runs at a time.
enum AuthAction { signIn, register, google, resetPassword, signOut }

/// Exposes the Firebase authentication state and auth actions to the UI.
///
/// The signed-in user's profile (UID, name, email and photo URL) is kept in
/// SharedPreferences so it is available offline and fills any field Firebase
/// has not delivered yet. Signing out clears only that profile; expense data
/// in SQLite is never touched.
class AuthProvider extends ChangeNotifier {
  AuthProvider(this._service, this._preferences) {
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
  late final StreamSubscription<AppUser?> _subscription;

  AuthStatus _status = AuthStatus.unknown;
  AppUser? _user;
  AuthAction? _pending;
  String? _error;
  bool _disposed = false;

  AuthStatus get status => _status;
  bool get isAuthenticated => _status == AuthStatus.authenticated;
  AppUser? get user => _user;

  /// True while any auth request is running.
  bool get isBusy => _pending != null;
  bool isRunning(AuthAction action) => _pending == action;

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
    final merged = user.mergeMissingFrom(_user).mergeMissingFrom(storedProfile);
    _user = merged;
    _status = AuthStatus.authenticated;
    unawaited(_preferences.setString(PrefKeys.userProfile, merged.toJson()));
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

  Future<bool> signOut() => _run(AuthAction.signOut, () async {
    await _service.signOut();
    return true;
  });

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
    } catch (e, stack) {
      debugPrint('Auth request $action failed: $e\n$stack');
      _error = 'Something went wrong. Please try again.';
      return false;
    } finally {
      _pending = null;
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
