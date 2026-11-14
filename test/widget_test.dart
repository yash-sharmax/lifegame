import 'package:appwrite/appwrite.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/main.dart';
import 'package:lifegame/screens/home_screen.dart';
import 'package:lifegame/screens/profile_screen.dart';

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

  testWidgets('home shows empty state when there are no habits', (
    tester,
  ) async {
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

  testWidgets('home shows XP at the top', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            habitRepo: _EmptyHabitRepo(),
            profileRepo: _XpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // XP is pinned at the top (XpBar), not buried in Profile.
    expect(find.text('42 XP'), findsOneWidget);
    expect(find.text('LEVEL 1'), findsOneWidget);
    // "X / 100 XP to Level N": how much of this level is done, out of
    // how much (user feedback, 14 Nov 2026).
    expect(find.text('42 / 100 XP to Level 2'), findsOneWidget);
  });

  testWidgets('done habit stays visible without a strikethrough', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            habitRepo: _DoneHabitRepo(),
            profileRepo: _XpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Read 10 pages'), findsOneWidget);
    expect(find.text('Done • +2 XP'), findsOneWidget);
    final title = tester.widget<Text>(find.text('Read 10 pages'));
    expect(title.style?.decoration, isNot(TextDecoration.lineThrough));
  });

  testWidgets('done weekly task stays visible without a strikethrough', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepo: _FullProfileRepo(),
            habitRepo: _EmptyHabitRepo(),
            taskRepo: _WeeklyTaskRepo(),
            socialRepo: _SocialCountsRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Task sections sit below the fold: scroll until visible.
    await tester.scrollUntilVisible(find.text('Buy groceries'), 300);
    await tester.pumpAndSettle();

    expect(find.text('Buy groceries'), findsOneWidget);
    final title = tester.widget<Text>(find.text('Buy groceries'));
    expect(title.style?.decoration, isNot(TextDecoration.lineThrough));
    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(checkbox.value, isTrue);
  });

  testWidgets('desktop shell uses a navigation rail', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Life Game'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('home renders wide desktop layout without errors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            habitRepo: _DoneHabitRepo(),
            profileRepo: _XpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Read 10 pages'), findsOneWidget);
    expect(find.text('42 XP'), findsOneWidget);
  });

  testWidgets('a rapid second tap does not start a second toggle', (
    tester,
  ) async {
    // The toggle takes 100ms in this fake; a second tap 10ms later
    // must be ignored while the first toggle is still saving, so two
    // toggles can never run against the same stale state.
    final repo = _CountingHabitRepo();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(habitRepo: repo, profileRepo: _XpProfileRepo()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Read 10 pages'));
    await tester.pump(const Duration(milliseconds: 10));
    await tester.tap(find.text('Read 10 pages'));
    await tester.pumpAndSettle();

    expect(repo.toggleCalls, 1);
  });

  testWidgets(
    'tapping a habit shows it done immediately, before the write finishes',
    (tester) async {
      // The fake write takes 100ms; 10ms after the tap — long before the
      // write completes — the tile and its XP must already show done.
      final repo = _CountingHabitRepo();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeScreen(habitRepo: repo, profileRepo: _XpProfileRepo()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Tap to complete • +2 XP'), findsOneWidget);
      await tester.tap(find.text('Read 10 pages'));
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('Done • +2 XP'), findsOneWidget);
      expect(repo.toggleCalls, 0);

      await tester.pumpAndSettle();
      // After the write lands the tile stays done (the fake remembers it).
      expect(find.text('Done • +2 XP'), findsOneWidget);
      expect(repo.toggleCalls, 1);
    },
  );

  testWidgets('a failed toggle rolls the optimistic state back', (
    tester,
  ) async {
    final repo = _FailingHabitRepo();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(habitRepo: repo, profileRepo: _XpProfileRepo()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Read 10 pages'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.text('Done • +2 XP'), findsOneWidget);

    // The write fails at 100ms: the tile rolls back and an error shows.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Tap to complete • +2 XP'), findsOneWidget);
    expect(find.textContaining('Toggle failed'), findsOneWidget);
  });

  testWidgets('home tile offers edit/delete and deleting removes it', (
    tester,
  ) async {
    final repo = _MutableHabitRepo();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(habitRepo: repo, profileRepo: _XpProfileRepo()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Read 10 pages'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Edit habit'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Read 10 pages'), findsNothing);
    expect(repo.deletedIds, ['h1']);
  });

  testWidgets('profile habit list refreshes when habits change elsewhere', (
    tester,
  ) async {
    // Tall viewport so both habit rows are on screen (the list is a
    // lazy ListView — a row below the fold is never built).
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Profile loads once (IndexedStack keeps it alive); a habit added
    // on Home must appear here without restarting the app.
    final habits = _MutableHabitRepo();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepo: _FullProfileRepo(),
            habitRepo: habits,
            taskRepo: _EmptyTaskRepo(),
            socialRepo: _SocialCountsRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Read 10 pages'), findsOneWidget);
    expect(find.text('Morning workout'), findsNothing);

    habits.habits.add(
      const Habit(id: 'h2', userId: 'test-user', title: 'Morning workout'),
    );
    HabitRepository.notifyChangedForTest();
    await tester.pumpAndSettle();

    expect(find.text('Morning workout'), findsOneWidget);
  });

  testWidgets('profile shows support, feedback and delete-account sections', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepo: _FullProfileRepo(),
            habitRepo: _EmptyHabitRepo(),
            taskRepo: _EmptyTaskRepo(),
            socialRepo: _SocialCountsRepo(),
            feedbackRepo: _FakeFeedbackRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Delete account'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Support'), findsOneWidget);
    expect(find.text('How Life Game works'), findsOneWidget);
    expect(find.text('Email support'), findsOneWidget);
    expect(find.text('Feedback'), findsOneWidget);
    expect(find.text('Send feedback'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Version 2.2.0+7 • Flutter • Appwrite'), findsOneWidget);
  });

  testWidgets('feedback form sends a message and shows a thank-you', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final feedback = _FakeFeedbackRepo();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepo: _FullProfileRepo(),
            habitRepo: _EmptyHabitRepo(),
            taskRepo: _EmptyTaskRepo(),
            socialRepo: _SocialCountsRepo(),
            feedbackRepo: feedback,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Send feedback'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), 'Love the app!');
    await tester.tap(find.text('Send feedback'));
    await tester.pumpAndSettle();

    expect(feedback.sent, ['Love the app!']);
    expect(find.text('Thank you — your feedback was sent.'), findsOneWidget);
    expect(find.text('Love the app!'), findsWidgets);
  });

  testWidgets('delete-account flow asks for confirmation before deleting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final auth = _FakeAuthRepo();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepo: _FullProfileRepo(),
            habitRepo: _EmptyHabitRepo(),
            taskRepo: _EmptyTaskRepo(),
            socialRepo: _SocialCountsRepo(),
            feedbackRepo: _FakeFeedbackRepo(),
            authRepo: auth,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Delete account'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    expect(find.text('Delete your account?'), findsOneWidget);
    // The delete button starts disabled until the checkbox is ticked.
    final deleteButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Delete my account'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(deleteButton.onPressed, isNull);
    expect(auth.deleteCalled, isFalse);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete my account'));
    // No pumpAndSettle here: after a successful delete the blocking
    // overlay shows a spinner that never settles (in the real app the
    // auth gate signs the user out and unmounts this screen).
    await tester.pump(const Duration(milliseconds: 100));

    expect(auth.deleteCalled, isTrue);
  });
}

/// Fake repositories that return empty data without touching Appwrite.

/// Fake repositories that return empty data without touching Appwrite.
class _EmptyHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];
}

class _EmptyProfileRepo extends ProfileRepository {
  @override
  Future<Profile?> fetchMyProfile() async =>
      const Profile(id: 'test-user', username: 'tester', displayName: 'Tester');
}

/// Profile with 42 XP (level 1, 58 XP to level 2).
class _XpProfileRepo extends ProfileRepository {
  @override
  Future<Profile?> fetchMyProfile() async => const Profile(
    id: 'test-user',
    username: 'tester',
    displayName: 'Tester',
    xp: 42,
    currentStreak: 3,
    longestStreak: 5,
  );
}

/// One habit, already done today.
class _DoneHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [
    HabitLog(id: 'h1_$date', habitId: 'h1', userId: 'test-user', logDate: date),
  ];
}

class _FullProfileRepo extends ProfileRepository {
  @override
  Future<Profile?> fetchMyProfile() async => const Profile(
    id: 'test-user',
    username: 'tester',
    displayName: 'Tester',
    xp: 42,
    currentStreak: 3,
    longestStreak: 5,
  );

  @override
  Future<int> fetchGlobalRank() async => 1;
}

class _WeeklyTaskRepo extends TaskRepository {
  @override
  Future<List<WeeklyTask>> listWeeklyTasks(String weekStart) async => [
    WeeklyTask(
      id: 'w1',
      userId: 'test-user',
      title: 'Buy groceries',
      weekStart: weekStart,
      done: true,
    ),
  ];

  @override
  Future<List<MonthlyTask>> listMonthlyTasks(String month) async => [];
}

class _SocialCountsRepo extends SocialRepository {
  @override
  Future<int> followersCount(String userId) async => 0;

  @override
  Future<int> followingCount(String userId) async => 0;
}

/// Counts toggleHabit calls; the toggle takes 100ms so a second tap
/// during the first toggle overlaps it. Remembers the done state so a
/// reload after the toggle still shows the tile as done.
class _CountingHabitRepo extends HabitRepository {
  int toggleCalls = 0;
  bool done = false;

  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => done
      ? [
          HabitLog(
            id: 'h1_$date',
            habitId: 'h1',
            userId: 'test-user',
            logDate: date,
          ),
        ]
      : [];

  @override
  Future<ToggleResult> toggleHabit({
    required Habit habit,
    required String date,
    required bool completed,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    toggleCalls++;
    done = completed;
    return const ToggleResult(xpDelta: 2, allDone: false);
  }
}

/// A habit repo whose toggle always fails, so the optimistic UI must
/// roll the tile back to its previous state.
class _FailingHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];

  @override
  Future<ToggleResult> toggleHabit({
    required Habit habit,
    required String date,
    required bool completed,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    throw StateError('Toggle failed (test).');
  }
}

/// A client that never talks to anything, for fakes that need a
/// TablesDB instance without a real Appwrite client behind it.
class _StubClient implements Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records feedback submissions in memory instead of Appwrite.
class _FakeFeedbackRepo extends FeedbackRepository {
  _FakeFeedbackRepo() : super(db: TablesDB(_StubClient()));

  final sent = <String>[];

  @override
  Future<FeedbackEntry> submitFeedback(String text) async {
    sent.add(text);
    return FeedbackEntry(
      id: 'f${sent.length}',
      userId: 'test-user',
      text: text,
      createdAt: DateTime(2026, 11, 14),
    );
  }

  @override
  Future<List<FeedbackEntry>> listMyFeedback({int limit = 10}) async => [
    for (var i = sent.length - 1; i >= 0; i--)
      FeedbackEntry(
        id: 'f${i + 1}',
        userId: 'test-user',
        text: sent[i],
        createdAt: DateTime(2026, 11, 14),
      ),
  ];
}

/// Records account-deletion calls instead of talking to Appwrite.
class _FakeAuthRepo extends AuthRepository {
  bool deleteCalled = false;

  @override
  Future<void> deleteAccount() async {
    deleteCalled = true;
  }
}

/// Habits held in a mutable list so tests can add/remove them and
/// trigger a refresh notification, like another tab would.
class _MutableHabitRepo extends HabitRepository {
  final habits = <Habit>[
    const Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
  ];
  final deletedIds = <String>[];

  @override
  Future<List<Habit>> listMyHabits() async => List.of(habits);

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];

  @override
  Future<void> updateHabit(Habit habit, {String? title, int? color}) async {
    final index = habits.indexWhere((h) => h.id == habit.id);
    if (index >= 0 && title != null) {
      habits[index] = Habit(
        id: habit.id,
        userId: habit.userId,
        title: title,
        color: habit.color,
      );
    }
  }

  @override
  Future<void> deleteHabit(String habitId) async {
    deletedIds.add(habitId);
    habits.removeWhere((h) => h.id == habitId);
  }
}

class _EmptyTaskRepo extends TaskRepository {
  @override
  Future<List<WeeklyTask>> listWeeklyTasks(String weekStart) async => [];

  @override
  Future<List<MonthlyTask>> listMonthlyTasks(String month) async => [];
}
