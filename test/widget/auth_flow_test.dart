import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/app/home_shell.dart';
import 'package:money_mate/features/auth/screens/login_screen.dart';
import 'package:money_mate/features/auth/screens/verify_email_screen.dart';

import '../helpers/app_harness.dart';
import '../helpers/fakes.dart';

Future<void> fillLogin(
  WidgetTester tester, {
  required String email,
  required String password,
}) async {
  await tester.enterText(find.byKey(const Key('emailField')), email);
  await tester.enterText(find.byKey(const Key('passwordField')), password);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('signed-out users land on the login screen', (tester) async {
    await TestHarness(user: null).pump(tester);
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(find.text('Welcome back'), findsOneWidget);
  });

  testWidgets('signed-in users go straight to the dashboard with their name', (
    tester,
  ) async {
    await TestHarness().pump(tester);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
    final greeting = tester.widget<Text>(
      find.byKey(const Key('dashboardGreeting')),
    );
    expect(greeting.data, contains('Sam'));
    expect(find.text('SL'), findsWidgets); // avatar initials
  });

  testWidgets('login validates input and shows auth errors', (tester) async {
    final harness = TestHarness(user: null);
    await harness.pump(tester);

    await tapKey(tester, 'submitAuthButton');
    expect(find.text('Please enter your email'), findsOneWidget);
    expect(find.text('Please enter your password'), findsOneWidget);
    expect(harness.auth.calls, isEmpty);

    await fillLogin(tester, email: 'not-an-email', password: 'x');
    await tapKey(tester, 'submitAuthButton');
    expect(find.text('Enter a valid email address'), findsOneWidget);

    await fillLogin(tester, email: 'sam.lee@example.com', password: 'wrong');
    await tapKey(tester, 'submitAuthButton');
    expect(find.text('Incorrect email or password.'), findsOneWidget);
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('password visibility toggles', (tester) async {
    await TestHarness(user: null).pump(tester);
    TextField field() => tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const Key('passwordField')),
        matching: find.byType(TextField),
      ),
    );
    expect(field().obscureText, isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(field().obscureText, isFalse);
    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(field().obscureText, isTrue);
  });

  testWidgets('shows a loader and blocks repeat taps while signing in', (
    tester,
  ) async {
    final harness = TestHarness(user: null);
    await harness.pump(tester);
    harness.auth.gate = Completer<void>();

    await fillLogin(
      tester,
      email: 'sam.lee@example.com',
      password: 'secret123',
    );
    await tester.tap(find.byKey(const Key('submitAuthButton')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byKey(const Key('submitAuthButton')));
    await tester.tap(find.byKey(const Key('googleSignInButton')));
    await tester.pump();
    expect(harness.auth.calls, ['signIn']);

    harness.auth.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('registration validates and opens the dashboard', (tester) async {
    final harness = TestHarness(user: null);
    await harness.pump(tester);
    await tapKey(tester, 'toggleAuthModeButton');
    expect(find.text('Create your account'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('emailField')), 'new@x.io');
    await tester.enterText(find.byKey(const Key('passwordField')), '123');
    await tester.enterText(
      find.byKey(const Key('confirmPasswordField')),
      '456',
    );
    await tapKey(tester, 'submitAuthButton');
    expect(find.text('Please enter your name'), findsOneWidget);
    expect(find.text('Use at least 6 characters'), findsOneWidget);
    expect(find.text('Passwords do not match'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('nameField')), 'Nia Patel');
    await tester.enterText(find.byKey(const Key('passwordField')), 'secret1');
    await tester.enterText(
      find.byKey(const Key('confirmPasswordField')),
      'secret1',
    );
    await tapKey(tester, 'submitAuthButton');

    // New email/password accounts verify their email first.
    expect(harness.auth.calls.first, 'register');
    expect(harness.auth.calls.where((c) => c == 'register'), hasLength(1));
    expect(find.byType(VerifyEmailScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(harness.auth.verificationEmailsSent, 1);

    harness.auth.verifyOnServer();
    await tapKey(tester, 'checkVerifiedButton');
    expect(find.byType(HomeShell), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('dashboardGreeting'))).data,
      contains('Nia'),
    );
  });

  testWidgets('Google sign-in opens the dashboard', (tester) async {
    final harness = TestHarness(user: null);
    await harness.pump(tester);
    await tapKey(tester, 'googleSignInButton');
    // Google accounts are verified: no email, straight to the dashboard.
    expect(harness.auth.calls, ['google']);
    expect(harness.auth.verificationEmailsSent, 0);
    expect(find.byType(VerifyEmailScreen), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('forgot password sends a reset link', (tester) async {
    final harness = TestHarness(user: null);
    await harness.pump(tester);
    await tester.enterText(
      find.byKey(const Key('emailField')),
      'sam.lee@example.com',
    );
    await tapKey(tester, 'forgotPasswordButton');
    expect(find.text('Reset password'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Send link'));
    await tester.pumpAndSettle();

    expect(harness.auth.resetEmails, ['sam.lee@example.com']);
    expect(find.textContaining('Password reset link sent'), findsOneWidget);
  });

  testWidgets('sign out keeps local data and cannot navigate back', (
    tester,
  ) async {
    final harness = TestHarness(
      transactions: [
        tx(id: 'a', amountMinor: 1000, date: DateTime.now(), note: 'Lunch'),
      ],
    );
    await harness.pump(tester);
    await openTab(tester, 'Settings');
    expect(find.text('Sam Lee'), findsOneWidget);
    expect(find.text('sam.lee@example.com'), findsOneWidget);

    await tapKey(tester, 'signOutTile');
    expect(find.text('Sign out?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(HomeShell), findsNothing);
    expect(harness.transactions.items, hasLength(1));

    // The login screen is the only route: back cannot reveal the dashboard.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsNothing);
  });

  testWidgets('sign-in keeps its spinner until the dashboard opens', (
    tester,
  ) async {
    final harness = TestHarness(user: null);
    await harness.pump(tester);
    harness.accountGate = Completer<void>();

    await fillLogin(
      tester,
      email: 'sam.lee@example.com',
      password: 'secret123',
    );
    await tester.tap(find.byKey(const Key('submitAuthButton')));
    await tester.pump();
    await tester.pump();

    // Signed in, account data still opening: no frozen-looking screen.
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('submitAuthButton')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('googleSignInButton')))
          .onPressed,
      isNull,
    );

    harness.accountGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(HomeShell), findsOneWidget);
  });

  testWidgets('each account on a device sees only its own data', (
    tester,
  ) async {
    final harness = TestHarness(
      transactions: [
        tx(id: 'a', amountMinor: 1000, date: DateTime.now(), note: 'Lunch'),
      ],
    );
    await harness.pump(tester);
    expect(find.textContaining('Lunch'), findsWidgets);

    Future<void> signOut() async {
      await openTab(tester, 'Settings');
      await tapKey(tester, 'signOutTile');
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginScreen), findsOneWidget);
    }

    // A new account starts empty instead of showing Sam's records.
    await signOut();
    await tapKey(tester, 'toggleAuthModeButton');
    await tester.enterText(find.byKey(const Key('nameField')), 'Nia Patel');
    await fillLogin(tester, email: 'nia@x.io', password: 'secret1');
    await tester.enterText(
      find.byKey(const Key('confirmPasswordField')),
      'secret1',
    );
    await tapKey(tester, 'submitAuthButton');
    expect(find.byType(VerifyEmailScreen), findsOneWidget);
    harness.auth.verifyOnServer();
    await tapKey(tester, 'checkVerifiedButton');
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.textContaining('Lunch'), findsNothing);

    // Signing back in to the first account shows its data again.
    await signOut();
    await fillLogin(
      tester,
      email: 'sam.lee@example.com',
      password: 'secret123',
    );
    await tapKey(tester, 'submitAuthButton');
    expect(find.byType(HomeShell), findsOneWidget);
    expect(find.textContaining('Lunch'), findsWidgets);

    expect(harness.openedAccounts, hasLength(2));
    expect(harness.transactions.items, hasLength(1));
  });
}
