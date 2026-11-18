// Sub-tasks (v2.8.0, 18 Nov 2026): pure rules — which sub-tasks are
// due, when a habit counts as done, and how the daily score is built
// from the work done (sub-tasks), not just habit ticks.
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/logic/subtasks.dart';

void main() {
  const today = '2026-11-18';
  const yesterday = '2026-11-17';
  const tomorrow = '2026-11-19';

  HabitSubtask daily(String id, {String date = yesterday}) => HabitSubtask(
    id: id,
    habitId: 'h1',
    title: 'Daily $id',
    kind: HabitSubtask.kindDaily,
    date: date,
  );
  HabitSubtask todayOnly(String id, {String date = today}) => HabitSubtask(
    id: id,
    habitId: 'h1',
    title: 'Today $id',
    kind: HabitSubtask.kindToday,
    date: date,
  );

  group('dueSubtasks', () {
    test('daily sub-tasks are due every day from creation onward', () {
      final subs = [daily('a', date: yesterday), daily('b', date: today)];
      expect(dueSubtasks(subs, today).map((s) => s.id), ['a', 'b']);
      expect(dueSubtasks(subs, tomorrow).map((s) => s.id), ['a', 'b']);
    });

    test('a daily sub-task created tomorrow is not due today', () {
      final subs = [daily('a', date: tomorrow)];
      expect(dueSubtasks(subs, today), isEmpty);
    });

    test('today sub-tasks are due only on their own date', () {
      final subs = [todayOnly('a'), todayOnly('b', date: tomorrow)];
      expect(dueSubtasks(subs, today).map((s) => s.id), ['a']);
      expect(dueSubtasks(subs, tomorrow).map((s) => s.id), ['b']);
    });

    test('archived sub-tasks are never due', () {
      final subs = [daily('a').copyWith(archived: true)];
      expect(dueSubtasks(subs, today), isEmpty);
    });
  });

  group('habitIsDone', () {
    test('no sub-tasks due: the habit tick decides', () {
      expect(
        habitIsDone(due: [], doneSubtaskIds: {}, habitTicked: true),
        isTrue,
      );
      expect(
        habitIsDone(due: [], doneSubtaskIds: {}, habitTicked: false),
        isFalse,
      );
    });

    test('sub-tasks due: all of them must be done', () {
      final due = [daily('a'), daily('b')];
      expect(
        habitIsDone(
          due: due,
          doneSubtaskIds: {'a'},
          habitTicked: true,
        ),
        isFalse,
      );
      expect(
        habitIsDone(
          due: due,
          doneSubtaskIds: {'a', 'b'},
          habitTicked: false,
        ),
        isTrue,
      );
    });
  });

  group('scoreItemsForToday', () {
    const habitWithSubs = Habit(
      id: 'h1',
      userId: 'u1',
      title: 'Exercise',
    );
    const habitPlain = Habit(id: 'h2', userId: 'u1', title: 'Read');

    test('a habit with sub-tasks contributes one item per sub-task', () {
      final items = scoreItemsForToday(
        habits: [habitWithSubs],
        dueByHabit: {
          'h1': [daily('a'), todayOnly('b')],
        },
        doneSubtaskIds: {'a'},
        doneHabitIds: {},
      );
      expect(items.length, 2);
      expect(items[0].displayLabel, 'Exercise — Daily a');
      expect(items[0].done, isTrue);
      expect(items[0].isSubtask, isTrue);
      expect(items[1].done, isFalse);
    });

    test('a habit with no sub-tasks contributes itself', () {
      final items = scoreItemsForToday(
        habits: [habitPlain],
        dueByHabit: {},
        doneSubtaskIds: {},
        doneHabitIds: {'h2'},
      );
      expect(items.length, 1);
      expect(items[0].displayLabel, 'Read');
      expect(items[0].isSubtask, isFalse);
      expect(items[0].done, isTrue);
    });

    test('mixed habits: sub-tasks where they exist, habits elsewhere', () {
      final items = scoreItemsForToday(
        habits: [habitWithSubs, habitPlain],
        dueByHabit: {
          'h1': [daily('a')],
        },
        doneSubtaskIds: {},
        doneHabitIds: {},
      );
      expect(items.length, 2);
      expect(items[0].isSubtask, isTrue);
      expect(items[1].isSubtask, isFalse);
    });
  });

  group('scorePercent', () {
    test('0 items is 0%', () {
      expect(scorePercent([]), 0);
    });

    test('1 of 3 done is 33%', () {
      final items = scoreItemsForToday(
        habits: const [
          Habit(id: 'h1', userId: 'u1', title: 'A'),
          Habit(id: 'h2', userId: 'u1', title: 'B'),
          Habit(id: 'h3', userId: 'u1', title: 'C'),
        ],
        dueByHabit: {},
        doneSubtaskIds: {},
        doneHabitIds: {'h1'},
      );
      expect(scorePercent(items), 33);
    });
  });
}
