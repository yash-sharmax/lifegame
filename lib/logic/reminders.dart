// Pure reminder-time helpers (v2.3.0).
//
// Reminder times are stored as "HH:MM" (24-hour) strings. These helpers
// are backend-free so they can be unit-tested (see test/reminder_test.dart).
library;

/// A parsed "HH:MM" time of day.
typedef ReminderTime = ({int hour, int minute});

/// Parses "HH:MM" (24-hour). Returns null when the format is wrong or
/// the values are out of range.
ReminderTime? parseReminderTime(String value) {
  final parts = value.split(':');
  if (parts.length != 2) return null;
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return (hour: hour, minute: minute);
}

/// Formats an hour/minute pair as "HH:MM" (24-hour, zero-padded).
String formatReminderTime(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

/// Formats an hour/minute pair as 12-hour text, e.g. "7:30 AM".
String formatReminderTime12h(int hour, int minute) {
  final suffix = hour >= 12 ? 'PM' : 'AM';
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$h12:${minute.toString().padLeft(2, '0')} $suffix';
}

/// True when the reminder time has been reached at [now] (same day) and
/// it has not fired yet today ([lastFiredDateKey] is the YYYY-MM-DD of
/// the last fire, or null when it never fired).
///
/// The service ticks every 30 seconds, so "reached" means now is at or
/// after the scheduled time — a reminder set for a time that already
/// passed today still fires once (better late than never, and it will
/// not fire again today).
bool isReminderDueNow({
  required String time,
  required DateTime now,
  required String? lastFiredDateKey,
}) {
  final parsed = parseReminderTime(time);
  if (parsed == null) return false;
  final todayKey =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  if (lastFiredDateKey == todayKey) return false;
  final due = DateTime(now.year, now.month, now.day, parsed.hour, parsed.minute);
  return !now.isBefore(due);
}

/// Next wall-clock occurrence of [time] at or after [now] (today when
/// the time is still ahead, otherwise tomorrow). Used to schedule the
/// Android exact alarm.
DateTime nextOccurrence(String time, [DateTime? now]) {
  final current = now ?? DateTime.now();
  final parsed = parseReminderTime(time);
  if (parsed == null) return current;
  var next = DateTime(
    current.year,
    current.month,
    current.day,
    parsed.hour,
    parsed.minute,
  );
  if (next.isBefore(current)) {
    next = next.add(const Duration(days: 1));
  }
  return next;
}
