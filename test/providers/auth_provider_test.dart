import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_mate/core/constants/app_constants.dart';
import 'package:money_mate/models/app_user.dart';
import 'package:money_mate/providers/auth_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fakes.dart';

Future<(AuthProvider, FakeAuthService, SharedPreferences)> createProvider({
  AppUser? signedIn,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final service = FakeAuthService(signedIn: signedIn);
  final provider = AuthProvider(service, prefs);
  await pumpEventQueue();
  return (provider, service, prefs);
}

void main() {
  test('starts unknown, then follows the saved session', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final provider = AuthProvider(FakeAuthService(signedIn: testUser), prefs);
    expect(provider.status, AuthStatus.unknown);
    await pumpEventQueue();
    expect(provider.status, AuthStatus.authenticated);
    expect(provider.user, testUser);
    provider.dispose();
  });

  test('signed-out session resolves to unauthenticated', () async {
    final (provider, _, _) = await createProvider();
    expect(provider.status, AuthStatus.unauthenticated);
    expect(provider.user, isNull);
    provider.dispose();
  });

  test('stores UID, name, email and photo URL of the signed-in user', () async {
    final (provider, service, prefs) = await createProvider();
    service.googleUser = const AppUser(
      uid: 'g-1',
      email: 'ana@example.com',
      displayName: 'Ana Ruiz',
      photoUrl: 'https://example.com/ana.png',
    );
    expect(await provider.signInWithGoogle(), isTrue);
    await pumpEventQueue();

    final stored = AppUser.fromJson(prefs.getString(PrefKeys.userProfile));
    expect(stored, service.googleUser);
    expect(provider.user!.firstName, 'Ana');
    expect(provider.user!.initials, 'AR');
    provider.dispose();
  });

  test('wrong password sets a readable error', () async {
    final (provider, _, _) = await createProvider();
    final ok = await provider.signIn(
      email: 'sam.lee@example.com',
      password: 'nope',
    );
    expect(ok, isFalse);
    expect(provider.error, 'Incorrect email or password.');
    expect(provider.status, AuthStatus.unauthenticated);
    expect(provider.isBusy, isFalse);
    provider.dispose();
  });

  test('ignores duplicate requests while one is running', () async {
    final (provider, service, _) = await createProvider();
    service.gate = Completer<void>();

    final first = provider.signIn(
      email: 'sam.lee@example.com',
      password: 'secret123',
    );
    expect(provider.isRunning(AuthAction.signIn), isTrue);
    expect(await provider.signInWithGoogle(), isFalse);
    expect(
      await provider.signIn(email: 'sam.lee@example.com', password: 'x'),
      isFalse,
    );

    service.gate!.complete();
    expect(await first, isTrue);
    expect(service.calls, ['signIn']);
    expect(provider.isBusy, isFalse);
    provider.dispose();
  });

  test(
    'registration keeps the display name set after account creation',
    () async {
      final (provider, _, prefs) = await createProvider();
      final ok = await provider.register(
        name: 'Lee Park',
        email: 'lee@example.com',
        password: 'secret123',
      );
      await pumpEventQueue();
      expect(ok, isTrue);
      expect(provider.user!.name, 'Lee Park');
      expect(
        AppUser.fromJson(prefs.getString(PrefKeys.userProfile))!.displayName,
        'Lee Park',
      );
      provider.dispose();
    },
  );

  test('cancelled Google sign-in is not an error', () async {
    final (provider, service, _) = await createProvider();
    service.googleUser = null;
    expect(await provider.signInWithGoogle(), isFalse);
    expect(provider.error, isNull);
    expect(provider.status, AuthStatus.unauthenticated);
    provider.dispose();
  });

  test('sign out clears the stored profile only', () async {
    final (provider, _, prefs) = await createProvider(signedIn: testUser);
    await prefs.setString(PrefKeys.currencyCode, 'USD');
    expect(prefs.getString(PrefKeys.userProfile), isNotNull);

    expect(await provider.signOut(), isTrue);
    await pumpEventQueue();
    expect(provider.status, AuthStatus.unauthenticated);
    expect(prefs.getString(PrefKeys.userProfile), isNull);
    expect(prefs.getString(PrefKeys.currencyCode), 'USD');
    provider.dispose();
  });
}
