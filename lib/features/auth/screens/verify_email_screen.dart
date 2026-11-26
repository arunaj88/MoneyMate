import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/shared/widgets/app_logo.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';

/// Shown instead of the app while the signed-in account's email address is
/// unverified (email/password accounts). [AuthNavigator] replaces it with
/// the dashboard as soon as [AuthProvider] reports the account verified, so
/// there is no way around it.
///
/// Firebase emails a verification link (sent automatically, see
/// [AuthProvider]). Opening it on any device verifies the account; this
/// screen notices when the app returns to the foreground, every few seconds
/// while it is open, or when the user taps "I've verified my email".
class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});

  /// How often the screen quietly checks for a verification.
  static const Duration pollInterval = Duration(seconds: 10);

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen>
    with WidgetsBindingObserver {
  Timer? _ticker;
  int _seconds = 0;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted) return;
    _seconds++;
    if (_foreground &&
        _seconds % VerifyEmailScreen.pollInterval.inSeconds == 0) {
      unawaited(context.read<AuthProvider>().refreshVerification());
    }
    // Redraws the resend countdown.
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      unawaited(context.read<AuthProvider>().refreshVerification());
    }
  }

  Future<void> _check() async {
    final ok = await context.read<AuthProvider>().checkEmailVerified();
    if (ok && mounted) {
      showAppSnackBar(context, 'Email verified. Welcome to MoneyMate!');
    }
  }

  Future<void> _resend() async {
    final auth = context.read<AuthProvider>();
    final ok = await auth.resendVerificationEmail();
    if (ok && mounted) {
      showAppSnackBar(
        context,
        'A new verification link was sent to ${auth.user?.email}.',
      );
    }
  }

  Future<void> _useDifferentEmail() async {
    final auth = context.read<AuthProvider>();
    final confirmed = await showConfirmDialog(
      context,
      title: 'Use a different email?',
      message:
          'You will be signed out. Create an account with the correct email '
          'address, or sign in to an existing one.',
      confirmLabel: 'Sign out',
    );
    if (confirmed && mounted) await auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final auth = context.watch<AuthProvider>();
    // Verified: the account's data is opening, the dashboard follows.
    final entering = auth.isAuthenticated;
    final checking = auth.isCheckingVerification || entering;
    final busy = checking || auth.isSendingVerificationEmail || auth.isBusy;
    final email = auth.user?.email ?? '';
    final error = auth.verificationError;

    return Scaffold(
      key: const Key('verifyEmailScreen'),
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(Spacing.sm),
                child: TextButton.icon(
                  key: const Key('verifySignOutButton'),
                  onPressed: busy ? null : auth.signOut,
                  icon: auth.isRunning(AuthAction.signOut)
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.logout_rounded, size: 18),
                  label: const Text('Sign out'),
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    Spacing.xl,
                    0,
                    Spacing.xl,
                    Spacing.xl,
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(child: AppLogo(size: 64)),
                        const SizedBox(height: Spacing.lg),
                        Text(
                          'Verify Your Email',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: Spacing.sm),
                        Text(
                          'We sent a verification link to',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: Spacing.xs),
                        Text(
                          email,
                          key: const Key('verifyEmailAddress'),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: Spacing.xl),
                        _Steps(scheme: scheme, theme: theme),
                        const SizedBox(height: Spacing.lg),
                        if (error != null) ...[
                          _ErrorLine(message: error),
                          const SizedBox(height: Spacing.md),
                        ],
                        FilledButton(
                          key: const Key('checkVerifiedButton'),
                          onPressed: busy ? null : _check,
                          child: checking
                              ? const SizedBox.square(
                                  dimension: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : const Text("I've verified my email"),
                        ),
                        const SizedBox(height: Spacing.md),
                        _ResendRow(auth: auth, busy: busy, onResend: _resend),
                        const SizedBox(height: Spacing.sm),
                        Text(
                          "Can't find it? Check your spam or junk folder.",
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: Spacing.lg),
                        TextButton(
                          key: const Key('useDifferentEmailButton'),
                          onPressed: busy ? null : _useDifferentEmail,
                          child: const Text('Use a different email'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps({required this.scheme, required this.theme});

  final ColorScheme scheme;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    Widget step(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.primary),
          const SizedBox(width: Spacing.md),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(Spacing.lg),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Spacing.radiusSm),
      ),
      child: Column(
        children: [
          step(
            Icons.mark_email_unread_outlined,
            'Open the email from MoneyMate',
          ),
          step(Icons.link_rounded, 'Tap the verification link'),
          step(Icons.login_rounded, 'Come back here: we sign you in'),
        ],
      ),
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.error;
    return Row(
      key: const Key('verifyError'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(Icons.error_outline_rounded, size: 18, color: color),
        ),
        const SizedBox(width: Spacing.xs),
        Flexible(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _ResendRow extends StatelessWidget {
  const _ResendRow({
    required this.auth,
    required this.busy,
    required this.onResend,
  });

  final AuthProvider auth;
  final bool busy;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wait = auth.resendAvailableAt?.difference(DateTime.now());

    final Widget action;
    if (auth.isSendingVerificationEmail) {
      action = const Padding(
        padding: EdgeInsets.all(Spacing.md),
        child: SizedBox.square(
          dimension: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    } else if (wait != null && wait > Duration.zero) {
      final seconds = (wait.inMilliseconds / 1000).ceil();
      action = Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Text(
          'Resend in ${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
          key: const Key('resendCountdown'),
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    } else {
      action = TextButton(
        key: const Key('resendEmailButton'),
        onPressed: busy || !auth.canResendVerificationEmail ? null : onResend,
        child: const Text('Resend email'),
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text("Didn't get the email?", style: theme.textTheme.bodyMedium),
        action,
      ],
    );
  }
}
