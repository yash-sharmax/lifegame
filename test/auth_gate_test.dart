import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/config.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/main.dart';

/// Auth-gate session-restore tests.
///
/// Run with:
///   flutter test --dart-define APPWRITE_PROJECT_ID=test-project test/auth_gate_test.dart
///
/// AppConfig.isConfigured is false without the define, so these tests
/// skip in a plain `flutter test` run — the gate returns the login
/// screen immediately when the app is unconfigured.
void main() {
  // Skip when the suite runs without the define (see the file header).
  final skip = !AppConfig.isConfigured;

  group('auth gate session restore', () {
    testWidgets('shows a loader while the session is being checked', (
      tester,
    ) async {
      final controller = StreamController<AuthChange>();
      addTearDown(controller.close);
      await tester.pumpWidget(
        MaterialApp(home: AuthGate(authRepo: _GateAuthRepo(controller))),
      );
      await tester.pump();

      // The stored session is still being checked: a spinner, not the
      // login screen (showing login here is what made a reload look
      // like a logout).
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Welcome back'), findsNothing);

      // The check completes with no session → login screen.
      controller.add(const AuthChange(event: AuthEvent.signedOut));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
    }, skip: skip);

    testWidgets('surfaces a session-check failure with a retry', (
      tester,
    ) async {
      final controller = StreamController<AuthChange>();
      addTearDown(controller.close);
      AuthRepository.debugSetSessionErrorForTest(
        'No network connection. Check your internet and try again.',
      );
      addTearDown(() => AuthRepository.debugSetSessionErrorForTest(null));
      await tester.pumpWidget(
        MaterialApp(home: AuthGate(authRepo: _GateAuthRepo(controller))),
      );
      await tester.pump();

      controller.add(const AuthChange(event: AuthEvent.signedOut));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not check your saved session'),
          findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      // Retry re-checks the session; the fake reports a signed-in user
      // and the gate leaves the login screen.
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Could not check your saved session'),
        findsNothing,
      );
    }, skip: skip);

    testWidgets('a restored session goes straight to the app', (
      tester,
    ) async {
      final controller = StreamController<AuthChange>();
      addTearDown(controller.close);
      await tester.pumpWidget(
        MaterialApp(
          home: AuthGate(
            authRepo: _GateAuthRepo(controller),
            profileRepo: _GateProfileRepo(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.add(
        const AuthChange(
          event: AuthEvent.signedIn,
          user: AppAuthUser(uid: 'user-1', email: 'test@example.com'),
        ),
      );
      await tester.pumpAndSettle();

      // Main shell: the Home tab renders (the habit repo is real and
      // unconfigured here, so Home shows its empty state after the
      // failed load — the gate itself has done its job).
      expect(find.text("Today's habits"), findsOneWidget);
      expect(find.text('Welcome back'), findsNothing);
    }, skip: skip);
  });
}

/// Auth repo whose session stream the test drives by hand.
class _GateAuthRepo extends AuthRepository {
  _GateAuthRepo(this._controller);

  final StreamController<AuthChange> _controller;

  @override
  Stream<AuthChange> get onAuthStateChange => _controller.stream;

  @override
  Future<void> ensureSession() async {
    // The retry path: report a signed-in user.
    _controller.add(
      const AuthChange(
        event: AuthEvent.signedIn,
        user: AppAuthUser(uid: 'user-1', email: 'test@example.com'),
      ),
    );
  }
}

class _GateProfileRepo extends ProfileRepository {
  @override
  Future<Profile?> fetchMyProfile() async => const Profile(
    id: 'user-1',
    username: 'tester',
    displayName: 'Tester',
  );
}
