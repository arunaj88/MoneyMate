import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:money_mate/app/app_dependencies.dart';
import 'package:money_mate/providers/auth_provider.dart';

/// Opens the on-device data of whoever signs in, so every account on a
/// device sees only its own records.
///
/// The data of the last account stays open while nobody is signed in (it
/// is never deleted on sign-out) and is replaced as soon as a different
/// account signs in. An account's data is opened once per app run and
/// reused if that account signs in again.
class AccountSession extends ChangeNotifier {
  AccountSession(this._auth, this._open, {this.onOpenFailed}) {
    _auth.addListener(_onAuthChanged);
    _onAuthChanged();
  }

  /// Shown on the sign-in screen when an account's data cannot be opened.
  static const String openFailedMessage =
      'Your data on this device could not be opened. Please try again.';

  final AuthProvider _auth;
  final AccountDataOpener _open;

  /// Called after an account's data could not be opened and the account
  /// was signed out, to tell the user ([openFailedMessage]).
  final VoidCallback? onOpenFailed;
  final Map<String, Future<AccountData>> _opened = {};

  String? _uid;
  AccountData? _data;
  String? _opening;
  bool _disposed = false;

  /// The account whose data is open, or null before anyone signed in.
  String? get uid => _uid;

  /// The open account's repositories and services.
  AccountData? get data => _data;

  /// True once the signed-in account's own data is open.
  bool get isReady {
    final user = _auth.isAuthenticated ? _auth.user : null;
    return user != null && _data != null && user.uid == _uid;
  }

  void _onAuthChanged() {
    final uid = _auth.isAuthenticated ? _auth.user?.uid : null;
    if (uid == null || uid == _uid || uid == _opening) return;
    _opening = uid;
    unawaited(_load(uid));
  }

  Future<void> _load(String uid) async {
    try {
      final data = await (_opened[uid] ??= _open(uid));
      // Another account signed in while this one was opening.
      if (_disposed || _opening != uid) return;
      _opening = null;
      _uid = uid;
      _data = data;
      _notify();
    } catch (e, stack) {
      debugPrint('Opening account data failed: $e\n$stack');
      _opened.remove(uid);
      if (_disposed || _opening != uid) return;
      _opening = null;
      // Never show another account's data instead: go back to sign-in.
      await _auth.signOut();
      if (!_disposed) onOpenFailed?.call();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _auth.removeListener(_onAuthChanged);
    super.dispose();
  }
}
