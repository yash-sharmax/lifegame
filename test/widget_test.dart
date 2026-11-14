import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/main.dart';
import 'package:lifegame/screens/home_screen.dart';

void main() {
  testWidgets('unconfigured app shows the login screen', (tester) async {
    // No APPWRITE_* dart-define is passed in tests, so the app runs
    // unconfigured and the auth gate must show the login screen.
    await tester.pumpWidget(const LifeGameApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Log in'), findsWidgets);
  });

  testWidgets('auth screen switches to signup', (tester) async {
    // Tall viewport so the whole auth card is on screen.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const LifeGameApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Create your account'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
  });

  testWidgets('home shows empty state when there are no habits',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            habitRepo: _EmptyHabitRepo(),
            profileRepo: _EmptyProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Your journey starts here'), findsOneWidget);
    expect(find.text('Add your first habit'), findsOneWidget);
  });
}

/// Fake repositories that return empty data without touching Appwrite.
class _EmptyHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];
}

class _EmptyProfileRepo extends ProfileRepository {
  @override
  Future<Profile?> fetchMyProfile() async => const Profile(
    id: 'test-user',
    username: 'tester',
    displayName: 'Tester',
  );
}
