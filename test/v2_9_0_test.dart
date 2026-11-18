// v2.9.0 tests (18 Nov 2026): follow requests, friend circle,
// visibility gating, discoverable filtering, offline behaviour,
// theme persistence and the colour-picker single-selection fix.
import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/logic/xp.dart';
import 'package:lifegame/screens/profile_screen.dart';
import 'package:lifegame/theme.dart';
import 'package:lifegame/widgets/habit_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [Client] that never talks to anything (same trick as
/// repository_test.dart).
class _StubClient implements Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Compact in-memory [TablesDB] for the v2.9.0 tests. Supports the
/// query operators the repositories use (equal, startsWith,
/// greaterThan / greaterThanEqual / lessThanEqual, orderAsc /
/// orderDesc, limit, offset). Flip [failAll] to simulate going
/// offline: every call then throws a network error (Appwrite code 0),
/// so the repositories must serve the local cache instead.
/// Deliberately delay-free: the methods complete on microtasks, so
/// they work in widget tests too (testWidgets freezes real time —
/// a Future.delayed in the fake would hang the test body forever).
class _V29FakeDB extends TablesDB {
  _V29FakeDB() : super(_StubClient());

  final Map<String, Map<String, _Row>> _tables = {};
  int _seq = 0;

  /// When true, every call fails as a network error.
  bool failAll = false;

  AppwriteException get _networkError =>
      AppwriteException('Failed host lookup', 0, '');

  Map<String, _Row> _rowsOf(String tableId) =>
      _tables.putIfAbsent(tableId, () => {});

  String _now() {
    final stamp = DateTime.utc(2026, 1, 1).add(Duration(milliseconds: _seq++));
    return stamp.toIso8601String();
  }

  models.Row _toRow(String tableId, _Row row) => models.Row(
    $id: row.id,
    $sequence: '0',
    $tableId: tableId,
    $databaseId: 'lifegame',
    $createdAt: row.createdAt,
    $updatedAt: row.createdAt,
    $permissions: const [],
    data: Map<String, dynamic>.from(row.data),
  );

  @override
  Future<models.Row> createRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    required Map data,
    List<String>? permissions,
    String? transactionId,
  }) async {
    if (failAll) throw _networkError;
    final rows = _rowsOf(tableId);
    if (rows.containsKey(rowId)) {
      throw AppwriteException(
        'Row already exists',
        409,
        'document_already_exists',
      );
    }
    final row = _Row(
      id: rowId,
      createdAt: _now(),
      data: Map<String, dynamic>.from(data),
    );
    rows[rowId] = row;
    return _toRow(tableId, row);
  }

  @override
  Future<models.Row> getRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    List<String>? queries,
    String? transactionId,
  }) async {
    if (failAll) throw _networkError;
    final row = _rowsOf(tableId)[rowId];
    if (row == null) {
      throw AppwriteException('Row not found', 404, 'document_not_found');
    }
    return _toRow(tableId, row);
  }

  @override
  Future<models.Row> updateRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    Map? data,
    List<String>? permissions,
    String? transactionId,
  }) async {
    if (failAll) throw _networkError;
    final row = _rowsOf(tableId)[rowId];
    if (row == null) {
      throw AppwriteException('Row not found', 404, 'document_not_found');
    }
    if (data != null) row.data.addAll(Map<String, dynamic>.from(data));
    return _toRow(tableId, row);
  }

  @override
  Future<dynamic> deleteRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    String? transactionId,
  }) async {
    if (failAll) throw _networkError;
    final removed = _rowsOf(tableId).remove(rowId);
    if (removed == null) {
      throw AppwriteException('Row not found', 404, 'document_not_found');
    }
    return null;
  }

  @override
  Future<models.RowList> listRows({
    required String databaseId,
    required String tableId,
    List<String>? queries,
    String? transactionId,
    bool? total,
    int? ttl,
  }) async {
    if (failAll) throw _networkError;
    var rows = _rowsOf(tableId).values.toList();
    var limit = 25;
    var offset = 0;
    for (final q in queries ?? const <String>[]) {
      final parsed = jsonDecode(q) as Map<String, dynamic>;
      final method = parsed['method'] as String;
      final attribute = parsed['attribute'] as String?;
      final values = (parsed['values'] as List?) ?? const [];
      switch (method) {
        case 'equal':
          rows = rows
              .where((r) => values.contains(_valueOf(r, attribute!)))
              .toList();
        case 'greaterThan':
          rows = rows
              .where(
                (r) => _compare(_valueOf(r, attribute!), values.first) > 0,
              )
              .toList();
        case 'greaterThanEqual':
          rows = rows
              .where(
                (r) => _compare(_valueOf(r, attribute!), values.first) >= 0,
              )
              .toList();
        case 'lessThanEqual':
          rows = rows
              .where(
                (r) => _compare(_valueOf(r, attribute!), values.first) <= 0,
              )
              .toList();
        case 'startsWith':
          rows = rows
              .where(
                (r) => (_valueOf(r, attribute!) as String).startsWith(
                  values.first as String,
                ),
              )
              .toList();
        case 'orderAsc':
          final attrAsc = attribute!;
          rows.sort(
            (a, b) => _compare(_valueOf(a, attrAsc), _valueOf(b, attrAsc)),
          );
        case 'orderDesc':
          final attrDesc = attribute!;
          rows.sort(
            (a, b) => _compare(_valueOf(b, attrDesc), _valueOf(a, attrDesc)),
          );
        case 'limit':
          limit = values.first as int;
        case 'offset':
          offset = values.first as int;
      }
    }
    final filteredTotal = rows.length;
    final page = rows.skip(offset).take(limit).toList();
    return models.RowList(
      total: filteredTotal,
      rows: page.map((r) => _toRow(tableId, r)).toList(),
    );
  }

  dynamic _valueOf(_Row row, String attribute) {
    if (attribute == r'$createdAt') return row.createdAt;
    if (attribute == r'$id') return row.id;
    return row.data[attribute];
  }

  int _compare(dynamic a, dynamic b) {
    if (a is Comparable && b is Comparable) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }
}

class _Row {
  _Row({required this.id, required this.createdAt, required this.data});

  final String id;
  final String createdAt;
  final Map<String, dynamic> data;
}

void main() {
  SharedPreferences.setMockInitialValues({});

  late _V29FakeDB db;
  late ProfileRepository profiles;
  late SocialRepository social;
  late HabitRepository habits;

  void asUser(String uid) {
    AuthRepository.debugSetCachedUserForTest(
      AppAuthUser(uid: uid, email: '$uid@example.com'),
    );
  }

  Future<void> seedUser(
    String id,
    String username,
    String name, {
    int xp = 0,
    String visibility = 'public',
    bool? discoverable,
  }) async {
    final userData = <String, dynamic>{
      'username': username,
      'displayName': name,
      'bio': '',
      'xp': xp,
      'currentStreak': 0,
      'longestStreak': 0,
      'lastActiveDate': null,
      'visibility': visibility,
    };
    if (discoverable != null) userData['discoverable'] = discoverable;
    await db.createRow(
      databaseId: 'lifegame',
      tableId: 'users',
      rowId: id,
      data: userData,
    );
    await db.createRow(
      databaseId: 'lifegame',
      tableId: 'usernames',
      rowId: 'un_$id',
      data: {'username': username, 'ownerUid': id},
    );
  }

  /// A direct follow row, as if the follow had already happened.
  Future<void> seedFollow(
    String follower,
    String following, {
    String? status,
  }) async {
    final followData = <String, dynamic>{
      'followerUid': follower,
      'followingUid': following,
    };
    if (status != null) followData['status'] = status;
    await db.createRow(
      databaseId: 'lifegame',
      tableId: 'follows',
      rowId: 'f_${follower}_$following',
      data: followData,
    );
  }

  setUp(() async {
    db = _V29FakeDB();
    asUser('user-1');
    profiles = ProfileRepository(db: db);
    social = SocialRepository(db: db);
    habits = HabitRepository(db: db);
    await seedUser('user-1', 'tester', 'Tester');
    // Fresh local cache per test (the LocalStore singleton survives
    // across tests in this file).
    final store = await LocalStore.getInstance();
    await store.clearForUser('user-1');
    await store.clearForUser('user-2');
    await store.clearForUser('user-3');
    await store.clearForUser('user-4');
  });

  tearDown(() {
    AuthRepository.debugSetCachedUserForTest(null);
  });

  group('v2.9.0: follow requests', () {
    test('follow on a public account is accepted immediately', () async {
      await seedUser('user-2', 'zara', 'Zara');
      await social.follow('user-2');
      expect(await social.followStatus('user-2'), 'accepted');
      expect(await social.isFollowing('user-2'), isTrue);
      expect(await social.followingIds(), ['user-2']);
    });

    test('follow on a private account creates a pending request', () async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      await social.follow('user-2');
      // Pending is NOT "following" — the button shows "Requested".
      expect(await social.followStatus('user-2'), 'pending');
      expect(await social.isFollowing('user-2'), isFalse);
      expect(await social.followingIds(), isEmpty);
      // The private account sees the request in Notifications.
      asUser('user-2');
      final requests = await social.pendingFollowRequests();
      expect(requests.length, 1);
      expect(requests.single.$2.username, 'tester');
      expect(await social.pendingRequestCount(), 1);
    });

    test('accepting a request makes the follower visible', () async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      await social.follow('user-2');
      asUser('user-2');
      final requests = await social.pendingFollowRequests();
      await social.acceptFollowRequest(requests.single.$1);
      expect(await social.pendingFollowRequests(), isEmpty);
      // Back as the requester: now a real follower.
      asUser('user-1');
      expect(await social.followStatus('user-2'), 'accepted');
      expect(await social.isFollowing('user-2'), isTrue);
      expect(await social.followingIds(), ['user-2']);
    });

    test('declining a request deletes the row', () async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      await social.follow('user-2');
      asUser('user-2');
      final requests = await social.pendingFollowRequests();
      await social.declineFollowRequest(requests.single.$1);
      expect(await social.pendingFollowRequests(), isEmpty);
      asUser('user-1');
      expect(await social.followStatus('user-2'), 'none');
      expect(await social.isFollowing('user-2'), isFalse);
    });

    test('unfollow cancels a pending request', () async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      await social.follow('user-2');
      expect(await social.followStatus('user-2'), 'pending');
      await social.unfollow('user-2');
      expect(await social.followStatus('user-2'), 'none');
    });

    test('a follow row without status counts as accepted', () async {
      // Rows written before the `status` attribute existed have null.
      await seedUser('user-2', 'zara', 'Zara');
      await seedFollow('user-2', 'user-1');
      expect(await social.followersIds(), ['user-2']);
      final followers = await social.recentFollowers();
      expect(followers.map((p) => p.username), ['zara']);
    });
  });

  group('v2.9.0: friend circle (mutual follows only)', () {
    test('mutual follows appear, one-sided follows do not', () async {
      await seedUser('user-2', 'zara', 'Zara');
      await seedUser('user-3', 'amit', 'Amit');
      await seedUser('user-4', 'meera', 'Meera');
      // Zara and I follow each other (accepted both ways).
      await seedFollow('user-1', 'user-2', status: 'accepted');
      await seedFollow('user-2', 'user-1', status: 'accepted');
      // Amit: I follow him, he does not follow me back.
      await seedFollow('user-1', 'user-3', status: 'accepted');
      // Meera: she follows me, I do not follow her.
      await seedFollow('user-4', 'user-1', status: 'accepted');

      expect(await social.isMutual('user-2'), isTrue);
      expect(await social.isMutual('user-3'), isFalse);
      expect(await social.isMutual('user-4'), isFalse);
      final friends = await social.mutualFriends();
      expect(friends.map((p) => p.username), ['zara']);
    });

    test('a pending request is not mutual, even if they follow me',
        () async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      // Zara follows me (accepted); my follow to her is still pending.
      await seedFollow('user-2', 'user-1', status: 'accepted');
      await social.follow('user-2');
      expect(await social.followStatus('user-2'), 'pending');
      expect(await social.isMutual('user-2'), isFalse);
      expect(await social.mutualFriends(), isEmpty);
    });
  });

  group('v2.9.0: visibility + discoverability', () {
    test('old rows read as public + discoverable (null-safe)', () {
      final old = Profile.fromJson({
        'id': 'old-1',
        'username': 'old',
        'displayName': 'Old',
        'xp': 5,
      });
      expect(old.visibility, 'public');
      expect(old.isPublic, isTrue);
      expect(old.discoverable, isTrue);
      final hidden = Profile.fromJson({
        'id': 'h-1',
        'username': 'h',
        'displayName': 'H',
        'visibility': 'private',
        'discoverable': false,
      });
      expect(hidden.isPublic, isFalse);
      expect(hidden.discoverable, isFalse);
    });

    test('hidden accounts are excluded from the leaderboard', () async {
      await seedUser('user-2', 'zara', 'Zara', xp: 20, discoverable: false);
      await seedUser('user-3', 'amit', 'Amit', xp: 10);
      // user-4 has no discoverable key at all (old row) — still shown.
      await seedUser('user-4', 'meera', 'Meera', xp: 5);
      final board = await profiles.fetchGlobalLeaderboard();
      // 'tester' (user-1, xp 0, discoverable) is on the board too.
      expect(board.map((e) => e.profile.username), [
        'amit',
        'meera',
        'tester',
      ]);
      expect(board.map((e) => e.rank), [1, 2, 3]);
    });

    test('hidden accounts are excluded from Search', () async {
      await seedUser('user-2', 'zara', 'Zara', discoverable: false);
      await seedUser('user-3', 'amit', 'Amit');
      expect(await profiles.searchProfiles('z'), isEmpty);
      final found = await profiles.searchProfiles('a');
      expect(found.map((p) => p.username), ['amit']);
    });

    test('the Friends leaderboard still includes hidden people I follow',
        () async {
      await seedUser('user-2', 'zara', 'Zara', xp: 30, discoverable: false);
      await seedFollow('user-1', 'user-2', status: 'accepted');
      final board = await profiles.fetchFriendsLeaderboard();
      // Friends are not discovery — a hidden friend still shows here.
      expect(board.map((e) => e.profile.username), ['zara', 'tester']);
    });

    test('listHabitsForUser returns the habits the profile may show',
        () async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      asUser('user-2');
      final habit = await habits.addHabit(title: 'Morning run', color: 0);
      expect(habit.title, 'Morning run');
      asUser('user-1');
      final theirs = await profiles.listHabitsForUser('user-2');
      expect(theirs.map((h) => h.title), ['Morning run']);
    });
  });

  group('v2.9.0: visibility gating on the profile screen', () {
    Future<void> pumpUserProfile(
      WidgetTester tester,
      Profile profile,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: UserProfileScreen(
            profile: profile,
            socialRepo: SocialRepository(db: db),
            profileRepo: ProfileRepository(db: db),
          ),
        ),
      );
      // Bounded pumps, NOT pumpAndSettle: the loading skeleton has a
      // repeating shimmer animation, so pumpAndSettle never returns
      // while it is on screen. A few 100ms pumps let the fake-DB
      // loads (2ms each) finish and the skeleton disappear.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 200));
    }

    testWidgets('public account shows the habit list', (tester) async {
      await seedUser('user-2', 'zara', 'Zara');
      asUser('user-2');
      await habits.addHabit(title: 'Morning run', color: 0);
      asUser('user-1');
      final profile = (await profiles.fetchProfile('user-2'))!;
      await pumpUserProfile(tester, profile);
      expect(find.text('Morning run'), findsOneWidget);
      expect(find.text('This account is private'), findsNothing);
    });

    testWidgets('private account hides habits from non-mutual visitors',
        (tester) async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      asUser('user-2');
      await habits.addHabit(title: 'Morning run', color: 0);
      asUser('user-1');
      final profile = (await profiles.fetchProfile('user-2'))!;
      await pumpUserProfile(tester, profile);
      expect(find.text('This account is private'), findsOneWidget);
      expect(find.text('Morning run'), findsNothing);
    });

    testWidgets('private account shows habits to a mutual friend',
        (tester) async {
      await seedUser('user-2', 'zara', 'Zara', visibility: 'private');
      asUser('user-2');
      await habits.addHabit(title: 'Morning run', color: 0);
      await seedFollow('user-2', 'user-1', status: 'accepted');
      await seedFollow('user-1', 'user-2', status: 'accepted');
      asUser('user-1');
      final profile = (await profiles.fetchProfile('user-2'))!;
      await pumpUserProfile(tester, profile);
      expect(find.text('Morning run'), findsOneWidget);
      expect(find.text('This account is private'), findsNothing);
    });
  });

  group('v2.9.0: offline-first', () {
    test('habits, logs and XP load from the local cache with no network',
        () async {
      final today = todayKey();
      final habit = await habits.addHabit(title: 'Offline habit', color: 0);
      // Warm the caches while online.
      expect((await habits.listMyHabits()).length, 1);
      expect((await profiles.fetchMyProfile())!.xp, 0);

      db.failAll = true;
      // Everything still loads from local — no error, no blank data.
      final cachedHabits = await habits.listMyHabits();
      expect(cachedHabits.map((h) => h.title), ['Offline habit']);
      // Tick offline: completes (no rollback) and the log is cached.
      final result = await habits.toggleHabit(
        habit: habit,
        date: today,
        completed: true,
      );
      expect(result, isNotNull);
      final logs = await habits.listLogsForDate(today);
      expect(logs.length, 1);
      expect(logs.single.completed, isTrue);
      // XP is derived locally: 2 for the one completed habit.
      final me = await profiles.fetchMyProfile();
      expect(me!.xp, 2);
      expect(me.currentStreak, 1);
      // The server write is queued for the background sync.
      final store = await LocalStore.getInstance();
      expect(
        store.loadOutbox().any(
          (o) => o['kind'] == 'log' && o['habitId'] == habit.id,
        ),
        isTrue,
      );
      db.failAll = false;
    });
  });

  group('v2.9.0: colour picker', () {
    test('the palette has no duplicate colours', () {
      final firsts = AppTheme.habitGradients
          .map((g) => g.colors.first.toARGB32())
          .toList();
      expect(firsts.toSet().length, firsts.length);
      expect(firsts.length, 6);
    });

    testWidgets('exactly one checkmark, whichever colour is tapped',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showAddHabitDialog(context),
                  child: const Text('Add habit'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Add habit'));
      // Bounded pumps, NOT pumpAndSettle: the dialog's entrance is a
      // one-shot animation, but a settle wait is unnecessary here.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Add a habit'), findsOneWidget);
      // The preset colour circles: GestureDetector wrapping a
      // 40x40 circle Container with a gradient.
      final circles = find.byWidgetPredicate((widget) {
        if (widget is! GestureDetector) return false;
        final child = widget.child;
        if (child is! Container) return false;
        final decoration = child.decoration;
        return decoration is BoxDecoration &&
            decoration.shape == BoxShape.circle &&
            decoration.gradient != null;
      });
      expect(circles, findsNWidgets(6));
      // One checkmark at first (the default first colour).
      expect(find.byIcon(Icons.check), findsOneWidget);
      // Tap a different colour — still exactly one checkmark.
      await tester.tap(circles.at(3));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
      // And tapping yet another colour keeps it at one.
      await tester.tap(circles.at(5));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsOneWidget);
    });
  });

  group('v2.9.0: leaderboard week + rank line', () {
    test('week range is Monday–Sunday, short month names', () {
      // Wed 18 Nov 2026 → week Mon 16 – Sun 22 Nov.
      expect(weekRangeLabel(DateTime(2026, 11, 18)), 'Nov 16 - 22');
      // Monday itself.
      expect(weekRangeLabel(DateTime(2026, 11, 16)), 'Nov 16 - 22');
      // Sunday itself.
      expect(weekRangeLabel(DateTime(2026, 11, 22)), 'Nov 16 - 22');
      // A week spanning two months: Mon 30 Nov – Sun 6 Dec.
      expect(weekRangeLabel(DateTime(2026, 12, 2)), 'Nov 30 - Dec 6');
    });

    test('days left in the week: 6 on Monday, 0 on Sunday', () {
      expect(daysLeftInWeek(DateTime(2026, 11, 16)), 6);
      expect(daysLeftInWeek(DateTime(2026, 11, 18)), 4);
      expect(daysLeftInWeek(DateTime(2026, 11, 21)), 1);
      expect(daysLeftInWeek(DateTime(2026, 11, 22)), 0);
    });

    test('XP to the next rank follows the level bands', () {
      // 158 XP → level 2 Recruit; Warrior starts at level 3 (200 XP).
      expect(nextRankNameForXp(158), 'Warrior');
      expect(xpToNextRank(158), 42);
      // Exactly on a boundary: 200 XP → level 3 Warrior; Knight at 400.
      expect(nextRankNameForXp(200), 'Knight');
      expect(xpToNextRank(200), 200);
      // 950 XP → level 10 Warlord; Legend starts at level 11 (1000 XP).
      expect(nextRankNameForXp(950), 'Legend');
      expect(xpToNextRank(950), 50);
      // Legend is the top rank: no next rank, nothing more to earn.
      expect(nextRankNameForXp(1000), isNull);
      expect(xpToNextRank(1000), 0);
      expect(nextRankNameForXp(5432), isNull);
      expect(xpToNextRank(5432), 0);
    });
  });

  group('v2.9.0: theme', () {
    test('the theme choice persists across loads (default dark)',
        () async {
      final controller = ThemeController.instance;
      await controller.load();
      expect(controller.isLight, isFalse);
      await controller.setMode(Brightness.light);
      expect(controller.isLight, isTrue);
      // A fresh load reads the saved choice back.
      await controller.load();
      expect(controller.isLight, isTrue);
      // Reset for the other tests in this file.
      await controller.setMode(Brightness.dark);
      expect(controller.isLight, isFalse);
    });
  });
}
