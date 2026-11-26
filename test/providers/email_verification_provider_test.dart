import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/core/services/auth_service.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';

const unverified = AppUser(
  uid: 'uid-new',
  email: 'nia@example.com',
  displayName: 'Nia Patel',
  emailVerified: false,
);

class Setup {
  Setup(this.provider, this.service, this.prefs);

  final AuthProvider provider;
  final FakeAuthService service;
  final SharedPreferences prefs;
}

late DateTime now;

Future<Setup> setup({
  AppUser? signedIn,
  Map<String, Object> prefs = const {},
  void Function(FakeAuthService)? configure,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final preferences = await SharedPreferences.getInstance();
  final service = FakeAuthService(signedIn: signedIn);
  configure?.call(service);
  final provider = AuthProvider(service, preferences, clock: () => now);
  await pumpEventQueue();
  return Setup(provider, service, preferences);
}

String sentRecord(String uid, DateTime at) => jsonEncode({
  'uid': uid,
  'email': 'nia@example.com',
  'sentAt': at.millisecondsSinceEpoch,
});

void main() {
  setUp(() => now = DateTime(2026, 11, 26, 9));

  test('registration needs verification and emails one link', () async {
    final s = await setup();
    expect(
      await s.provider.register(
        name: 'Nia Patel',
        email: 'nia@example.com',
        password: 'secret123',
      ),
      isTrue,
    );
    await pumpEventQueue();

    expect(s.provider.status, AuthStatus.verificationRequired);
    expect(s.provider.isAuthenticated, isFalse);
    expect(s.provider.needsEmailVerification, isTrue);
    expect(s.provider.user!.email, 'nia@example.com');
    expect(s.service.verificationEmailsSent, 1);
    expect(s.service.calls.where((c) => c == 'register'), hasLength(1));
    expect(s.provider.verificationEmailSentAt, now);
    expect(s.provider.resendAvailableAt, now.add(const Duration(seconds: 60)));
    expect(s.provider.canResendVerificationEmail, isFalse);
    s.provider.dispose();
  });

  test('checking after the link was opened signs the user in', () async {
    final s = await setup(signedIn: unverified);
    expect(await s.provider.checkEmailVerified(), isFalse);
    expect(s.provider.verificationError, contains("isn't verified yet"));
    expect(s.provider.status, AuthStatus.verificationRequired);

    s.service.verifyOnServer();
    expect(await s.provider.checkEmailVerified(), isTrue);
    expect(s.provider.status, AuthStatus.authenticated);
    expect(s.provider.user!.emailVerified, isTrue);
    expect(s.provider.verificationError, isNull);
    await pumpEventQueue();
    expect(s.prefs.getString(PrefKeys.verificationEmailSent), isNull);
    s.provider.dispose();
  });

  test('returning to the app picks up a link opened elsewhere', () async {
    final s = await setup(signedIn: unverified);
    s.service.verifyOnServer();
    await s.provider.refreshVerification();
    expect(s.provider.status, AuthStatus.authenticated);
    s.provider.dispose();
  });

  test('resend waits 60 seconds and ignores rapid taps', () async {
    final s = await setup(signedIn: unverified);
    expect(s.service.verificationEmailsSent, 1);
    expect(await s.provider.resendVerificationEmail(), isFalse);

    now = now.add(const Duration(seconds: 59));
    expect(s.provider.canResendVerificationEmail, isFalse);
    now = now.add(const Duration(seconds: 1));
    expect(s.provider.canResendVerificationEmail, isTrue);

    final taps = await Future.wait([
      s.provider.resendVerificationEmail(),
      s.provider.resendVerificationEmail(),
      s.provider.resendVerificationEmail(),
    ]);
    expect(taps.where((ok) => ok), hasLength(1));
    expect(s.service.verificationEmailsSent, 2);
    s.provider.dispose();
  });

  test('a failed email can be resent at once, without a new account', () async {
    final s = await setup(
      signedIn: unverified,
      configure: (service) => service.sendError = AuthException(
        firebaseAuthMessage('network-request-failed'),
        code: 'network-request-failed',
      ),
    );
    expect(s.provider.verificationError, contains('No internet connection'));
    expect(s.provider.verificationEmailSentAt, isNull);
    expect(s.provider.canResendVerificationEmail, isTrue);

    expect(await s.provider.resendVerificationEmail(), isTrue);
    expect(s.service.verificationEmailsSent, 1);
    expect(s.provider.verificationError, isNull);
    expect(s.service.calls, isNot(contains('register')));
    s.provider.dispose();
  });

  test("Firebase's email limit shows a message and a cooldown", () async {
    final s = await setup(signedIn: unverified);
    now = now.add(const Duration(minutes: 2));
    s.service.sendError = AuthException(
      firebaseAuthMessage('too-many-requests'),
      code: 'too-many-requests',
    );
    expect(await s.provider.resendVerificationEmail(), isFalse);
    expect(s.provider.verificationError, contains('Too many emails'));
    expect(s.provider.canResendVerificationEmail, isFalse);
    s.provider.dispose();
  });

  test('after a restart a recent email is not sent again', () async {
    final sentAt = now.subtract(const Duration(seconds: 20));
    final s = await setup(
      signedIn: unverified,
      prefs: {
        PrefKeys.verificationEmailSent: sentRecord(unverified.uid, sentAt),
      },
    );
    expect(s.provider.status, AuthStatus.verificationRequired);
    expect(s.service.verificationEmailsSent, 0);
    expect(s.service.calls, contains('reload'));
    expect(s.provider.verificationEmailSentAt, sentAt);
    expect(
      s.provider.resendAvailableAt,
      sentAt.add(const Duration(seconds: 60)),
    );
    s.provider.dispose();
  });

  test('an old record, or another account, sends a new email', () async {
    final old = await setup(
      signedIn: unverified,
      prefs: {
        PrefKeys.verificationEmailSent: sentRecord(
          unverified.uid,
          now.subtract(const Duration(days: 2)),
        ),
      },
    );
    expect(old.service.verificationEmailsSent, 1);
    old.provider.dispose();

    final other = await setup(
      signedIn: unverified,
      prefs: {PrefKeys.verificationEmailSent: sentRecord('someone-else', now)},
    );
    expect(other.service.verificationEmailsSent, 1);
    other.provider.dispose();
  });

  test('an account verified before the app started gets no email', () async {
    final s = await setup(
      signedIn: unverified,
      configure: (service) => service.verifyOnServer(),
    );
    expect(s.provider.status, AuthStatus.authenticated);
    expect(s.service.verificationEmailsSent, 0);
    s.provider.dispose();
  });

  test('an expired session signs out', () async {
    final s = await setup(signedIn: unverified);
    s.service.reloadError = const AuthException(
      'Your session has expired. Please sign in again.',
      code: 'session-expired',
    );
    await s.provider.refreshVerification();
    await pumpEventQueue();
    expect(s.provider.status, AuthStatus.unauthenticated);
    expect(s.provider.user, isNull);
    s.provider.dispose();
  });

  test('a check while offline keeps the user on the screen', () async {
    final s = await setup(signedIn: unverified);
    s.service.reloadError = AuthException(
      firebaseAuthMessage('network-request-failed'),
      code: 'network-request-failed',
    );
    expect(await s.provider.checkEmailVerified(), isFalse);
    expect(s.provider.status, AuthStatus.verificationRequired);
    expect(s.provider.verificationError, contains('No internet connection'));
    s.provider.dispose();
  });

  test('verified Google accounts never get a verification email', () async {
    final s = await setup();
    expect(await s.provider.signInWithGoogle(), isTrue);
    await pumpEventQueue();
    expect(s.provider.status, AuthStatus.authenticated);
    expect(s.service.calls, ['google']);
    expect(s.service.verificationEmailsSent, 0);
    s.provider.dispose();
  });

  test('signing out clears the verification state', () async {
    final s = await setup(signedIn: unverified);
    expect(s.prefs.getString(PrefKeys.verificationEmailSent), isNotNull);
    expect(await s.provider.signOut(), isTrue);
    await pumpEventQueue();
    expect(s.provider.status, AuthStatus.unauthenticated);
    expect(s.provider.verificationEmailSentAt, isNull);
    expect(s.prefs.getString(PrefKeys.verificationEmailSent), isNull);
    expect(await s.provider.checkEmailVerified(), isFalse);
    expect(await s.provider.resendVerificationEmail(), isFalse);
    s.provider.dispose();
  });

  test('only accounts with an unverified email need verification', () {
    expect(
      const AppUser(uid: 'a', emailVerified: false).needsEmailVerification,
      isFalse,
    );
    expect(
      const AppUser(uid: 'a', email: 'a@x.io').needsEmailVerification,
      isFalse,
    );
    expect(unverified.needsEmailVerification, isTrue);
    expect(unverified.withEmailVerified(true).needsEmailVerification, isFalse);
  });
}
