import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/app/home_shell.dart';
import 'package:money_mate/core/services/auth_service.dart';
import 'package:money_mate/features/auth/screens/login_screen.dart';
import 'package:money_mate/features/auth/screens/verify_email_screen.dart';
import 'package:money_mate/models/app_user.dart';

import '../helpers/app_harness.dart';

const unverified = AppUser(
  uid: 'uid-new',
  email: 'nia@example.com',
  displayName: 'Nia Patel',
  emailVerified: false,
);

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an unverified account opens on the verification screen', (
    tester,
  ) async {
    final harness = TestHarness(user: unverified);
    await harness.pump(tester);

    expect(find.byType(VerifyEmailScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(find.text('Verify Your Email'), findsOneWidget);
    expect(find.text('nia@example.com'), findsOneWidget);
    expect(harness.auth.verificationEmailsSent, 1);
    // No account data is opened for an unverified account.
    expect(harness.openedAccounts, isEmpty);

    // The verification screen is the only route.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsNothing);
  });

  testWidgets("checking before the link is opened explains what to do", (
    tester,
  ) async {
    final harness = TestHarness(user: unverified);
    await harness.pump(tester);

    await tap(tester, 'checkVerifiedButton');
    expect(find.textContaining("isn't verified yet"), findsOneWidget);
    expect(find.byType(VerifyEmailScreen), findsOneWidget);

    harness.auth.verifyOnServer();
    await tap(tester, 'checkVerifiedButton');
    expect(find.byType(HomeShell), findsOneWidget);
    expect(harness.openedAccounts, [unverified.uid]);
    expect(find.text('Email verified. Welcome to MoneyMate!'), findsOneWidget);
  });

  testWidgets('returning to the app after opening the link signs in', (
    tester,
  ) async {
    final harness = TestHarness(user: unverified);
    await harness.pump(tester);

    harness.auth.verifyOnServer();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('the screen checks again every few seconds', (tester) async {
    final harness = TestHarness(user: unverified);
    await harness.pump(tester);

    harness.auth.verifyOnServer();
    await tester.pump(VerifyEmailScreen.pollInterval);
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('resend counts down, then sends a new link', (tester) async {
    final harness = TestHarness(user: unverified);
    harness.auth.sendError = AuthException(
      firebaseAuthMessage('network-request-failed'),
      code: 'network-request-failed',
    );
    await harness.pump(tester);

    // The first email failed: the error shows and resend is available.
    expect(find.textContaining('No internet connection'), findsOneWidget);
    await tap(tester, 'resendEmailButton');
    expect(harness.auth.verificationEmailsSent, 1);
    expect(
      find.textContaining('A new verification link was sent'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('resendEmailButton')), findsNothing);
    expect(find.textContaining('Resend in 1:00'), findsOneWidget);
  });

  testWidgets('sign out returns to the login screen', (tester) async {
    final harness = TestHarness(user: unverified);
    await harness.pump(tester);

    await tap(tester, 'verifySignOutButton');
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(harness.auth.calls, contains('signOut'));
  });

  testWidgets('use a different email asks, then signs out', (tester) async {
    final harness = TestHarness(user: unverified);
    await harness.pump(tester);

    await tap(tester, 'useDifferentEmailButton');
    expect(find.text('Use a different email?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(VerifyEmailScreen), findsOneWidget);

    await tap(tester, 'useDifferentEmailButton');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('verified accounts never see the verification screen', (
    tester,
  ) async {
    final harness = TestHarness();
    await harness.pump(tester);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(harness.auth.calls, isNot(contains('sendVerification')));
  });

  testWidgets('the screen fits a small phone', (tester) async {
    await TestHarness(
      user: unverified,
    ).pump(tester, logicalSize: const Size(320, 568), devicePixelRatio: 2);
    expect(find.byType(VerifyEmailScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
