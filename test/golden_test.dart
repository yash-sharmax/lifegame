import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/logic/xp.dart';
import 'package:lifegame/screens/dashboard_screen.dart';
import 'package:lifegame/screens/home_screen.dart';
import 'package:lifegame/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Golden screenshots of Home + Dashboard at phone and desktop sizes,
/// using in-memory fake repositories (no Appwrite, no login).
/// Regenerate with: flutter test --update-goldens test/golden_test.dart
void main() {
  // v2.8.0: Home/Dashboard load sub-tasks through the repository, whose
  // on-device fallback reads SharedPreferences. Without this mock the
  // platform channel never answers in tests and _load hangs forever
  // (the screen stays on its skeletons).
  SharedPreferences.setMockInitialValues({});
  Future<void> setViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget app(Widget child) => MaterialApp(
    theme: AppTheme.dark,
    home: Scaffold(body: child),
  );

  group('home', () {
    testWidgets('mobile 390x844', (tester) async {
      await setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        app(
          HomeScreen(
            habitRepo: _GoldenHabitRepo(),
            profileRepo: _GoldenProfileRepo(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(HomeScreen),
        matchesGoldenFile('goldens/home_mobile.png'),
      );
    });

    testWidgets('desktop 1440x900', (tester) async {
      await setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        app(
          HomeScreen(
            habitRepo: _GoldenHabitRepo(),
            profileRepo: _GoldenProfileRepo(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(HomeScreen),
        matchesGoldenFile('goldens/home_desktop.png'),
      );
    });
  });

  group('dashboard', () {
    testWidgets('mobile 390x844', (tester) async {
      await setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        app(
          DashboardScreen(
            habitRepo: _GoldenHabitRepo(),
            taskRepo: _GoldenTaskRepo(),
            profileRepo: _GoldenProfileRepo(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DashboardScreen),
        matchesGoldenFile('goldens/dashboard_mobile.png'),
      );
    });

    testWidgets('desktop 1440x900', (tester) async {
      await setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        app(
          DashboardScreen(
            habitRepo: _GoldenHabitRepo(),
            taskRepo: _GoldenTaskRepo(),
            profileRepo: _GoldenProfileRepo(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(DashboardScreen),
        matchesGoldenFile('goldens/dashboard_desktop.png'),
      );
    });
  });
}

class _GoldenProfileRepo extends ProfileRepository {
  // XP 30 matches the ledger: 15 completed habit logs × 2 XP
  // (10 days of h1 + 5 days of h2), so no mismatch note shows.
  @override
  Future<Profile?> fetchMyProfile() async => const Profile(
    id: 'test-user',
    username: 'tester',
    displayName: 'Tester',
    xp: 30,
    currentStreak: 3,
    longestStreak: 5,
  );
}

/// No done tasks in the golden data: the ledger counts habits only.
class _GoldenTaskRepo extends TaskRepository {
  @override
  Future<List<WeeklyTask>> listAllDoneWeeklyTasks() async => [];

  @override
  Future<List<MonthlyTask>> listAllDoneMonthlyTasks() async => [];
}

/// Three habits; two done today; logs for the last 10 days so the
/// dashboard charts have data.
class _GoldenHabitRepo extends HabitRepository {
  static const _habits = [
    Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
    Habit(id: 'h2', userId: 'test-user', title: 'Morning workout'),
    Habit(id: 'h3', userId: 'test-user', title: 'Meditate 10 minutes'),
  ];

  @override
  Future<List<Habit>> listMyHabits() async => _habits;

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [
    HabitLog(id: 'h1_$date', habitId: 'h1', userId: 'test-user', logDate: date),
    HabitLog(id: 'h2_$date', habitId: 'h2', userId: 'test-user', logDate: date),
  ];

  @override
  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    return _logs().where((log) {
      final key = log.logDate;
      return key.compareTo(start) >= 0 && key.compareTo(end) <= 0;
    }).toList();
  }

  @override
  Future<List<HabitLog>> listAllCompletedLogs() async => _logs();

  /// 10 days of h1 + 5 days of h2 = 15 completed logs = 30 XP, which
  /// is what the golden profile reports (see _GoldenProfileRepo).
  List<HabitLog> _logs() {
    final logs = <HabitLog>[];
    final now = DateTime.now();
    for (var i = 0; i < 10; i++) {
      final day = now.subtract(Duration(days: i));
      final key = dateKey(day);
      logs.add(
        HabitLog(
          id: 'h1_$key',
          habitId: 'h1',
          userId: 'test-user',
          logDate: key,
        ),
      );
      if (i.isEven) {
        logs.add(
          HabitLog(
            id: 'h2_$key',
            habitId: 'h2',
            userId: 'test-user',
            logDate: key,
          ),
        );
      }
    }
    return logs;
  }
}
