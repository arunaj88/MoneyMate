import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../models/app_user.dart';

/// An authentication failure with a message that can be shown to the user.
class AuthException implements Exception {
  const AuthException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'AuthException($code): $message';
}

/// Authentication operations used by the app. The Firebase implementation is
/// used in production; tests provide an in-memory fake.
abstract class AuthService {
  /// Emits the current user (or null) on listen, then on every sign-in and
  /// sign-out.
  Stream<AppUser?> authStateChanges();

  AppUser? get currentUser;

  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  });

  /// Creates an account and sets its display name.
  Future<AppUser> registerWithEmail({
    required String name,
    required String email,
    required String password,
  });

  /// Returns null when the user closes the Google account picker.
  Future<AppUser?> signInWithGoogle();

  Future<void> sendPasswordResetEmail(String email);

  Future<void> signOut();
}

/// [AuthService] backed by Firebase Authentication and Google Sign-In.
class FirebaseAuthService implements AuthService {
  FirebaseAuthService({FirebaseAuth? auth, GoogleSignIn? googleSignIn})
    : _auth = auth ?? FirebaseAuth.instance,
      _googleSignIn = googleSignIn ?? GoogleSignIn.instance;

  final FirebaseAuth _auth;
  final GoogleSignIn _googleSignIn;
  Future<void>? _googleInit;

  static AppUser? _map(User? user) => user == null
      ? null
      : AppUser(
          uid: user.uid,
          email: user.email,
          displayName: user.displayName,
          photoUrl: user.photoURL,
        );

  @override
  Stream<AppUser?> authStateChanges() => _auth.authStateChanges().map(_map);

  @override
  AppUser? get currentUser => _map(_auth.currentUser);

  @override
  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  }) => _guard(() async {
    final result = await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    return _map(result.user)!;
  });

  @override
  Future<AppUser> registerWithEmail({
    required String name,
    required String email,
    required String password,
  }) => _guard(() async {
    final result = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    final user = result.user!;
    await user.updateDisplayName(name.trim());
    await user.reload();
    return _map(_auth.currentUser ?? user)!;
  });

  @override
  Future<AppUser?> signInWithGoogle() => _guard(() async {
    final UserCredential result;
    if (kIsWeb) {
      result = await _auth.signInWithPopup(GoogleAuthProvider());
    } else {
      await (_googleInit ??= _googleSignIn.initialize());
      if (!_googleSignIn.supportsAuthenticate()) {
        throw const AuthException(
          'Google sign-in is not available on this device.',
        );
      }
      final GoogleSignInAccount account;
      try {
        account = await _googleSignIn.authenticate();
      } on GoogleSignInException catch (e) {
        if (e.code == GoogleSignInExceptionCode.canceled ||
            e.code == GoogleSignInExceptionCode.interrupted) {
          return null;
        }
        rethrow;
      }
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw const AuthException(
          'Google did not return a sign-in token. Please try again.',
        );
      }
      result = await _auth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
    }
    return _map(result.user);
  });

  @override
  Future<void> sendPasswordResetEmail(String email) =>
      _guard(() => _auth.sendPasswordResetEmail(email: email.trim()));

  @override
  Future<void> signOut() => _guard(() async {
    // Clear the cached Google account so the picker shows next time.
    if (!kIsWeb && _googleInit != null) {
      try {
        await _googleSignIn.signOut();
      } catch (e) {
        debugPrint('Google sign-out failed: $e');
      }
    }
    await _auth.signOut();
  });

  /// Converts Firebase and Google errors into [AuthException]s.
  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on AuthException {
      rethrow;
    } on FirebaseAuthException catch (e) {
      throw AuthException(firebaseAuthMessage(e.code), code: e.code);
    } on GoogleSignInException catch (e) {
      debugPrint('Google sign-in failed: ${e.code} ${e.description}');
      throw AuthException(
        e.code == GoogleSignInExceptionCode.clientConfigurationError ||
                e.code == GoogleSignInExceptionCode.providerConfigurationError
            ? 'Google sign-in is not configured for this app yet.'
            : 'Google sign-in failed. Please try again.',
        code: e.code.name,
      );
    } on StateError catch (e) {
      // google_sign_in throws when serverClientId is missing on Android.
      debugPrint('Google sign-in setup error: $e');
      throw const AuthException(
        'Google sign-in is not configured for this app yet.',
      );
    }
  }
}

/// User-facing message for a Firebase Authentication error code.
String firebaseAuthMessage(String code) {
  switch (code) {
    case 'invalid-email':
      return 'That email address is not valid.';
    case 'user-disabled':
      return 'This account has been disabled.';
    case 'user-not-found':
    case 'wrong-password':
    case 'invalid-credential':
    case 'INVALID_LOGIN_CREDENTIALS':
      return 'Incorrect email or password.';
    case 'email-already-in-use':
      return 'An account already exists for that email. Try signing in.';
    case 'weak-password':
      return 'Choose a stronger password (at least 6 characters).';
    case 'too-many-requests':
      return 'Too many attempts. Please wait a moment and try again.';
    case 'network-request-failed':
      return 'No internet connection. Check your network and try again.';
    case 'operation-not-allowed':
      return 'This sign-in method is not enabled for the app.';
    case 'account-exists-with-different-credential':
      return 'This email is already registered with a different sign-in '
          'method.';
    case 'popup-closed-by-user':
    case 'cancelled-popup-request':
      return 'Sign-in was cancelled.';
    case 'requires-recent-login':
      return 'Please sign in again to continue.';
    default:
      return 'Something went wrong. Please try again.';
  }
}
