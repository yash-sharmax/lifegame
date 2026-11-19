// Natural-language reminder parser for the Reminders chat tab
// (v2.9.0, 18 Nov 2026).
//
// The user types a reminder in plain words — e.g. "Buy milk at 6pm"
// or "Call mom tomorrow at 7am" — and this parser pulls the date +
// time out of the message locally (no server, no AI call), returning
// the reminder text with the time/date part removed and the scheduled
// DateTime. v2.10.0: this parser is the OFFLINE fallback — when the
// app is online the AI parser (data/ai_reminder_parser.dart) runs
// first and this one is only used if it fails.
//
// Supported (Hinglish + English, deliberately forgiving):
// - Time: "at 6pm", "6pm", "at 6:00 pm", "6 baje", "18:00", "at 7 am".
//   v2.11.2: dot separators too ("3.08pm", "3.08"), and a bare time
//   with no am/pm infers AM/PM from the local time (afternoon +
//   hour 1–11 → PM); a past inferred time rolls to tomorrow
//   keeping the SAME period.
// - Day words: "kal" / "tomorrow" = tomorrow; "aaj" / "today" = today;
//   "parso" / "day after tomorrow" = day after tomorrow.
// - Part of day: "subah" / "morning" = AM; "shaam" / "sham" /
//   "evening" / "dopahar" / "afternoon" / "raat" / "night" = PM.
// - Dates: "24 Aug", "9 Nov", "24/8", "24-08"; day names "Monday",
//   "Somvar" (next occurrence of that weekday).
// - Default: no date given → today if that time is still ahead,
//   otherwise tomorrow.
//
// Pure functions, so they are unit-tested (test/chat_reminders_test.dart).
library;

/// A parsed reminder: the text to remind about, and when.
class ParsedReminder {
  const ParsedReminder({required this.text, required this.when});

  /// The message with the time/date part removed.
  final String text;

  /// The scheduled local date + time.
  final DateTime when;
}

/// Parses [message] into a [ParsedReminder], or null when no usable
/// time can be found in it. [now] is the reference moment (defaults
/// to DateTime.now()); tests pass a fixed one.
ParsedReminder? parseChatReminder(String message, [DateTime? now]) {
  final current = now ?? DateTime.now();
  final lower = message.toLowerCase();

  final time = _parseTime(lower);
  if (time == null) return null;
  var hour = time.hour;
  final minute = time.minute;

  // Part-of-day words adjust an ambiguous 12-hour time: "subah" /
  // "morning" force AM; evening/afternoon/night force PM. An explicit
  // am/pm in the time itself always wins.
  //
  // v2.11.2: a bare time (no am/pm, no part-of-day word) infers its
  // period from the user's local time — in the afternoon an hour
  // 1–11 means PM ("remind me to drink water at 3:09" at 3:09 PM
  // means 3:09 PM, not 3:09 AM). In the morning it means AM. The
  // inferred time then follows the usual rule below: today when it
  // is still ahead, otherwise tomorrow — keeping the SAME period
  // (PM stays PM, never silently becomes AM).
  if (!time.hasMeridiem) {
    if (_containsAny(lower, _morningWords)) {
      if (hour == 12) hour = 0;
      if (hour > 12) hour = hour % 12;
    } else if (_containsAny(lower, _eveningWords)) {
      if (hour < 12) hour += 12;
    } else if (current.hour >= 12) {
      // Afternoon / evening here: a bare 1–11 is PM.
      if (hour >= 1 && hour < 12) hour += 12;
    } else {
      // Morning here: a bare 1–11 is AM; bare 12 is midnight.
      if (hour == 12) hour = 0;
    }
  }

  // Date: an explicit date/day wins; else a day word; else today if
  // the time is still ahead, otherwise tomorrow.
  var day = _parseDate(lower, current);
  day ??= _parseDayWord(lower, current);
  day ??= _parseWeekday(lower, current);
  if (day == null) {
    final todayAt = DateTime(
      current.year,
      current.month,
      current.day,
      hour,
      minute,
    );
    day = todayAt.isAfter(current)
        ? DateTime(current.year, current.month, current.day)
        : DateTime(
            current.year,
            current.month,
            current.day,
          ).add(const Duration(days: 1));
  }

  final when = DateTime(day.year, day.month, day.day, hour, minute);
  final text = _stripTimeAndDate(message);
  if (text.isEmpty) return null;
  return ParsedReminder(text: text, when: when);
}

class _Time {
  const _Time({required this.hour, required this.minute, this.hasMeridiem = false});

  final int hour;
  final int minute;
  final bool hasMeridiem;
}

const _morningWords = ['subah', 'morning', 'savera'];
const _eveningWords = [
  'shaam',
  'sham',
  'evening',
  'dopahar',
  'afternoon',
  'raat',
  'night',
  'dopher',
];

bool _containsAny(String text, List<String> words) {
  for (final w in words) {
    if (text.contains(w)) return true;
  }
  return false;
}

/// Finds a time in [lower]: "at 6pm", "6:00 pm", "6 baje", "18:00",
/// "at 7 am", "3.08pm" (dot separator, v2.11.2). Returns the hour in
/// 24h form plus whether the period is already determined — either
/// by an explicit am/pm or because the time is 24-hour (hour > 12).
/// A 12-hour time with no am/pm has [hasMeridiem] false, so the
/// caller infers the period from the local time.
_Time? _parseTime(String lower) {
  // "6:30 pm" / "6:30pm" / "3.08pm" / "3.08 pm" / "at 6:30 pm" —
  // explicit am/pm, colon OR dot separator (v2.11.2: the dot form
  // used to match the bare-meridiem rule as "08pm" — hour 8).
  final dotMeridiem =
      RegExp(r'(\d{1,2})[.:](\d{2})\s*(am|pm)\b').firstMatch(lower);
  if (dotMeridiem != null) {
    var hour = int.parse(dotMeridiem.group(1)!);
    final minute = int.parse(dotMeridiem.group(2)!);
    if (hour < 1 || hour > 12 || minute > 59) return null;
    if (dotMeridiem.group(3) == 'pm' && hour != 12) hour += 12;
    if (dotMeridiem.group(3) == 'am' && hour == 12) hour = 0;
    return _Time(hour: hour, minute: minute, hasMeridiem: true);
  }
  // "6pm" / "6 pm" / "at 6pm".
  final meridiem = RegExp(r'(\d{1,2})\s*(am|pm)\b').firstMatch(lower);
  if (meridiem != null) {
    var hour = int.parse(meridiem.group(1)!);
    if (hour < 1 || hour > 12) return null;
    if (meridiem.group(2) == 'pm' && hour != 12) hour += 12;
    if (meridiem.group(2) == 'am' && hour == 12) hour = 0;
    return _Time(hour: hour, minute: 0, hasMeridiem: true);
  }
  // "18:00" / "6:30" / "3.08" (24-hour, or a bare 12-hour time —
  // the caller infers AM/PM from the local time when hour <= 12).
  final colon = RegExp(r'(\d{1,2})[.:](\d{2})\b').firstMatch(lower);
  if (colon != null) {
    final hour = int.parse(colon.group(1)!);
    final minute = int.parse(colon.group(2)!);
    if (hour > 23 || minute > 59) return null;
    return _Time(hour: hour, minute: minute, hasMeridiem: hour > 12);
  }
  // "6 baje" / "7 baje" — Hinglish.
  final baje = RegExp(r'(\d{1,2})\s*baje\b').firstMatch(lower);
  if (baje != null) {
    final hour = int.parse(baje.group(1)!);
    if (hour < 1 || hour > 12) return null;
    return _Time(hour: hour, minute: 0);
  }
  return null;
}

const _months = {
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

/// Explicit dates: "24 Aug", "9 Nov 2026", "24/8", "24-08".
/// A date in the past rolls to next year (a reminder is always in
/// the future).
DateTime? _parseDate(String lower, DateTime now) {
  final named = RegExp(
    r'(\d{1,2})\s*(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b(?:\s*(\d{4}))?',
  ).firstMatch(lower);
  if (named != null) {
    final day = int.parse(named.group(1)!);
    final month = _months[named.group(2)!]!;
    final year = named.group(3) != null
        ? int.parse(named.group(3)!)
        : now.year;
    if (day < 1 || day > 31) return null;
    var date = DateTime(year, month, day);
    // DateTime normalises an impossible day (e.g. 31 Feb → 3 Mar);
    // reject it instead of silently shifting.
    if (date.day != day || date.month != month) return null;
    if (named.group(3) == null && date.isBefore(
      DateTime(now.year, now.month, now.day),
    )) {
      date = DateTime(year + 1, month, day);
    }
    return date;
  }
  final numeric = RegExp(r'(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?').firstMatch(lower);
  if (numeric != null) {
    final day = int.parse(numeric.group(1)!);
    final month = int.parse(numeric.group(2)!);
    if (day < 1 || day > 31 || month < 1 || month > 12) return null;
    var year = now.year;
    if (numeric.group(3) != null) {
      year = int.parse(numeric.group(3)!);
      if (year < 100) year += 2000;
    }
    final date = DateTime(year, month, day);
    if (date.day != day || date.month != month) return null;
    if (numeric.group(3) == null &&
        date.isBefore(DateTime(now.year, now.month, now.day))) {
      return DateTime(year + 1, month, day);
    }
    return date;
  }
  return null;
}

/// Day words: "kal"/"tomorrow", "aaj"/"today", "parso"/"day after
/// tomorrow". "Kal" in Hinglish means tomorrow (not yesterday — the
/// reminder is always forward-looking).
DateTime? _parseDayWord(String lower, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  if (RegExp(r'\bparso\b').hasMatch(lower) ||
      lower.contains('day after tomorrow')) {
    return today.add(const Duration(days: 2));
  }
  if (RegExp(r'\bkal\b').hasMatch(lower) || lower.contains('tomorrow')) {
    return today.add(const Duration(days: 1));
  }
  if (RegExp(r'\baaj\b').hasMatch(lower) || lower.contains('today')) {
    return today;
  }
  return null;
}

const _weekdaysEn = {
  'monday': DateTime.monday,
  'tuesday': DateTime.tuesday,
  'wednesday': DateTime.wednesday,
  'thursday': DateTime.thursday,
  'friday': DateTime.friday,
  'saturday': DateTime.saturday,
  'sunday': DateTime.sunday,
};

const _weekdaysHi = {
  'somvar': DateTime.monday,
  'somvaar': DateTime.monday,
  'mangalvar': DateTime.tuesday,
  'mangalvaar': DateTime.tuesday,
  'budhvar': DateTime.wednesday,
  'budhvaar': DateTime.wednesday,
  'guruwar': DateTime.thursday,
  'guruvaar': DateTime.thursday,
  'shukravar': DateTime.friday,
  'shukravaar': DateTime.friday,
  'shanivar': DateTime.saturday,
  'shanivaar': DateTime.saturday,
  'ravivar': DateTime.sunday,
  'ravivaar': DateTime.sunday,
};

/// Weekday names: the NEXT occurrence of that weekday (today only
/// when the word is explicitly "today" — a bare weekday always means
/// the coming one, never today).
DateTime? _parseWeekday(String lower, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  for (final entry in {..._weekdaysEn, ..._weekdaysHi}.entries) {
    if (!RegExp('\\b${entry.key}\\b').hasMatch(lower)) continue;
    var daysAhead = (entry.value - now.weekday) % 7;
    if (daysAhead == 0) daysAhead = 7;
    return today.add(Duration(days: daysAhead));
  }
  return null;
}

/// The reminder text: the original message with the time/date/day
/// part removed, and leftover filler ("at", "ko", "please remind me")
/// tidied away.
String _stripTimeAndDate(String message) {
  var text = message;
  // Time expressions (with their "at"). Dot separators too
  // (v2.11.2): "at 3.08pm" used to leave "at 3." behind, which
  // truncated the task to "To drink water at 3."
  text = text.replaceAll(
    RegExp(r'\bat\s+\d{1,2}[.:]\d{2}\s*(am|pm)?\b', caseSensitive: false),
    ' ',
  );
  text = text.replaceAll(
    RegExp(r'\bat\s+\d{1,2}\s*(am|pm)\b', caseSensitive: false),
    ' ',
  );
  text = text.replaceAll(
    RegExp(r'\b\d{1,2}[.:]\d{2}\s*(am|pm)?\b', caseSensitive: false),
    ' ',
  );
  text = text.replaceAll(
    RegExp(r'\b\d{1,2}\s*(am|pm)\b', caseSensitive: false),
    ' ',
  );
  text = text.replaceAll(
    RegExp(r'\b\d{1,2}\s*baje\b', caseSensitive: false),
    ' ',
  );
  // Dates.
  text = text.replaceAll(
    RegExp(
      r'\b\d{1,2}\s*(jan|january|feb|february|mar|march|apr|april|may|jun|june|jul|july|aug|august|sep|sept|september|oct|october|nov|november|dec|december)\b(?:\s*\d{4})?',
      caseSensitive: false,
    ),
    ' ',
  );
  text = text.replaceAll(RegExp(r'\b\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?\b'), ' ');
  // Day words.
  text = text.replaceAll(
    RegExp(
      r'\b(kal|aaj|parso|today|tomorrow|day after tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|somvar|somvaar|mangalvar|mangalvaar|budhvar|budhvaar|guruwar|guruvaar|shukravar|shukravaar|shanivar|shanivaar|ravivar|ravivaar)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  // Part-of-day words ("subah", "shaam") and the time particles
  // ("ko", "pe", "par") — they belong to the time, not the reminder.
  text = text.replaceAll(
    RegExp(
      r'\b(subah|morning|savera|shaam|sham|evening|dopahar|dopher|afternoon|raat|night)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  text = text.replaceAll(RegExp(r'\b(ko|pe|par)\b'), ' ');
  // Leftover filler.
  text = text.replaceAll(
    RegExp(
      r'\b(please\s+)?(remind me|yaad dilao|yaad dila do|yaad dilana|remind|yaad)\b',
      caseSensitive: false,
    ),
    ' ',
  );
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  // Drop a trailing "at" / "ko" / "pe" left behind by the removals,
  // and a leading "to" ("remind me to drink water" → "Drink water",
  // not "To drink water").
  text = text.replaceAll(RegExp(r'\s+(at|ko|pe|par)\s*$'), '').trim();
  text = text.replaceFirst(RegExp(r'^to\s+', caseSensitive: false), '');
  // Capitalise the first letter for display.
  if (text.isEmpty) return text;
  return text[0].toUpperCase() + text.substring(1);
}

/// "Mon, Aug 24, 2026 at 6:00 PM" — the confirmation line the chat
/// shows after a reminder is set (same shape as the Nevermiss bot).
String formatReminderConfirmation(DateTime when, String text) {
  const weekdays = [
    '',
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  const months = [
    '',
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour12 = when.hour % 12 == 0 ? 12 : when.hour % 12;
  final suffix = when.hour >= 12 ? 'PM' : 'AM';
  final minute = when.minute.toString().padLeft(2, '0');
  return 'Reminder set for ${weekdays[when.weekday]}, '
      '${months[when.month]} ${when.day}, ${when.year} '
      'at $hour12:$minute $suffix: $text';
}

// ---------------------------------------------------------------------------
// v2.11.2 — corrections, ambiguity, and "no clear task".
// ---------------------------------------------------------------------------

/// Correction openers: the user is fixing the reminder that was
/// just set, not asking for a new one ("not 8 it's 3:08pm", "no,
/// I meant 4pm", "actually tomorrow at 9").
const _correctionOpeners = [
  'not ',
  'not,',
  'no ',
  'no,',
  'nope',
  'nope,',
  'i meant',
  'i mean ',
  'actually',
  'correction',
  'wrong ',
  'sorry ',
];

/// True when [message] reads like a correction of the reminder
/// that was just created (v2.11.2). The caller then EDITS the last
/// reminder instead of creating a new one. A correction opener on
/// its own ("not now") is not a correction — it must also carry a
/// time (a digit), or there is nothing to correct the reminder to.
bool looksLikeCorrection(String message) {
  final lower = message.trim().toLowerCase();
  if (!RegExp(r'\d').hasMatch(lower)) return false;
  for (final opener in _correctionOpeners) {
    if (lower.startsWith(opener)) return true;
  }
  // "it's 3:08pm" / "it is 4pm" on its own also corrects the time.
  if (RegExp(r"^it'?s\s+\d").hasMatch(lower)) return true;
  if (RegExp(r'^it is\s+\d').hasMatch(lower)) return true;
  return false;
}

/// The task text a correction carries, if any: the message with the
/// correction opener, the wrong time reference, and the new time
/// removed. Empty when the correction only fixes the time ("not 8
/// it's 3:08pm" → "" — the old task stays).
String correctionTaskText(String message) {
  var text = message.trim();
  // Repeatedly drop leading correction openers and stray
  // punctuation ("no, I meant call mom at 4pm" → "call mom at
  // 4pm"; "not 8 it's 3:08pm" → "it's 3:08pm").
  var changed = true;
  while (changed) {
    changed = false;
    final lower = text.toLowerCase();
    for (final opener in _correctionOpeners) {
      if (lower.startsWith(opener)) {
        text = text.substring(opener.length).trim();
        changed = true;
        break;
      }
    }
    if (!changed) {
      final stripped = text.replaceFirst(RegExp(r'^[,\s:;]+'), '').trim();
      if (stripped != text) {
        text = stripped;
        changed = true;
      }
    }
  }
  // A bare number left over is the WRONG hour ("not 8 it's 3:08pm"
  // → "8 it's 3:08pm" → "it's 3:08pm") — drop it first.
  text = text.replaceFirst(RegExp(r'^\d{1,2}[,\s:]*'), '');
  // "it's 3:08pm" / "it is 4pm" — drop the "it's" too.
  text = text.replaceFirst(
    RegExp(r"^it'?s\s+", caseSensitive: false),
    '',
  );
  text = text.replaceFirst(
    RegExp(r'^it is\s+', caseSensitive: false),
    '',
  );
  final stripped = _stripTimeAndDate(text);
  return stripped.trim();
}

/// True when the parse had to GUESS something: the message gave no
/// explicit date/day word AND no explicit am/pm, so the period was
/// inferred from the local time (v2.11.2). The confirmation bubble
/// shows the "include a date/day" tip only then — never on a
/// successful, unambiguous set.
bool reminderParseWasAmbiguous(String message) {
  final lower = message.toLowerCase();
  final now = DateTime.now();
  final hasDateOrDay =
      _parseDate(lower, now) != null ||
      _parseDayWord(lower, now) != null ||
      _parseWeekday(lower, now) != null;
  if (hasDateOrDay) return false;
  final hasMeridiem = RegExp(r'\d\s*(am|pm)\b').hasMatch(lower);
  return !hasMeridiem;
}

/// True when [text] (already stripped of its time/date part) names
/// an actual task: at least one word with letters in it. "5" or
/// "" is not a task — the caller asks for clarification instead of
/// creating a garbage reminder (v2.11.2).
bool hasClearTask(String text) {
  return RegExp(r'[A-Za-z]{2,}').hasMatch(text.trim());
}
