import 'dart:async';

import 'package:flutter/material.dart';

import 'package:money_mate/features/auth/screens/login_screen.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/app/home_shell.dart';

enum _Destination { login, home }

/// Keeps the navigator in step with the authentication state.
///
/// The app starts on the splash screen. Once the saved session has been
/// checked (and the splash has shown for [minSplashDuration]) it replaces the
/// whole route stack with the dashboard or the login screen. It does the same
/// whenever the state changes later, so after signing out every protected
/// route — including dialogs and pushed screens — is removed and the back
/// button cannot return to them.
class AuthNavigator extends StatefulWidget {
  const AuthNavigator({
    super.key,
    required this.auth,
    required this.navigatorKey,
    required this.minSplashDuration,
    required this.child,
  });

  final AuthProvider auth;
  final GlobalKey<NavigatorState> navigatorKey;
  final Duration minSplashDuration;
  final Widget child;

  @override
  State<AuthNavigator> createState() => _AuthNavigatorState();
}

class _AuthNavigatorState extends State<AuthNavigator> {
  _Destination? _current;
  bool _splashElapsed = false;
  Timer? _splashTimer;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(_scheduleSync);
    if (widget.minSplashDuration <= Duration.zero) {
      _splashElapsed = true;
    } else {
      _splashTimer = Timer(widget.minSplashDuration, () {
        _splashElapsed = true;
        _scheduleSync();
      });
    }
    _scheduleSync();
  }

  @override
  void didUpdateWidget(AuthNavigator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth != widget.auth) {
      oldWidget.auth.removeListener(_scheduleSync);
      widget.auth.addListener(_scheduleSync);
      _scheduleSync();
    }
  }

  @override
  void dispose() {
    widget.auth.removeListener(_scheduleSync);
    _splashTimer?.cancel();
    super.dispose();
  }

  /// Navigation must not happen during a build, so run it after the frame.
  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _sync();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _sync() {
    final status = widget.auth.status;
    if (status == AuthStatus.unknown || !_splashElapsed) return;
    final target = status == AuthStatus.authenticated
        ? _Destination.home
        : _Destination.login;
    if (target == _current) return;
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) {
      _scheduleSync();
      return;
    }
    _current = target;
    navigator.pushAndRemoveUntil(_route(target), (_) => false);
  }

  Route<void> _route(_Destination destination) => PageRouteBuilder<void>(
    settings: RouteSettings(name: '/${destination.name}'),
    transitionDuration: const Duration(milliseconds: 350),
    pageBuilder: (_, _, _) => switch (destination) {
      _Destination.home => const HomeShell(),
      _Destination.login => const LoginScreen(),
    },
    transitionsBuilder: (_, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );

  @override
  Widget build(BuildContext context) => widget.child;
}
