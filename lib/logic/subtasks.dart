// Pure sub-task rules for Life Game (v2.8.0, 18 Nov 2026).
//
// A habit can be broken into sub-tasks. Some are DAILY (recurring,
// due every day) and some are TODAY (only for one day). The daily
// score is built from the WORK DONE — sub-tasks — not just habit
// ticks:
//
// - An item the score counts is either a sub-task (for a habit that
//   has sub-tasks due today) or the habit itself (for a habit with
//   NO sub-tasks due today).
// - Score % = items done today / items due today x 100.
// - A habit counts as DONE (+2 XP) when: it has sub-tasks due and
//   ALL of them are done, or it has no sub-tasks due and its own
//   tick is on. Unticking a sub-task reverses the habit's done state
//   when it was fully done. There is NO XP per sub-task — XP stays
//   +2 per habit, derived, no bonus, no penalty (see logic/xp.dart).
//
// These functions are free of any backend dependency so they can be
// unit-tested (see test/subtask_test.dart).
library;

import '../data/models.dart';

/// One item the daily score counts: a sub-task, or a whole habit when
/// it has no sub-tasks due.
class ScoreItem {
  const ScoreItem({
    required this.habitId,
    required this.habitTitle,
    required this.title,
    required this.done,
    this.subtaskId,
  });

  /// The habit this item belongs to.
  final String habitId;

  /// The habit's title (shown so a sub-task can be traced by hand).
  final String habitTitle;

  /// The item's own title: the sub-task title, or the habit title
  /// when the item IS the habit.
  final String title;

  /// Whether it is done today.
  final bool done;

  /// Non-null when the item is a sub-task; null when it is the habit.
  final String? subtaskId;

  /// True when this item is a sub-task (not the habit itself).
  bool get isSubtask => subtaskId != null;

  /// "Habit — Sub-task" for a sub-task, the habit title otherwise.
  String get displayLabel =>
      isSubtask ? '$habitTitle — $title' : title;
}

/// Sub-tasks of one habit that are due on [dateKey], in creation
/// order (daily first is NOT assumed — callers group by kind).
List<HabitSubtask> dueSubtasks(
  List<HabitSubtask> subtasks,
  String dateKey,
) => subtasks.where((s) => !s.archived && s.isDueOn(dateKey)).toList();

/// Whether a habit counts as done on a day.
///
/// - No sub-tasks due → the habit's own tick decides.
/// - Sub-tasks due → ALL of them must be done (the habit tick alone
///   does not count — the work is the sub-tasks).
bool habitIsDone({
  required List<HabitSubtask> due,
  required Set<String> doneSubtaskIds,
  required bool habitTicked,
}) {
  if (due.isEmpty) return habitTicked;
  return due.every((s) => doneSubtaskIds.contains(s.id));
}

/// Builds today's score items from the habits due today.
///
/// For each habit: when it has sub-tasks due today, one item per
/// sub-task; when it has none, one item for the habit itself.
/// [doneSubtaskIds] and [doneHabitIds] are the ids completed today.
List<ScoreItem> scoreItemsForToday({
  required List<Habit> habits,
  required Map<String, List<HabitSubtask>> dueByHabit,
  required Set<String> doneSubtaskIds,
  required Set<String> doneHabitIds,
}) {
  final items = <ScoreItem>[];
  for (final habit in habits) {
    final due = dueByHabit[habit.id] ?? const <HabitSubtask>[];
    if (due.isEmpty) {
      items.add(
        ScoreItem(
          habitId: habit.id,
          habitTitle: habit.title,
          title: habit.title,
          done: doneHabitIds.contains(habit.id),
        ),
      );
    } else {
      for (final sub in due) {
        items.add(
          ScoreItem(
            habitId: habit.id,
            habitTitle: habit.title,
            title: sub.title,
            done: doneSubtaskIds.contains(sub.id),
            subtaskId: sub.id,
          ),
        );
      }
    }
  }
  return items;
}

/// Score percent (0–100) for a list of score items. 0 items = 0%.
int scorePercent(List<ScoreItem> items) {
  if (items.isEmpty) return 0;
  final done = items.where((i) => i.done).length;
  return (done / items.length * 100).round();
}
