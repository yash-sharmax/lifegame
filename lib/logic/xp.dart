// Pure XP, level and streak rules for Life Game.
//
// These functions are deliberately free of any backend dependency so they
// can be unit-tested (see test/xp_test.dart).
//
// Rules (agreed with the user, 14 Nov 2026; final rule 18 Nov 2026):
// - XP is DERIVED, not accumulated: a habit/task is worth +2 XP while it
//   is ticked, and 0 while it is blank. Ticking grants +2; unticking
//   fully reverses that +2 (back to 0 for that item); re-ticking grants
//   +2 again. So repeated tick/untick nets 0 and can never farm XP.
//   There is NO -1 penalty, NO negative marking, and NO streak or
//   first-completion bonus — XP comes only from completed habits.
// - Streak = consecutive days (local calendar dates, Asia/Kolkata on the
//   user's device) with at least 1 habit completed.
// - Level = floor(total XP / 100) + 1. At 2 XP per task a level takes
//   50 completions. Progress to the next level is (XP % 100) / 100.
// - Rank: a named title for each level band, shown on profiles
//   and the leaderboard (18 Nov 2026).

/// XP granted for completing one habit or task.
const int xpPerTask = 2;
const int xpPerLevel = 100;

/// Warrior rank names, by level band. A warrior's title is how the
/// app talks about levels: "Level 4 Warrior", not just a number.
String rankNameForLevel(int level) {
  if (level <= 2) return 'Recruit';
  if (level <= 4) return 'Warrior';
  if (level <= 6) return 'Knight';
  if (level <= 8) return 'Champion';
  if (level <= 10) return 'Warlord';
  return 'Legend';
}

/// Rank name for a given total XP.
String rankNameForXp(int xp) => rankNameForLevel(levelForXp(xp));

/// XP delta for toggling an item: +2 on completing a pending item,
/// -2 on unticking a done item (the full reversal — the item is worth
/// 0 while blank, so unticking takes back exactly the +2 it granted),
/// 0 when nothing actually changes. Single source of truth for the
/// plus/minus rule — repositories and UI both use it so the stored XP
/// can never drift from the log. Repeated tick/untick nets 0.
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

// Day of the year, 1-based (Jan 1 = 1).
int dayOfYear([DateTime? date]) {
  final d = date ?? DateTime.now();
  return d.difference(DateTime(d.year, 1, 1)).inDays + 1;
}

// Days left in the year after today (365/366 - day of year).
int daysLeftInYear([DateTime? date]) {
  final d = date ?? DateTime.now();
  final daysInYear = DateTime(d.year + 1, 1, 1)
      .difference(DateTime(d.year, 1, 1))
      .inDays;
  return daysInYear - dayOfYear(d);
}

const _monthNames = [
  '',
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

// "November 2026" — the month header on the Dashboard calendar.
String monthName(DateTime date) => '${_monthNames[date.month]} ${date.year}';
