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
    final stamp = DateTime.utc(
      2026,
      1,
      1,
    ).add(Duration(milliseconds: _seq++));
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
    await _latency();
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
                (r) =>
                    _compare(_valueOf(r, attribute!), values.first) > 0,
              )
              .toList();
        case 'greaterThanEqual':
          rows = rows
              .where(
                (r) =>
                    _compare(_valueOf(r, attribute!), values.first) >= 0,
              )
              .toList();
        case 'lessThanEqual':
          rows = rows
              .where(
                (r) =>
                    _compare(_valueOf(r, attribute!), values.first) <= 0,
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
            (a, b) =>
                _compare(_valueOf(a, attrAsc), _valueOf(b, attrAsc)),
          );
        case 'orderDesc':
          final attrDesc = attribute!;
          rows.sort(
            (a, b) =>
                _compare(_valueOf(b, attrDesc), _valueOf(a, attrDesc)),
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
    await db.createRow(
      databaseId: 'lifegame',
      tableId: 'users',
      rowId: 'user-1',
      data: {
        'username': 'tester',
        'displayName': 'Tester',
        'bio': '',
        'xp': 50,
        'currentStreak': 1,
        'longestStreak': 1,
        'lastActiveDate': today,
      },
    );
  });

  tearDown(() {
    AuthRepository.debugSetCachedUserForTest(null);
  });

  Future<Profile> myProfile() async => (await profiles.fetchMyProfile())!;

  group('toggle persistence (live-test regression, 14 Nov 2026)', () {
    test('concurrent tick then untick leaves the stored state undone',
        () async {
      final habit = await habits.addHabit(title: 'XP Test', color: 0);

      // Fired together, like two fast taps: without serialisation the
      // untick reads the log before the tick has written it, no-ops,
      // and the tick's +2 XP + log survive — the UI then shows 50/undone
      // while the server holds 52/done.
      await Future.wait([
        habits.toggleHabit(habit: habit, date: today, completed: true),
        habits.toggleHabit(habit: habit, date: today, completed: false),
      ]);

      expect(await habits.listLogsForDate(today), isEmpty);
      final after = await myProfile();
      expect(after.xp, 50);
      expect(after.currentStreak, 0);
    });

    test('concurrent untick then tick leaves the stored state done',
        () async {
      final habit = await habits.addHabit(title: 'XP Test', color: 0);
      await habits.toggleHabit(habit: habit, date: today, completed: true);
      expect((await myProfile()).xp, 52);

      await Future.wait([
        habits.toggleHabit(habit: habit, date: today, completed: false),
        habits.toggleHabit(habit: habit, date: today, completed: true),
      ]);

      expect((await habits.listLogsForDate(today)).length, 1);
      final after = await myProfile();
      expect(after.xp, 52);
      expect(after.currentStreak, 1);
    });

    test('sequential tick then untick restores base XP and removes the log',
        () async {
      final habit = await habits.addHabit(title: 'XP Test', color: 0);
      await habits.toggleHabit(habit: habit, date: today, completed: true);
      expect((await myProfile()).xp, 52);
      await habits.toggleHabit(habit: habit, date: today, completed: false);

      expect(await habits.listLogsForDate(today), isEmpty);
      final after = await myProfile();
      expect(after.xp, 50);
      expect(after.currentStreak, 0);
    });
  });

  group('deleteHabit keeps XP and streak consistent', () {
    test('deleting a habit done today takes back its +2 XP', () async {
      final habit = await habits.addHabit(title: 'XP Test', color: 0);
      await habits.toggleHabit(habit: habit, date: today, completed: true);
      expect((await myProfile()).xp, 52);

      await habits.deleteHabit(habit.id);

      expect(await habits.listMyHabits(), isEmpty);
      expect(await habits.listLogsForDate(today), isEmpty);
      final after = await myProfile();
      expect(after.xp, 50);
      expect(after.currentStreak, 0);
      expect(after.longestStreak, 1);
    });

    test('deleting a never-done habit leaves XP and streak untouched',
        () async {
      // A second habit done today backs the seeded streak with a real log.
      final doneHabit = await habits.addHabit(title: 'Wake up at 4am', color: 0);
      await habits.toggleHabit(
        habit: doneHabit,
        date: today,
        completed: true,
      );
      expect((await myProfile()).xp, 52);
      expect((await myProfile()).currentStreak, 1);

      final habit = await habits.addHabit(title: 'XP Test', color: 0);
      await habits.deleteHabit(habit.id);

      final remaining = await habits.listMyHabits();
      expect(remaining.map((h) => h.id), [doneHabit.id]);
      expect((await habits.listLogsForDate(today)).length, 1);
      final after = await myProfile();
      expect(after.xp, 52);
      expect(after.currentStreak, 1);
    });
  });

  group('task deletes keep XP consistent', () {
    test('deleting a done weekly task takes back its +2 XP', () async {
      final week = weekStartKey();
      await tasks.addWeeklyTask('Buy groceries', week);
      final task = (await tasks.listWeeklyTasks(week)).first;
      await tasks.toggleWeeklyTask(task.id, true);
      expect((await myProfile()).xp, 52);

      await tasks.deleteWeeklyTask(task.id);

      expect(await tasks.listWeeklyTasks(week), isEmpty);
      expect((await myProfile()).xp, 50);
    });

    test('deleting a pending weekly task leaves XP untouched', () async {
      final week = weekStartKey();
      await tasks.addWeeklyTask('Buy groceries', week);
      final task = (await tasks.listWeeklyTasks(week)).first;

      await tasks.deleteWeeklyTask(task.id);

      expect(await tasks.listWeeklyTasks(week), isEmpty);
      expect((await myProfile()).xp, 50);
    });
  });
}
