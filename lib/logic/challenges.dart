// Pure challenge rules (v2.3.0).
//
// A challenge is created on a date, then has a 3-day setup window in
// which its habits can still be added, removed or renamed. After those
// 3 days the habits LOCK for the whole challenge duration — no changes
// inside the challenge while it runs. The challenge itself runs for
// [durationDays] starting the day after the setup window ends:
//
//   created  ── 3 setup days ──► start ── durationDays ──► end
//
// Daily (non-challenge) habits stay fully flexible: they can be added
// or removed any time, challenge or not.
//
// Challenge XP is NOT a second XP system: it is the sum of `xpEarned`
// on the existing habit logs for the challenge's habits inside the
// active window [startDate, endDate].
//
// All date keys are 'YYYY-MM-DD' in the device's local calendar (same
// convention as lib/logic/xp.dart). These functions are backend-free
// so they can be unit-tested (see test/challenge_test.dart).
library;

import '../data/models.dart';
import 'xp.dart';

/// Days after creation during which challenge habits can still change.
const int challengeSetupWindowDays = 3;

/// Allowed preset durations (days) offered in the create sheet.
const List<int> challengeDurationOptions = [7, 14, 21, 30];

/// Adds [days] to a 'YYYY-MM-DD' date key.
String addDaysToKey(String key, int days) {
  final d = DateTime.parse(key).add(Duration(days: days));
  return dateKey(d);
}

/// Whole days from [fromKey] to [toKey] (negative when [toKey] is earlier).
int daysBetweenKeys(String fromKey, String toKey) {
  final from = DateTime.parse(fromKey);
  final to = DateTime.parse(toKey);
  return to.difference(from).inDays;
}

/// First active day of the challenge: the day after the setup window.
String challengeStartDate(String createdDate) =>
    addDaysToKey(createdDate, challengeSetupWindowDays);

/// Last active day of the challenge (inclusive).
String challengeEndDate(String createdDate, int durationDays) =>
    addDaysToKey(challengeStartDate(createdDate), durationDays - 1);

/// Last day habits can still be edited (inclusive).
String challengeSetupEndDate(String createdDate) =>
    addDaysToKey(createdDate, challengeSetupWindowDays - 1);

enum ChallengePhase { setup, active, finished }

/// Phase of a challenge on [now] (defaults to today).
ChallengePhase challengePhase({
  required String createdDate,
  required int durationDays,
  DateTime? now,
}) {
  final today = todayKey(now);
  if (today.compareTo(challengeStartDate(createdDate)) < 0) {
    return ChallengePhase.setup;
  }
  if (today.compareTo(challengeEndDate(createdDate, durationDays)) > 0) {
    return ChallengePhase.finished;
  }
  return ChallengePhase.active;
}

/// True when the challenge's habits are locked (setup window over).
bool challengeHabitsLocked({required String createdDate, DateTime? now}) =>
    todayKey(now).compareTo(challengeStartDate(createdDate)) >= 0;

/// Days left in the active window, counting today. 0 when finished.
/// During setup this returns the full duration (the challenge has not
/// started yet).
int challengeDaysRemaining({
  required String createdDate,
  required int durationDays,
  DateTime? now,
}) {
  final today = todayKey(now);
  final end = challengeEndDate(createdDate, durationDays);
  if (today.compareTo(end) > 0) return 0;
  final start = challengeStartDate(createdDate);
  if (today.compareTo(start) < 0) return durationDays;
  return daysBetweenKeys(today, end) + 1;
}

/// Fraction (0.0–1.0) of the active window that has elapsed. 0 during
/// setup, 1 when finished.
double challengeProgress({
  required String createdDate,
  required int durationDays,
  DateTime? now,
}) {
  final today = todayKey(now);
  final start = challengeStartDate(createdDate);
  final end = challengeEndDate(createdDate, durationDays);
  if (today.compareTo(start) < 0) return 0;
  if (today.compareTo(end) > 0) return 1;
  final elapsed = daysBetweenKeys(start, today) + 1;
  return (elapsed / durationDays).clamp(0.0, 1.0);
}

/// XP earned on the challenge's habits inside the active window, from
/// the existing habit logs (no second XP system).
int challengeXpFromLogs({
  required List<HabitLog> logs,
  required Set<String> habitIds,
  required String startDate,
  required String endDate,
}) {
  var xp = 0;
  for (final log in logs) {
    if (!log.completed) continue;
    if (!habitIds.contains(log.habitId)) continue;
    if (log.logDate.compareTo(startDate) < 0) continue;
    if (log.logDate.compareTo(endDate) > 0) continue;
    xp += log.xpEarned;
  }
  return xp;
}

/// Consecutive days inside the active window (walking back from today,
/// or from the end date when the challenge is over) with at least one
/// locked habit completed. 0 when nothing is done yet.
int challengeStreak({
  required List<HabitLog> logs,
  required Set<String> habitIds,
  required String startDate,
  required String endDate,
  DateTime? now,
}) {
  final activeDates = <String>{};
  for (final log in logs) {
    if (!log.completed) continue;
    if (!habitIds.contains(log.habitId)) continue;
    if (log.logDate.compareTo(startDate) < 0) continue;
    if (log.logDate.compareTo(endDate) > 0) continue;
    activeDates.add(log.logDate);
  }
  if (activeDates.isEmpty) return 0;
  var cursor = DateTime.parse(todayKey(now));
  final end = DateTime.parse(endDate);
  if (cursor.isAfter(end)) cursor = end;
  if (!activeDates.contains(dateKey(cursor))) {
    cursor = cursor.subtract(const Duration(days: 1));
  }
  var streak = 0;
  final start = DateTime.parse(startDate);
  while (!cursor.isBefore(start) && activeDates.contains(dateKey(cursor))) {
    streak++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return streak;
}
