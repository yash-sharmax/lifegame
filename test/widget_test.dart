import 'package:appwrite/appwrite.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/logic/xp.dart';
import 'package:lifegame/main.dart';
import 'package:lifegame/screens/dashboard_screen.dart';
import 'package:lifegame/screens/home_screen.dart';
import 'package:lifegame/screens/profile_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // v2.8.0: Home/Dashboard load sub-tasks through the repository, whose
  // on-device fallback reads SharedPreferences. Without this mock the
  // platform channel never answers in tests and _load hangs forever
  // (the screen stays on its skeletons).
  SharedPreferences.setMockInitialValues({});
  testWidgets('unconfigured app shows the login screen', (tester) async {
    // No APPWRITE_* dart-define is passed in tests, so the app runs
    // unconfigured and the auth gate must show the login screen.
    await tester.pumpWidget(const LifeGameApp());
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Welcome back'), findsOneWidget);
    // "Continue with Google" was removed (18 Nov 2026): email only.
    expect(find.text('Continue with Google'), findsNothing);
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

  testWidgets(
    'v2.8.5: signup has a confirm password field, login does not',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const LifeGameApp());
      await tester.pumpAndSettle();

      // Login mode: single password field, no confirmation.
      expect(find.text('Confirm password'), findsNothing);

      await tester.tap(find.text('Create account'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm password'), findsOneWidget);

      // Mismatched confirmation blocks the submit with an error.
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Password'),
        'password123',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'different123',
      );
      await tester.tap(find.text('Create account'));
      await tester.pump();
      expect(find.text('Passwords do not match'), findsOneWidget);

      // Matching confirmation clears the error (submit then fails
      // elsewhere — the app is unconfigured in tests — but the
      // mismatch error itself must be gone).
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Confirm password'),
        'password123',
      );
      await tester.tap(find.text('Create account'));
      await tester.pump();
      expect(find.text('Passwords do not match'), findsNothing);
    },
  );

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

    expect(find.text('No habits yet'), findsOneWidget);
    expect(find.text('Add your first habit'), findsOneWidget);
  });

  testWidgets('home shows the XP pill, not the level bar (it lives on Profile)', (
    tester,
  ) async {
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

    // The level bar moved off Home to Profile (18 Nov 2026), but
    // Home now shows the XP pill next to the streak (tap it to open
    // the leaderboard) — so '42 XP' IS here, while the level bar's
    // own strings are not.
    expect(find.text('LEVEL 1'), findsNothing);
    expect(find.text('42 XP'), findsOneWidget);
    expect(find.text('42 / 100 XP to Level 2'), findsNothing);
  });

  testWidgets('profile shows the level bar with warrior rank', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileScreen(
            profileRepo: _FullProfileRepo(),
            habitRepo: _EmptyHabitRepo(),
            taskRepo: _EmptyTaskRepo(),
            socialRepo: _SocialCountsRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LEVEL 1'), findsOneWidget);
    expect(find.text('RECRUIT'), findsOneWidget);
    expect(find.text('42 XP'), findsOneWidget);
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
    // Tall viewport so the tab bar is on screen (like the other
    // Profile tests).
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
            taskRepo: _WeeklyTaskRepo(),
            socialRepo: _SocialCountsRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Weekly tasks live behind the "Weekly" tab now (18 Nov 2026):
    // tap it first, then the task is visible.
    await tester.tap(find.text('Weekly (1)'));
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
  });

  testWidgets('a rapid second tap is accepted and toggles back', (
    tester,
  ) async {
    // The toggle takes 100ms in this fake. A second tap 10ms later
    // must NOT be ignored any more (18 Nov 2026: the old guard that
    // blocked rapid taps is what made taps feel stuck): it flips the
    // tile back, queues its own server write, and the repo's serialised
    // queue runs them in order — so the tile ends undone and XP nets 0.
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
    // The first tap already painted the tile done.
    expect(find.text('Done • +2 XP'), findsOneWidget);
    await tester.tap(find.text('Read 10 pages'));
    await tester.pump(const Duration(milliseconds: 10));
    // The second tap paints it undone immediately — no waiting.
    expect(find.text('Tap to complete • +2 XP'), findsOneWidget);
    await tester.pumpAndSettle();

    expect(repo.toggleCalls, 2);
    expect(find.text('Tap to complete • +2 XP'), findsOneWidget);
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
    expect(find.text('Email support'), findsNothing);
    expect(find.text('Feedback'), findsOneWidget);
    expect(find.text('Send feedback'), findsOneWidget);
    expect(find.text('Delete account'), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
    // About is clean: plain version only, no build suffix, no tech mentions.
    expect(
      find.text('Version 2.11.3'),
      findsOneWidget,
    );
    expect(find.textContaining('+25'), findsNothing);
    expect(find.textContaining('Flutter'), findsNothing);
    expect(find.textContaining('Appwrite'), findsNothing);

    // Tapping About opens the dialog with the app description.
    // ensureVisible (not scrollUntilVisible): the Settings card grew
    // in v2.9.0 (theme + visibility + discoverable rows), so About
    // can sit above the current scroll position — scrollUntilVisible
    // only scrolls one way and left it off-screen.
    await tester.ensureVisible(find.text('About Life Game'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About Life Game'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Life Game turns your everyday habits into a game'),
      findsOneWidget,
    );
    expect(find.textContaining('Recruit to Legend'), findsOneWidget);
    expect(
      find.text('Version 2.11.3'),
      findsWidgets,
    );
    expect(find.textContaining('+25'), findsNothing);
    expect(find.textContaining('Flutter'), findsNothing);
    expect(find.textContaining('Appwrite'), findsNothing);
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

  testWidgets('dashboard shows the habit table, charts and XP ledger', (
    tester,
  ) async {
    // Tall viewport so the whole scrollable Dashboard (score card +
    // table + charts + ledger) is built: ListView only builds what
    // is on screen, and the ledger sits far below the fold.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            habitRepo: _LedgerHabitRepo(),
            taskRepo: _LedgerTaskRepo(),
            profileRepo: _TwoXpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The habit table (Daily single-day list by default, v2.8.1):
    // habits shown, view-only (ticking happens on Home).
    expect(find.text('Habit table'), findsOneWidget);
    // The habit appears in the table row, the score card and the
    // ledger.
    expect(find.text('Read 10 pages'), findsWidgets);
    expect(find.text('View only — tick from Home'), findsOneWidget);
    // Pie chart (done vs missed) and bar graph (per-habit, daily).
    expect(find.byType(PieChart), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    // The ledger: 1 completed habit log = 1 entry × 2 XP = 2 XP,
    // matching the profile's 2 XP exactly.
    expect(find.text('XP breakdown'), findsOneWidget);
    expect(find.text('Total 2 XP'), findsOneWidget);
    expect(find.text('1 entries × 2 XP = 2 XP'), findsOneWidget);
    expect(find.textContaining('will match after the next sync'), findsNothing);

    // Switch to Monthly: the multi-day Excel table renders instead.
    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(find.text('Habit'), findsOneWidget);
    expect(find.text('View only — tick from Home'), findsOneWidget);
  });

  test('chartDayLabel spaces monthly labels every 5 days', () {
    // Monthly axes: 1, 5, 10, 15, 20, 25, 30 + the last day — never
    // all 30 crammed together (18 Nov 2026: the old `interval: 5`
    // did nothing on bar charts).
    expect(chartDayLabel(1, 30), '1');
    expect(chartDayLabel(2, 30), isNull);
    expect(chartDayLabel(5, 30), '5');
    expect(chartDayLabel(7, 30), isNull);
    expect(chartDayLabel(30, 30), '30');
    expect(chartDayLabel(31, 31), '31');
    expect(chartDayLabel(29, 31), isNull);
    // Short axes (weekly / 7-day trend) label every day.
    expect(chartDayLabel(3, 7, sparse: false), '3');
    expect(chartDayLabel(17, 7, sparse: false), '17');
  });

  testWidgets('dashboard period switcher changes the table and charts', (
    tester,
  ) async {
    // Tall viewport so the whole scrollable Dashboard is built.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            habitRepo: _LedgerHabitRepo(),
            taskRepo: _LedgerTaskRepo(),
            profileRepo: _TwoXpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Daily is the default (v2.8.1: the Dashboard opens on Daily).
    expect(find.text('Daily'), findsOneWidget);
    expect(find.text('Weekly'), findsOneWidget);
    expect(find.text('Monthly'), findsOneWidget);
    expect(find.textContaining('Today,'), findsOneWidget);
    expect(find.text("Today's habits"), findsOneWidget);
    expect(find.text('Daily completions — last 7 days'), findsOneWidget);

    await tester.tap(find.text('Weekly'));
    await tester.pumpAndSettle();
    // 'Week of …' appears twice: the period label and the stats line.
    expect(find.textContaining('Week of'), findsWidgets);
    expect(find.text('Completions per day'), findsOneWidget);
    expect(find.text('Daily completions — this week'), findsOneWidget);

    await tester.tap(find.text('Daily'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Today,'), findsOneWidget);
    expect(find.text("Today's habits"), findsOneWidget);
    expect(find.text('Daily completions — last 7 days'), findsOneWidget);

    await tester.tap(find.text('Monthly'));
    await tester.pumpAndSettle();
    expect(find.text('Daily completions — this month'), findsOneWidget);
    // The multi-day Excel table still renders in Monthly (the
    // 'Habit' column header exists only there, not in the Daily
    // single-day list).
    expect(find.text('Habit'), findsOneWidget);
  });

  testWidgets('dashboard shows today\'s score with done and pending', (
    tester,
  ) async {
    // Tall viewport so the whole scrollable Dashboard is built.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            habitRepo: _ScoreHabitRepo(),
            taskRepo: _LedgerTaskRepo(),
            profileRepo: _TwoXpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 1 of 2 habits done today: the score is 50%, and both lists
    // are shown so the percent can be checked by hand. '50%' shows
    // twice now (v2.8.1: Daily is the default, so the pie chart
    // shows today's 50% too — in Monthly it showed the month's
    // percent instead).
    expect(find.text("Today's score"), findsOneWidget);
    expect(find.text('50%'), findsWidgets);
    expect(find.textContaining('Today: 1 of 2 done'), findsOneWidget);
    expect(find.text('Done (1)'), findsOneWidget);
    expect(find.text('Still to do (1)'), findsOneWidget);
    expect(find.text('Read 10 pages'), findsWidgets);
    expect(find.text('Morning workout'), findsWidgets);
    expect(find.textContaining('This week:'), findsOneWidget);
    // All three charts render with data.
    expect(find.byType(PieChart), findsOneWidget);
    expect(find.byType(BarChart), findsOneWidget);
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('dashboard score counts sub-tasks, not just habit ticks', (
    tester,
  ) async {
    // Tall viewport so the whole scrollable Dashboard is built.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            habitRepo: _ScoreSubtaskHabitRepo(),
            taskRepo: _LedgerTaskRepo(),
            profileRepo: _TwoXpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Exercise has 2 daily sub-tasks (1 done) and Read is a plain
    // habit, done today: 3 items, 2 done — the score is 67%, and the
    // lists name the sub-tasks so the percent can be checked by hand.
    // XP is per HABIT (1 done × 2 XP), never per sub-task.
    expect(find.text("Today's score"), findsOneWidget);
    expect(find.text('67%'), findsOneWidget);
    expect(find.textContaining('Today: 2 of 3 done'), findsOneWidget);
    expect(find.textContaining("Today's XP: 2 XP"), findsOneWidget);
    expect(find.text('Done (2)'), findsOneWidget);
    expect(find.text('Still to do (1)'), findsOneWidget);
    expect(find.text('Exercise — Warm up'), findsOneWidget);
    expect(find.text('Exercise — Run 2 km'), findsOneWidget);
    expect(find.text('Read'), findsWidgets);
  });

  testWidgets('home shows sub-task progress on the habit row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            habitRepo: _SubtaskProgressHabitRepo(),
            profileRepo: _XpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // One of two sub-tasks done: the row shows the progress, and the
    // habit itself is NOT done yet (its sub-tasks are not all done).
    expect(find.text('Exercise'), findsOneWidget);
    expect(find.text('1/2 sub-tasks done'), findsOneWidget);
    expect(find.text('Tap to complete • +2 XP'), findsOneWidget);
  });

  testWidgets('dashboard charts show empty states when nothing is done', (
    tester,
  ) async {
    // Tall viewport so the whole scrollable Dashboard is built.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            habitRepo: _NoLogsHabitRepo(),
            taskRepo: _LedgerTaskRepo(),
            profileRepo: _EmptyProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // No completions at all: intentional empty states, not a giant
    // blank card. The pie still renders (grey 0% ring).
    expect(find.text('No completions in this period yet'), findsOneWidget);
    expect(find.text('No trend yet'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
    expect(find.byType(LineChart), findsNothing);
    expect(find.byType(PieChart), findsOneWidget);
    expect(find.text('0%'), findsWidgets);
    expect(find.textContaining('Not started yet'), findsOneWidget);
  });

  testWidgets('dashboard daily list shows full names, a readable date and sub-task progress', (
    tester,
  ) async {
    // Phone-width viewport (390): the old 1-day table truncated
    // 'Verify Challenge Habit' to 'Verify Challen…' at this width
    // (v2.8.1, user's screenshot). The tall viewport builds the
    // whole scrollable Dashboard.
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DashboardScreen(
            habitRepo: _DailyListHabitRepo(),
            taskRepo: _LedgerTaskRepo(),
            profileRepo: _TwoXpProfileRepo(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Daily is the default period now.
    expect(find.text('Daily completions — last 7 days'), findsOneWidget);
    // The long habit name shows in FULL, on a row wide enough for
    // it: the old 128px column gave the title ~94px; the new list
    // gives it the full card width.
    final nameFinder = find.text('Verify Challenge Habit');
    expect(nameFinder, findsOneWidget);
    expect(tester.getSize(nameFinder).width, greaterThan(150));
    // The date header spells the weekday out in full (the old table
    // showed a tiny day number + one weekday letter).
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    expect(find.text(weekdays[DateTime.now().weekday - 1]), findsOneWidget);
    // Sub-task progress on the habit row.
    expect(find.text('1/2 sub-tasks done'), findsOneWidget);
    // Clear Done / Pending status per row: the habit with an undone
    // sub-task is Pending, the plain done habit is Done.
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Done'), findsWidgets);
  });

  testWidgets('followers list opens with profiles, empty state otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FollowListScreen(
          followers: true,
          socialRepo: _FollowListRepo(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Followers'), findsOneWidget);
    expect(find.text('Amit'), findsOneWidget);
    expect(find.text('@amit'), findsOneWidget);
    expect(find.text('Zara'), findsOneWidget);
    expect(find.text('LVL 1 • RECRUIT'), findsWidgets);

    // Tapping a row opens that person's profile.
    await tester.tap(find.text('Amit'));
    await tester.pumpAndSettle();
    expect(find.text('@amit'), findsWidgets);
    expect(find.text('Level 1 • Recruit'), findsWidgets);
  });

  testWidgets('following list shows the empty state when nobody is followed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FollowListScreen(
          followers: false,
          socialRepo: _EmptyFollowRepo(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Not following anyone yet'), findsOneWidget);
  });

  testWidgets('habit notes can be added in the edit dialog and persist', (
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

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Edit habit'), findsOneWidget);

    final notesField = find.byWidgetPredicate(
      (w) =>
          w is TextField && w.decoration?.labelText == 'Notes (optional)',
    );
    expect(notesField, findsOneWidget);
    await tester.enterText(notesField, '10 pages before bed');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(repo.habits.single.notes, '10 pages before bed');
    // The habit row shows the note preview with its icon.
    expect(find.text('10 pages before bed'), findsOneWidget);
    expect(find.byIcon(Icons.sticky_note_2_outlined), findsOneWidget);
  });

  testWidgets('phone bottom nav is compact with a clear active tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: MainShell()));
    await tester.pumpAndSettle();

    // The stock NavigationBar is gone: the custom compact bar shows
    // the selected tab's label inside its violet pill, the others as
    // icons only.
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);

    await tester.tap(find.byIcon(Icons.dashboard_outlined));
    await tester.pumpAndSettle();
    // 'Dashboard' now appears twice: the Dashboard screen's AppBar
    // title and the nav pill label. 'Home' is gone from the nav.
    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Home'), findsNothing);

    // v2.9.0: four tabs — the Reminders tab opens the chat screen,
    // and its 9-letter label fits the 58px bar on one line (no
    // overflow at 390px wide).
    await tester.tap(find.byIcon(Icons.chat_bubble_outline));
    await tester.pumpAndSettle();
    expect(find.text('Reminders'), findsWidgets);
    expect(find.text('Dashboard'), findsNothing);
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
  Future<void> updateHabit(
    Habit habit, {
    String? title,
    int? color,
    String? notes,
  }) async {
    final index = habits.indexWhere((h) => h.id == habit.id);
    if (index >= 0) {
      habits[index] = Habit(
        id: habit.id,
        userId: habit.userId,
        title: title ?? habit.title,
        color: color ?? habit.color,
        notes: notes ?? habit.notes,
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

/// One habit, done today: feeds the Dashboard table + ledger test.
class _LedgerHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];

  @override
  Future<List<HabitLog>> listLogsInRange(String start, String end) async => [
    HabitLog(
      id: 'h1_${dateKey(DateTime.now())}',
      habitId: 'h1',
      userId: 'test-user',
      logDate: dateKey(DateTime.now()),
    ),
  ];

  @override
  Future<List<HabitLog>> listAllCompletedLogs() async => [
    HabitLog(
      id: 'h1_${dateKey(DateTime.now())}',
      habitId: 'h1',
      userId: 'test-user',
      logDate: dateKey(DateTime.now()),
    ),
  ];
}

/// Two habits, one done today: feeds the daily-score test.
class _ScoreHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
    const Habit(id: 'h2', userId: 'test-user', title: 'Morning workout'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];

  @override
  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    final today = dateKey(DateTime.now());
    if (today.compareTo(start) >= 0 && today.compareTo(end) <= 0) {
      return [
        HabitLog(
          id: 'h1_$today',
          habitId: 'h1',
          userId: 'test-user',
          logDate: today,
        ),
      ];
    }
    return [];
  }

  @override
  Future<List<HabitLog>> listAllCompletedLogs() async {
    final today = dateKey(DateTime.now());
    return [
      HabitLog(
        id: 'h1_$today',
        habitId: 'h1',
        userId: 'test-user',
        logDate: today,
      ),
    ];
  }
}

/// Two habits for the sub-task score test (v2.8.0): Exercise has two
/// daily sub-tasks, one done today; Read is a plain habit, done
/// today. Score items: 3, done: 2 (67%); XP: 1 habit × 2 XP.
class _ScoreSubtaskHabitRepo extends HabitRepository {
  List<HabitSubtask> get _subs {
    final today = dateKey(DateTime.now());
    return [
      HabitSubtask(
        id: 's1',
        habitId: 'h1',
        title: 'Warm up',
        kind: HabitSubtask.kindDaily,
        date: today,
      ),
      HabitSubtask(
        id: 's2',
        habitId: 'h1',
        title: 'Run 2 km',
        kind: HabitSubtask.kindDaily,
        date: today,
      ),
    ];
  }

  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Exercise'),
    const Habit(id: 'h2', userId: 'test-user', title: 'Read'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async {
    final today = dateKey(DateTime.now());
    if (date != today) return [];
    return [
      HabitLog(
        id: 'h2_$today',
        habitId: 'h2',
        userId: 'test-user',
        logDate: today,
      ),
    ];
  }

  @override
  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    final today = dateKey(DateTime.now());
    if (today.compareTo(start) >= 0 && today.compareTo(end) <= 0) {
      return [
        HabitLog(
          id: 'h2_$today',
          habitId: 'h2',
          userId: 'test-user',
          logDate: today,
        ),
      ];
    }
    return [];
  }

  @override
  Future<List<HabitLog>> listAllCompletedLogs() async {
    final today = dateKey(DateTime.now());
    return [
      HabitLog(
        id: 'h2_$today',
        habitId: 'h2',
        userId: 'test-user',
        logDate: today,
      ),
    ];
  }

  @override
  Future<Map<String, List<HabitSubtask>>> listSubtasksByHabit(
    Iterable<String> habitIds,
  ) async => {'h1': _subs};

  @override
  Future<Set<String>> completedSubtaskIdsForDate(String date) async {
    if (date != dateKey(DateTime.now())) return {};
    return {'s1'};
  }

  @override
  Future<Map<String, Set<String>>> completedSubtaskIdsInRange(
    String start,
    String end,
  ) async {
    final today = dateKey(DateTime.now());
    if (today.compareTo(start) >= 0 && today.compareTo(end) <= 0) {
      return {today: {'s1'}};
    }
    return {};
  }
}

/// Long habit name + sub-tasks: feeds the Daily-list layout test
/// (v2.8.1). 'Verify Challenge Habit' must show in FULL — the old
/// 1-day table truncated it to 'Verify Challen…' at phone width.
class _DailyListHabitRepo extends HabitRepository {
  List<HabitSubtask> get _subs {
    final today = dateKey(DateTime.now());
    return [
      HabitSubtask(
        id: 's1',
        habitId: 'h1',
        title: 'Warm up',
        kind: HabitSubtask.kindDaily,
        date: today,
      ),
      HabitSubtask(
        id: 's2',
        habitId: 'h1',
        title: 'Run 2 km',
        kind: HabitSubtask.kindDaily,
        date: today,
      ),
    ];
  }

  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(
      id: 'h1',
      userId: 'test-user',
      title: 'Verify Challenge Habit',
    ),
    const Habit(id: 'h2', userId: 'test-user', title: 'Read'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];

  @override
  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    final today = dateKey(DateTime.now());
    if (today.compareTo(start) >= 0 && today.compareTo(end) <= 0) {
      return [
        HabitLog(
          id: 'h2_$today',
          habitId: 'h2',
          userId: 'test-user',
          logDate: today,
        ),
      ];
    }
    return [];
  }

  @override
  Future<List<HabitLog>> listAllCompletedLogs() async {
    final today = dateKey(DateTime.now());
    return [
      HabitLog(
        id: 'h2_$today',
        habitId: 'h2',
        userId: 'test-user',
        logDate: today,
      ),
    ];
  }

  @override
  Future<Map<String, List<HabitSubtask>>> listSubtasksByHabit(
    Iterable<String> habitIds,
  ) async => {'h1': _subs};

  @override
  Future<Set<String>> completedSubtaskIdsForDate(String date) async {
    if (date != dateKey(DateTime.now())) return {};
    return {'s1'};
  }

  @override
  Future<Map<String, Set<String>>> completedSubtaskIdsInRange(
    String start,
    String end,
  ) async {
    final today = dateKey(DateTime.now());
    if (today.compareTo(start) >= 0 && today.compareTo(end) <= 0) {
      return {today: {'s1'}};
    }
    return {};
  }
}

/// One habit with two daily sub-tasks, one done today: the Home row
/// shows "1/2 sub-tasks done" and the habit is not done yet.
class _SubtaskProgressHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Exercise'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];

  @override
  Future<Map<String, List<HabitSubtask>>> listSubtasksByHabit(
    Iterable<String> habitIds,
  ) async {
    final today = dateKey(DateTime.now());
    return {
      'h1': [
        HabitSubtask(
          id: 's1',
          habitId: 'h1',
          title: 'Warm up',
          kind: HabitSubtask.kindDaily,
          date: today,
        ),
        HabitSubtask(
          id: 's2',
          habitId: 'h1',
          title: 'Run 2 km',
          kind: HabitSubtask.kindDaily,
          date: today,
        ),
      ],
    };
  }

  @override
  Future<Set<String>> completedSubtaskIdsForDate(String date) async {
    if (date != dateKey(DateTime.now())) return {};
    return {'s1'};
  }
}

/// Habits but no completions at all: charts show empty states.
class _NoLogsHabitRepo extends HabitRepository {
  @override
  Future<List<Habit>> listMyHabits() async => [
    const Habit(id: 'h1', userId: 'test-user', title: 'Read 10 pages'),
  ];

  @override
  Future<List<HabitLog>> listLogsForDate(String date) async => [];

  @override
  Future<List<HabitLog>> listLogsInRange(String start, String end) async =>
      [];

  @override
  Future<List<HabitLog>> listAllCompletedLogs() async => [];
}

/// No done tasks: the Dashboard ledger counts only the habit log.
class _LedgerTaskRepo extends TaskRepository {
  @override
  Future<List<WeeklyTask>> listAllDoneWeeklyTasks() async => [];

  @override
  Future<List<MonthlyTask>> listAllDoneMonthlyTasks() async => [];
}

/// Profile with exactly 2 XP, so the ledger (1 entry × 2 XP) matches.
class _TwoXpProfileRepo extends ProfileRepository {
  @override
  Future<Profile?> fetchMyProfile() async => const Profile(
    id: 'test-user',
    username: 'tester',
    displayName: 'Tester',
    xp: 2,
    currentStreak: 1,
    longestStreak: 1,
  );
}

/// Two followers, for the Followers list test.
class _FollowListRepo extends SocialRepository {
  @override
  Future<List<Profile>> followProfiles({
    required bool followers,
    String? userId,
  }) async => [
    const Profile(id: 'u2', username: 'amit', displayName: 'Amit'),
    const Profile(id: 'u3', username: 'zara', displayName: 'Zara'),
  ];

  @override
  Future<bool> isFollowing(String followingId) async => false;

  @override
  Future<int> followersCount(String userId) async => 2;

  @override
  Future<int> followingCount(String userId) async => 0;
}

/// Nobody followed: the Following list shows its empty state.
class _EmptyFollowRepo extends SocialRepository {
  @override
  Future<List<Profile>> followProfiles({
    required bool followers,
    String? userId,
  }) async => [];
}
