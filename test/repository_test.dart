import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/logic/xp.dart';

/// A [Client] that never talks to anything: constructing a real Client
/// in a unit test fails — its async init hits platform channels
/// (path_provider / package_info) that do not exist in tests.
/// [noSuchMethod] satisfies the interface; the fake database never
/// touches the client.
class _StubClient implements Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory [TablesDB] with a small artificial latency on every call,
/// so two repository calls fired together genuinely overlap — exactly
/// what the live test did when it ticked/unticked in quick succession.
/// Supports the query operators the repositories use (equal,
/// greaterThan / greaterThanEqual / lessThanEqual, startsWith,
/// orderAsc / orderDesc, limit, offset).
class FakeTablesDB extends TablesDB {
  FakeTablesDB() : super(_StubClient());

  final Map<String, Map<String, _FakeRow>> _tables = {};
  int _seq = 0;

  /// When true, reads lag writes: for [staleWindow] after a mutation,
  /// getRow/listRows see the tables as they were before that mutation
  /// (the read-after-write lag Appwrite Cloud shows under rapid
  /// toggling, 18 Nov 2026). Only [laggyTables] are affected — the
  /// live failure was a habit-log read going stale right after a log
  /// write; profile reads were fine live, and the UI paints XP
  /// optimistically rather than trusting a re-read for it. Off by
  /// default.
  bool laggyReads = false;
  Duration staleWindow = const Duration(milliseconds: 50);
  final Set<String> laggyTables = {'habit_logs'};

  Map<String, Map<String, _FakeRow>>? _staleSnapshot;
  DateTime? _staleUntil;

  Map<String, Map<String, _FakeRow>> _deepCopyTables() => {
    for (final e in _tables.entries)
      e.key: {
        for (final r in e.value.entries)
          r.key: _FakeRow(
            id: r.value.id,
            createdAt: r.value.createdAt,
            data: Map<String, dynamic>.from(r.value.data),
          ),
      },
  };

  void _recordMutation(String tableId) {
    if (!laggyReads || !laggyTables.contains(tableId)) return;
    _staleSnapshot = _deepCopyTables();
    _staleUntil = DateTime.now().add(staleWindow);
  }

  /// The tables a read sees: the pre-mutation snapshot while the
  /// stale window lasts, the live tables otherwise.
  Map<String, Map<String, _FakeRow>> _readTables() {
    final snapshot = _staleSnapshot;
    final until = _staleUntil;
    if (laggyReads &&
        snapshot != null &&
        until != null &&
        DateTime.now().isBefore(until)) {
      return snapshot;
    }
    return _tables;
  }

  Map<String, _FakeRow> _readRowsOf(String tableId) {
    // Only laggy tables read from the snapshot; every other table
    // reads live (see the laggyReads doc above).
    if (laggyReads && laggyTables.contains(tableId)) {
      return _readTables()[tableId] ?? {};
    }
    return _rowsOf(tableId);
  }

  Map<String, _FakeRow> _rowsOf(String tableId) =>
      _tables.putIfAbsent(tableId, () => {});

  Future<void> _latency() async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  models.Row _toRow(String tableId, _FakeRow row) => models.Row(
    $id: row.id,
    $sequence: '0',
    $tableId: tableId,
    $databaseId: 'lifegame',
    $createdAt: row.createdAt,
    $updatedAt: row.createdAt,
    $permissions: const [],
    data: Map<String, dynamic>.from(row.data),
  );

  String _now() {
    final stamp = DateTime.utc(2026, 1, 1).add(Duration(milliseconds: _seq++));
    return stamp.toIso8601String();
  }

  @override
  Future<models.Row> createRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    required Map data,
    List<String>? permissions,
    String? transactionId,
  }) async {
    await _latency();
    _recordMutation(tableId);
    final rows = _rowsOf(tableId);
    if (rows.containsKey(rowId)) {
      throw AppwriteException(
        'Row already exists',
        409,
        'document_already_exists',
      );
    }
    final row = _FakeRow(
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
    await _latency();
    final row = _readRowsOf(tableId)[rowId];
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
    await _latency();
    _recordMutation(tableId);
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
    await _latency();
    _recordMutation(tableId);
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
    await _latency();
    var rows = _readRowsOf(tableId).values.toList();
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
              .where((r) => _compare(_valueOf(r, attribute!), values.first) > 0)
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

  dynamic _valueOf(_FakeRow row, String attribute) {
    if (attribute == r'$createdAt') return row.createdAt;
    if (attribute == r'$id') return row.id;
    return row.data[attribute];
  }

  int _compare(dynamic a, dynamic b) {
    if (a is Comparable && b is Comparable) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }
}

class _FakeRow {
  _FakeRow({required this.id, required this.createdAt, required this.data});

  final String id;
  final String createdAt;
  final Map<String, dynamic> data;
}

void main() {
  late FakeTablesDB db;
  late HabitRepository habits;
  late TaskRepository tasks;
  late ProfileRepository profiles;
  final today = todayKey();

  setUp(() async {
    db = FakeTablesDB();
    AuthRepository.debugSetCachedUserForTest(
      const AppAuthUser(uid: 'user-1', email: 'test@example.com'),
    );
    habits = HabitRepository(db: db);
    tasks = TaskRepository(db: db);
    profiles = ProfileRepository(db: db);
    // Derived-consistent seed: XP is 2 x completed logs and the streak
    // comes from the active dates, so a fresh profile starts at 0 XP /
    // 0 streak. (A drifted seed — e.g. the old +50 daily bonus with no
    // completed logs — is corrected to the derived value by the first
    // toggle's reconcile; see the drift test below.)
    await db.createRow(
      databaseId: 'lifegame',
      tableId: 'users',
      rowId: 'user-1',
      data: {
        'username': 'tester',
        'displayName': 'Tester',
        'bio': '',
        'xp': 0,
        'currentStreak': 0,
        'longestStreak': 0,
        'lastActiveDate': null,
      },
    );
  });

  tearDown(() {
    AuthRepository.debugSetCachedUserForTest(null);
  });

  Future<Profile> myProfile() async => (await profiles.fetchMyProfile())!;

  group('toggle persistence (live-test regression, 14 Nov 2026)', () {
    test(
      'concurrent tick then untick leaves the stored state undone',
      () async {
        final habit = await habits.addHabit(title: 'XP Test', color: 0);

        // Fired together, like two fast taps: without serialisation the
        // untick reads the log before the tick has written it, no-ops,
        // and the tick's +2 XP + log survive — the UI then shows 0/undone
        // while the server holds 2/done.
        await Future.wait([
          habits.toggleHabit(habit: habit, date: today, completed: true),
          habits.toggleHabit(habit: habit, date: today, completed: false),
        ]);

        expect(await habits.listLogsForDate(today), isEmpty);
        final after = await myProfile();
        // Tick +2 then untick -2 (full reversal, 18 Nov 2026 rule):
        // the tick's XP is taken back entirely, so XP returns to 0.
        expect(after.xp, 0);
        expect(after.currentStreak, 0);
      },
    );

    test('concurrent untick then tick leaves the stored state done', () async {
      final habit = await habits.addHabit(title: 'XP Test', color: 0);
      await habits.toggleHabit(habit: habit, date: today, completed: true);
      expect((await myProfile()).xp, 2);

      await Future.wait([
        habits.toggleHabit(habit: habit, date: today, completed: false),
        habits.toggleHabit(habit: habit, date: today, completed: true),
      ]);

      expect((await habits.listLogsForDate(today)).length, 1);
      final after = await myProfile();
      // Untick -2 then tick +2: net 0, so XP stays 2.
      expect(after.xp, 2);
      expect(after.currentStreak, 1);
    });

    test(
      'sequential tick then untick leaves 0 XP and removes the log',
      () async {
        final habit = await habits.addHabit(title: 'XP Test', color: 0);
        await habits.toggleHabit(habit: habit, date: today, completed: true);
        expect((await myProfile()).xp, 2);
        await habits.toggleHabit(habit: habit, date: today, completed: false);

        expect(await habits.listLogsForDate(today), isEmpty);
        final after = await myProfile();
        // Untick takes back the full +2 (18 Nov 2026 rule): XP is
        // derived from what is currently done, so it returns to 0.
        expect(after.xp, 0);
        expect(after.currentStreak, 0);
      },
    );

    test(
      'rapid burst ending in untick saves undone even with laggy reads',
      () async {
        db.laggyReads = true;
        final habit = await habits.addHabit(title: 'XP Test', color: 0);

        // Five rapid tick/untick cycles, fired without awaiting (the
        // live test, 18 Nov 2026): the old read-modify-write toggle
        // lost one untick to a stale read and the server kept DONE/2 XP
        // while the UI showed undone/0 XP. The coalesced sync writes
        // only the final state, so the burst must end undone at 0 XP.
        final pending = <Future<ToggleResult>>[];
        for (var i = 0; i < 5; i++) {
          pending.add(
            habits.toggleHabit(habit: habit, date: today, completed: true),
          );
          pending.add(
            habits.toggleHabit(habit: habit, date: today, completed: false),
          );
        }
        await Future.wait(pending);

        expect(await habits.listLogsForDate(today), isEmpty);
        final after = await myProfile();
        expect(after.xp, 0);
        expect(after.currentStreak, 0);
      },
    );

    test(
      'rapid burst ending in tick saves done even with laggy reads',
      () async {
        db.laggyReads = true;
        final habit = await habits.addHabit(title: 'XP Test', color: 0);

        final pending = <Future<ToggleResult>>[];
        for (var i = 0; i < 5; i++) {
          pending.add(
            habits.toggleHabit(habit: habit, date: today, completed: true),
          );
          pending.add(
            habits.toggleHabit(habit: habit, date: today, completed: false),
          );
        }
        pending.add(
          habits.toggleHabit(habit: habit, date: today, completed: true),
        );
        await Future.wait(pending);

        expect((await habits.listLogsForDate(today)).length, 1);
        final after = await myProfile();
        expect(after.xp, 2);
        expect(after.currentStreak, 1);
      },
    );

    test('a toggle corrects a drifted stored XP to the derived value', () async {
      // The profile carries the legacy +50 daily bonus with no
      // completed logs: XP is derived from the logs, so the first
      // toggle heals the drift (18 Nov 2026 rule).
      await db.updateRow(
        databaseId: 'lifegame',
        tableId: 'users',
        rowId: 'user-1',
        data: {'xp': 50},
      );
      final habit = await habits.addHabit(title: 'XP Test', color: 0);
      await habits.toggleHabit(habit: habit, date: today, completed: true);
      expect((await myProfile()).xp, 2);
      expect((await myProfile()).currentStreak, 1);
    });
  });

  group('deleteHabit keeps XP and streak consistent', () {
    test('deleting a habit done today takes back 2 XP', () async {
      final habit = await habits.addHabit(title: 'XP Test', color: 0);
      await habits.toggleHabit(habit: habit, date: today, completed: true);
      expect((await myProfile()).xp, 2);

      await habits.deleteHabit(habit.id);

      expect(await habits.listMyHabits(), isEmpty);
      expect(await habits.listLogsForDate(today), isEmpty);
      final after = await myProfile();
      expect(after.xp, 0);
      expect(after.currentStreak, 0);
      expect(after.longestStreak, 1);
    });

    test(
      'deleting a never-done habit leaves XP and streak untouched',
      () async {
        // A second habit done today backs the seeded streak with a real log.
        final doneHabit = await habits.addHabit(
          title: 'Wake up at 4am',
          color: 0,
        );
        await habits.toggleHabit(
          habit: doneHabit,
          date: today,
          completed: true,
        );
        expect((await myProfile()).xp, 2);
        expect((await myProfile()).currentStreak, 1);

        final habit = await habits.addHabit(title: 'XP Test', color: 0);
        await habits.deleteHabit(habit.id);

        final remaining = await habits.listMyHabits();
        expect(remaining.map((h) => h.id), [doneHabit.id]);
        expect((await habits.listLogsForDate(today)).length, 1);
        final after = await myProfile();
        expect(after.xp, 2);
        expect(after.currentStreak, 1);
      },
    );
  });

  group('task deletes keep XP consistent', () {
    test('deleting a done weekly task takes back 2 XP', () async {
      final week = weekStartKey();
      await tasks.addWeeklyTask('Buy groceries', week);
      final task = (await tasks.listWeeklyTasks(week)).first;
      await tasks.toggleWeeklyTask(task.id, true);
      expect((await myProfile()).xp, 2);

      await tasks.deleteWeeklyTask(task.id);

      expect(await tasks.listWeeklyTasks(week), isEmpty);
      expect((await myProfile()).xp, 0);
    });

    test('deleting a pending weekly task leaves XP untouched', () async {
      final week = weekStartKey();
      await tasks.addWeeklyTask('Buy groceries', week);
      final task = (await tasks.listWeeklyTasks(week)).first;

      await tasks.deleteWeeklyTask(task.id);

      expect(await tasks.listWeeklyTasks(week), isEmpty);
      expect((await myProfile()).xp, 0);
    });
  });
  group('feedback', () {
    late FeedbackRepository feedback;

    setUp(() {
      feedback = FeedbackRepository(db: db);
    });

    test('submitting feedback saves a row with my user id', () async {
      final entry = await feedback.submitFeedback('Love the app!');
      expect(entry.text, 'Love the app!');
      expect(entry.userId, 'user-1');
      expect(entry.createdAt, isNotNull);
      final mine = await feedback.listMyFeedback();
      expect(mine.map((e) => e.text), ['Love the app!']);
    });

    test('the newest feedback comes first', () async {
      await feedback.submitFeedback('First');
      await feedback.submitFeedback('Second');
      final mine = await feedback.listMyFeedback();
      expect(mine.map((e) => e.text), ['Second', 'First']);
    });

    test('empty feedback is rejected', () async {
      expect(
        () => feedback.submitFeedback('   '),
        throwsA(isA<AuthException>()),
      );
    });
  });

  group('account deletion removes all user rows', () {
    late AccountRepository account;
    late SocialRepository social;

    setUp(() {
      account = AccountRepository(db: db);
      social = SocialRepository(db: db);
    });

    test(
      'deleteAllMyData removes every row that belongs to the user',
      () async {
        // A second user to follow, so "other people's data survives" can
        // be asserted too.
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'users',
          rowId: 'user-2',
          data: {
            'displayName': 'Other User',
            'username': 'otheruser',
            'currentStreak': 0,
            'longestStreak': 0,
            'xp': 10,
            'email': 'other@example.com',
            'avatar': null,
            'lastActiveDate': null,
          },
        );
        final habit = await habits.addHabit(title: 'XP Test', color: 0);
        await habits.toggleHabit(habit: habit, date: today, completed: true);
        await tasks.addWeeklyTask('Buy groceries', weekStartKey());
        final weekly = (await tasks.listWeeklyTasks(weekStartKey())).first;
        await tasks.toggleWeeklyTask(weekly.id, true);
        await tasks.addMonthlyTask('Read a book', monthKey());
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'daily_rewards',
          rowId: 'user-1_$today',
          data: {
            'ownerUid': 'user-1',
            'date': today,
            'xp': 50,
            'kind': 'daily_complete',
          },
        );
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'usernames',
          rowId: 'tester',
          data: {'username': 'tester', 'ownerUid': 'user-1'},
        );
        await social.follow('user-2');
        // Sanity: 2 (habit, derived) + 2 (weekly task).
        expect((await profiles.fetchMyProfile())?.xp, 4);

        await account.deleteAllMyData();

        expect(await habits.listMyHabits(), isEmpty);
        expect(await habits.listLogsForDate(today), isEmpty);
        expect(await tasks.listWeeklyTasks(weekStartKey()), isEmpty);
        expect(await tasks.listMonthlyTasks(monthKey()), isEmpty);
        expect(await social.followingIds(), isEmpty);
        expect(await profiles.fetchMyProfile(), isNull);
        expect(await profiles.isUsernameTaken('tester'), isFalse);
        final rewards = await db.listRows(
          databaseId: 'lifegame',
          tableId: 'daily_rewards',
          queries: [Query.equal('ownerUid', 'user-1')],
        );
        expect(rewards.total, 0);
        // The other user's profile must survive.
        expect((await profiles.fetchProfile('user-2'))?.username, 'otheruser');
      },
    );

    test('deleteAllMyData is idempotent', () async {
      await account.deleteAllMyData();
      await account.deleteAllMyData();
      expect(await profiles.fetchMyProfile(), isNull);
      expect(await habits.listMyHabits(), isEmpty);
    });

    test('deleteAccount without a signed-in user throws', () async {
      AuthRepository.debugSetCachedUserForTest(null);
      final auth = AuthRepository();
      expect(() => auth.deleteAccount(), throwsA(isA<AuthException>()));
    });
  });

  group('v2.6.0 (18 Nov 2026): habit notes, XP ledger sources, follow lists', () {
    test('habit notes round-trip through updateHabit and listMyHabits', () async {
      final habit = await habits.addHabit(title: 'Read', color: 0);
      await habits.updateHabit(habit, notes: '10 pages before bed');
      final listed = await habits.listMyHabits();
      expect(listed.single.notes, '10 pages before bed');

      // Clearing the note (empty string) removes it.
      await habits.updateHabit(listed.single, notes: '');
      expect((await habits.listMyHabits()).single.notes, isEmpty);
    });

    test('listAllCompletedLogs returns completed logs, newest first', () async {
      final habit = await habits.addHabit(title: 'Read', color: 0);
      final other = await habits.addHabit(title: 'Run', color: 1);
      await habits.toggleHabit(habit: habit, date: '2026-11-16', completed: true);
      await habits.toggleHabit(habit: other, date: '2026-11-18', completed: true);
      await habits.toggleHabit(habit: habit, date: '2026-11-17', completed: true);
      // One log is unticked again: it must not appear in the ledger.
      await habits.toggleHabit(habit: habit, date: '2026-11-16', completed: false);

      final logs = await habits.listAllCompletedLogs();
      expect(logs.length, 2);
      expect(logs.map((l) => l.logDate), ['2026-11-18', '2026-11-17']);
      expect(logs.every((l) => l.completed), isTrue);
    });

    test('listAllDoneWeeklyTasks / listAllDoneMonthlyTasks return done tasks only', () async {
      await tasks.addWeeklyTask('Weekly review', '2026-11-16');
      await tasks.addWeeklyTask('Not done yet', '2026-11-16');
      await tasks.addMonthlyTask('Pay rent', '2026-11');
      await tasks.addMonthlyTask('Skip this', '2026-11');
      final weekly = await tasks.listWeeklyTasks('2026-11-16');
      final monthly = await tasks.listMonthlyTasks('2026-11');
      await tasks.toggleWeeklyTask(
        weekly.firstWhere((t) => t.title == 'Weekly review').id,
        true,
      );
      await tasks.toggleMonthlyTask(
        monthly.firstWhere((t) => t.title == 'Pay rent').id,
        true,
      );

      final doneWeekly = await tasks.listAllDoneWeeklyTasks();
      expect(doneWeekly.length, 1);
      expect(doneWeekly.single.title, 'Weekly review');
      final doneMonthly = await tasks.listAllDoneMonthlyTasks();
      expect(doneMonthly.length, 1);
      expect(doneMonthly.single.title, 'Pay rent');
    });

    test('followProfiles returns followers and following, sorted by name', () async {
      Future<void> seedUser(String id, String name) async {
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'users',
          rowId: id,
          data: {
            'username': name.toLowerCase(),
            'displayName': name,
            'bio': '',
            'xp': 0,
            'currentStreak': 0,
            'longestStreak': 0,
            'lastActiveDate': null,
          },
        );
      }

      await seedUser('user-2', 'Zara');
      await seedUser('user-3', 'Amit');
      await seedUser('user-4', 'Meera');
      final social = SocialRepository(db: db);
      // user-2 and user-3 follow me; I follow user-3 and user-4.
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'follows',
        rowId: 'user-2_user-1',
        data: {'followerUid': 'user-2', 'followingUid': 'user-1'},
      );
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'follows',
        rowId: 'user-3_user-1',
        data: {'followerUid': 'user-3', 'followingUid': 'user-1'},
      );
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'follows',
        rowId: 'user-1_user-3',
        data: {'followerUid': 'user-1', 'followingUid': 'user-3'},
      );
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'follows',
        rowId: 'user-1_user-4',
        data: {'followerUid': 'user-1', 'followingUid': 'user-4'},
      );

      expect(await social.followersIds(), ['user-2', 'user-3']);
      expect(await social.followingIds(), ['user-3', 'user-4']);

      final followers = await social.followProfiles(followers: true);
      expect(followers.map((p) => p.displayName), ['Amit', 'Zara']);
      final following = await social.followProfiles(followers: false);
      expect(following.map((p) => p.displayName), ['Amit', 'Meera']);
    });

    test('followProfiles skips ids with no profile row', () async {
      final social = SocialRepository(db: db);
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'follows',
        rowId: 'ghost_user-1',
        data: {'followerUid': 'ghost', 'followingUid': 'user-1'},
      );
      expect(await social.followProfiles(followers: true), isEmpty);
    });
  });
}
