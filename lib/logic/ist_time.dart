// Asia/Kolkata wall-clock helpers (v2.11.3).
//
// The app's dates, streaks and reminders are all Asia/Kolkata.
// The user's phone is IST — but the code must NOT depend on the
// device timezone: a browser running in UTC (the retest device)
// parsed a bare "3:55" as 03:55 UTC and set the reminder for
// tomorrow 3:55 AM, even though it was 3:53 PM IST. Every
// reminder time in the app is therefore stored, compared and
// displayed in this frame: IST wall-clock fields.
//
// IST has no daylight saving, so the offset is a constant +05:30
// — no tz database lookup is needed (and none is available in
// pure logic / unit tests). A "naive" DateTime whose fields are
// IST is the app's reminder-time type; [istNow] is its "now".
library;

/// Asia/Kolkata is UTC+05:30, all year, no daylight saving.
const Duration kIstOffset = Duration(hours: 5, minutes: 30);

/// "Now" as an Asia/Kolkata wall-clock reading: a naive DateTime
/// whose fields are IST (year/month/day/hour/minute). Use this —
/// never [DateTime.now] — anywhere a reminder time is parsed,
/// compared, displayed or fired.
///
/// Naive on purpose: the whole reminder subsystem compares
/// FIELD values in the IST frame. A UTC-flagged value would
/// compare by instant and be 5:30 off against the naive
/// DateTimes the parser and storage produce.
DateTime istNow() {
  final u = DateTime.now().toUtc().add(kIstOffset);
  return DateTime(
    u.year,
    u.month,
    u.day,
    u.hour,
    u.minute,
    u.second,
    u.millisecond,
    u.microsecond,
  );
}

/// Converts an absolute instant (a UTC DateTime, e.g. parsed from
/// the parse-reminder Function's Z-suffixed ISO string) to IST
/// wall-clock fields, as a naive DateTime.
DateTime istFromUtc(DateTime utc) {
  final u = utc.toUtc().add(kIstOffset);
  return DateTime(
    u.year,
    u.month,
    u.day,
    u.hour,
    u.minute,
    u.second,
    u.millisecond,
    u.microsecond,
  );
}

/// Converts IST wall-clock fields back to the absolute UTC instant
/// (for Android exact alarms, which schedule instants).
DateTime utcFromIst(DateTime istWall) => DateTime.utc(
  istWall.year,
  istWall.month,
  istWall.day,
  istWall.hour,
  istWall.minute,
  istWall.second,
  istWall.millisecond,
).subtract(kIstOffset);

/// An IST wall-clock reading as an ISO 8601 string with an
/// explicit +05:30 offset, so a reader (the parse-reminder
/// Function's "current time" reference) cannot mistake it for
/// UTC or device-local time.
String istIso8601(DateTime istWall) {
  final iso = istWall.toIso8601String();
  return '$iso+05:30';
}

/// The current IST moment as an ISO 8601 string with +05:30.
String istNowIso() => istIso8601(istNow());
