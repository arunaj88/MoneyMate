import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/theme/app_theme.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:money_mate/shared/widgets/app_logo.dart';
import 'package:money_mate/shared/widgets/dialogs.dart';

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

String? validateEmail(String? value) {
  final v = value?.trim() ?? '';
  if (v.isEmpty) return 'Please enter your email';
  if (!_emailPattern.hasMatch(v)) return 'Enter a valid email address';
  return null;
}

/// Email/password sign-in and registration, Google sign-in and password
/// reset. Navigation after a successful sign-in is handled by
/// [AuthNavigator], which reacts to the auth state.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _registering = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  /// How the user last signed in from this screen. After a successful
  /// sign-in the screen stays up while the account's data opens; that
  /// button keeps its spinner until the dashboard appears.
  bool _usedGoogle = false;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _toggleMode() {
    context.read<AuthProvider>().clearError();
    _formKey.currentState?.reset();
    setState(() => _registering = !_registering);
  }

  void _showError(AuthProvider auth) {
    final message = auth.error;
    if (message != null && mounted) {
      showAppSnackBar(context, message, isError: true);
    }
  }

  Future<void> _submit() async {
    final auth = context.read<AuthProvider>();
    if (auth.isBusy) return;
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;
    setState(() => _usedGoogle = false);

    final ok = _registering
        ? await auth.register(
            name: _name.text,
            email: _email.text,
            password: _password.text,
          )
        : await auth.signIn(email: _email.text, password: _password.text);
    if (!ok) _showError(auth);
  }

  Future<void> _google() async {
    final auth = context.read<AuthProvider>();
    if (auth.isBusy) return;
    FocusScope.of(context).unfocus();
    setState(() => _usedGoogle = true);
    final ok = await auth.signInWithGoogle();
    if (!ok) _showError(auth);
  }

  Future<void> _forgotPassword() async {
    final auth = context.read<AuthProvider>();
    if (auth.isBusy) return;
    final email = await showDialog<String>(
      context: context,
      builder: (_) => _ResetPasswordDialog(initialEmail: _email.text.trim()),
    );
    if (email == null || !mounted) return;
    final ok = await auth.sendPasswordReset(email);
    if (!mounted) return;
    if (ok) {
      showAppSnackBar(
        context,
        'Password reset link sent to $email. Check your inbox.',
      );
    } else {
      _showError(auth);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final auth = context.watch<AuthProvider>();
    // Signed in, waiting for the dashboard (the account's data is opening).
    final entering = auth.isAuthenticated;
    final busy = auth.isBusy || entering;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.xl,
              vertical: Spacing.xl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: AppLogo(size: 64)),
                      const SizedBox(height: Spacing.lg),
                      Text(
                        _registering ? 'Create your account' : 'Welcome back',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: Spacing.xs),
                      Text(
                        _registering
                            ? 'Sign up to start using ${AppConstants.appName}'
                            : 'Sign in to ${AppConstants.appName}',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: Spacing.xl),
                      if (_registering) ...[
                        TextFormField(
                          key: const Key('nameField'),
                          controller: _name,
                          enabled: !busy,
                          textCapitalization: TextCapitalization.words,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.name],
                          decoration: const InputDecoration(
                            labelText: 'Full name',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                          validator: (v) {
                            final name = v?.trim() ?? '';
                            if (name.isEmpty) return 'Please enter your name';
                            if (name.length > 50) return 'Name is too long';
                            return null;
                          },
                        ),
                        const SizedBox(height: Spacing.md),
                      ],
                      TextFormField(
                        key: const Key('emailField'),
                        controller: _email,
                        enabled: !busy,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: validateEmail,
                      ),
                      const SizedBox(height: Spacing.md),
                      TextFormField(
                        key: const Key('passwordField'),
                        controller: _password,
                        enabled: !busy,
                        obscureText: _obscurePassword,
                        textInputAction: _registering
                            ? TextInputAction.next
                            : TextInputAction.done,
                        autofillHints: [
                          _registering
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        onFieldSubmitted: (_) {
                          if (!_registering) _submit();
                        },
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: _VisibilityToggle(
                            obscured: _obscurePassword,
                            onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                          ),
                        ),
                        validator: (v) {
                          final p = v ?? '';
                          if (p.isEmpty) return 'Please enter your password';
                          if (_registering && p.length < 6) {
                            return 'Use at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      if (_registering) ...[
                        const SizedBox(height: Spacing.md),
                        TextFormField(
                          key: const Key('confirmPasswordField'),
                          controller: _confirm,
                          enabled: !busy,
                          obscureText: _obscureConfirm,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) => _submit(),
                          decoration: InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: _VisibilityToggle(
                              obscured: _obscureConfirm,
                              onPressed: () => setState(
                                () => _obscureConfirm = !_obscureConfirm,
                              ),
                            ),
                          ),
                          validator: (v) => v != _password.text
                              ? 'Passwords do not match'
                              : null,
                        ),
                      ],
                      if (!_registering)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            key: const Key('forgotPasswordButton'),
                            onPressed: busy ? null : _forgotPassword,
                            child: const Text('Forgot password?'),
                          ),
                        )
                      else
                        const SizedBox(height: Spacing.lg),
                      FilledButton(
                        key: const Key('submitAuthButton'),
                        onPressed: busy ? null : _submit,
                        child: _ButtonContent(
                          loading:
                              auth.isRunning(AuthAction.signIn) ||
                              auth.isRunning(AuthAction.register) ||
                              (entering && !_usedGoogle),
                          label: _registering ? 'Create account' : 'Sign in',
                        ),
                      ),
                      const SizedBox(height: Spacing.lg),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Spacing.md,
                            ),
                            child: Text(
                              'or',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: Spacing.lg),
                      OutlinedButton(
                        key: const Key('googleSignInButton'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: busy ? null : _google,
                        child: _ButtonContent(
                          loading:
                              auth.isRunning(AuthAction.google) ||
                              (entering && _usedGoogle),
                          label: 'Continue with Google',
                          icon: const _GoogleMark(),
                        ),
                      ),
                      const SizedBox(height: Spacing.xl),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(
                              _registering
                                  ? 'Already have an account?'
                                  : 'New to ${AppConstants.appName}?',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          TextButton(
                            key: const Key('toggleAuthModeButton'),
                            onPressed: busy ? null : _toggleMode,
                            child: Text(
                              _registering ? 'Sign in' : 'Create account',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VisibilityToggle extends StatelessWidget {
  const _VisibilityToggle({required this.obscured, required this.onPressed});

  final bool obscured;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: obscured ? 'Show password' : 'Hide password',
      icon: Icon(
        obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
      ),
      onPressed: onPressed,
    );
  }
}

/// Button label that swaps to a spinner while its request runs.
class _ButtonContent extends StatelessWidget {
  const _ButtonContent({required this.loading, required this.label, this.icon});

  final bool loading;
  final String label;
  final Widget? icon;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      );
    }
    if (icon == null) return Text(label);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon!,
        const SizedBox(width: Spacing.md),
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

/// A simple multicolour "G" so the button reads as Google without bundling
/// a trademark asset.
class _GoogleMark extends StatelessWidget {
  const _GoogleMark();

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (rect) => const SweepGradient(
        colors: [
          Color(0xFFEA4335),
          Color(0xFFFBBC05),
          Color(0xFF34A853),
          Color(0xFF4285F4),
          Color(0xFFEA4335),
        ],
      ).createShader(rect),
      child: const Text(
        'G',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: Colors.white,
          height: 1,
        ),
      ),
    );
  }
}

class _ResetPasswordDialog extends StatefulWidget {
  const _ResetPasswordDialog({required this.initialEmail});

  final String initialEmail;

  @override
  State<_ResetPasswordDialog> createState() => _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends State<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialEmail);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Reset password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter your account email and we will send you a link to '
              'choose a new password.',
            ),
            const SizedBox(height: Spacing.lg),
            TextFormField(
              key: const Key('resetEmailField'),
              controller: _controller,
              autofocus: widget.initialEmail.isEmpty,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Email'),
              validator: validateEmail,
              onFieldSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(64, 40)),
          onPressed: _submit,
          child: const Text('Send link'),
        ),
      ],
    );
  }
}
