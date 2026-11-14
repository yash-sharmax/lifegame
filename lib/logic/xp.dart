// Pure XP, level and streak rules for Life Game.
//
// These functions are deliberately free of any backend dependency so they
// can be unit-tested (see test/xp_test.dart).
//
// Rules (agreed with the user, 14 Nov 2026):
// - +2 XP for every habit/task completion, and -2 XP when a completed
//   item is unticked again (never below 0). No daily-complete bonus.
// - Streak = consecutive days (local calendar dates, Asia/Kolkata on the
//   user's device) with at least 1 habit completed.
// - Level = floor(total XP / 100) + 1. At 2 XP per task a level takes
//   50 completions. Progress to the next level is (XP % 100) / 100.

/// XP granted for completing one habit or task (and removed on untick).
const int xpPerTask = 2;
const int xpPerLevel = 100;

/// XP delta for toggling an item: +2 on completing a pending item,
/// -2 on unticking a done item, 0 when nothing actually changes.
/// Single source of truth for the plus/minus rule — repositories and
/// UI both use it so the stored XP can never drift from the log.
int xpDeltaForToggle({required bool completing, required bool wasDone}) {
  if (completing && !wasDone) return xpPerTask;
  if (!completing && wasDone) return -xpPerTask;
  return 0;
}

// Level for a given total XP. Level 1 starts at 0 XP.
int levelForXp(int xp) => xp ~/ xpPerLevel + 1;

// Fraction (0.0–1.0) of the way to the next level.
double progressToNextLevel(int xp) => (xp % xpPerLevel) / xpPerLevel;

// XP still needed to reach the next level.
int xpToNextLevel(int xp) => xpPerLevel - (xp % xpPerLevel);

String _twoDigits(int n) => n.toString().padLeft(2, '0');

// Local calendar date as 'YYYY-MM-DD'.
String dateKey(DateTime date) =>
    '${date.year}-${_twoDigits(date.month)}-${_twoDigits(date.day)}';

// Today's local date key.
String todayKey([DateTime? now]) => dateKey(now ?? DateTime.now());

// Yesterday's local date key.
String yesterdayKey([DateTime? now]) {
  final d = now ?? DateTime.now();
  return dateKey(d.subtract(const Duration(days: 1)));
}

// New streak after completing at least one habit today.
//
// - lastActiveDate == today     → streak is unchanged.
// - lastActiveDate == yesterday → streak + 1.
// - otherwise (gap, or never)   → streak restarts at 1.
int streakAfterTick({
  required int currentStreak,
  required String? lastActiveDate,
  required String today,
}) {
  if (lastActiveDate == today) return currentStreak;
  if (lastActiveDate == yesterdayKey(DateTime.parse(today))) {
    return currentStreak + 1;
  }
  return 1;
}

// Current streak from a set of active date keys.
//
// Walks backwards from today: if today is not active yet, the streak is
// counted from yesterday (so the flame does not die the moment a new day
// starts). Returns 0 when there is no active day in the chain.
int computeStreak(Set<String> activeDates, [DateTime? now]) {
  final today = now ?? DateTime.now();
  var cursor = today;
  if (!activeDates.contains(dateKey(cursor))) {
    cursor = cursor.subtract(const Duration(days: 1));
  }
  var streak = 0;
  while (activeDates.contains(dateKey(cursor))) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return streak;
}

// Monday of the week containing [date], as a date key.
String weekStartKey([DateTime? date]) {
  final d = date ?? DateTime.now();
  final monday = d.subtract(Duration(days: d.weekday - 1));
  return dateKey(monday);
}

// Current month as 'YYYY-MM'.
String monthKey([DateTime? date]) {
  final d = date ?? DateTime.now();
  return '${d.year}-${_twoDigits(d.month)}';
}
