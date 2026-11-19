/// Data models mirroring the Appwrite collections (see APPWRITE.md).
///
/// Field names are camelCase, matching the document attributes.
/// `createdAt` comes from Appwrite's system `$createdAt` field (an ISO
/// string); `fromJson` also accepts a plain `createdAt` string so tests
/// can pass plain maps.
library;

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// createdAt from an Appwrite document: system `$createdAt` first.
DateTime? _createdAt(Map<String, dynamic> json) =>
    _parseDate(json[r'$createdAt'] ?? json['createdAt']);

class Profile {
  const Profile({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.bio = '',
    this.xp = 0,
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.lastActiveDate,
    this.createdAt,
    this.visibility = 'public',
    this.discoverable = true,
    this.publicKey,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    username: json['username'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
    avatarUrl: json['avatarUrl'] as String?,
    bio: json['bio'] as String? ?? '',
    xp: (json['xp'] as num?)?.toInt() ?? 0,
    currentStreak: (json['currentStreak'] as num?)?.toInt() ?? 0,
    longestStreak: (json['longestStreak'] as num?)?.toInt() ?? 0,
    lastActiveDate: json['lastActiveDate'] as String?,
    createdAt: _createdAt(json),
    // v2.9.0: null-safe — the attributes are being added to the live
    // table in parallel; a row written before they existed reads as
    // the default (public + discoverable).
    visibility: json['visibility'] as String? ?? 'public',
    discoverable: json['discoverable'] as bool? ?? true,
    // v2.11.0: RSA public key for end-to-end encrypted messages.
    // Null-safe — the attribute is being added to the live table in
    // parallel; a user without one just cannot receive E2EE yet.
    publicKey: json['publicKey'] as String?,
  );

  /// The document fields for a brand-new profile (XP starts at 0).
  /// `createdAt` is Appwrite's system `$createdAt` — never sent by us.
  Map<String, dynamic> toMap() => {
    'username': username,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'bio': bio,
    'xp': xp,
    'currentStreak': currentStreak,
    'longestStreak': longestStreak,
    'lastActiveDate': lastActiveDate,
    'visibility': visibility,
    'discoverable': discoverable,
    'publicKey': publicKey,
  };

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String bio;
  final int xp;
  final int currentStreak;
  final int longestStreak;
  final String? lastActiveDate;
  final DateTime? createdAt;

  /// 'public' or 'private' (v2.9.0). Public: anyone can see my habits
  /// on my profile. Private: only mutual friends can.
  final String visibility;

  /// False hides me from the Leaderboard and Search (v2.9.0). People
  /// who already follow me, or open my profile directly, can still
  /// see it (subject to [visibility]).
  final bool discoverable;

  /// My RSA public key for end-to-end encrypted messages (v2.11.0).
  /// Public by design — anyone may use it to encrypt a message to
  /// me. Null until I open Chats for the first time.
  final String? publicKey;

  /// True when other users may see my habits on my profile.
  bool get isPublic => visibility != 'private';

  String get initials {
    final source = displayName.isNotEmpty ? displayName : username;
    final parts = source
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    String firstChar(String s) =>
        s.isEmpty ? '' : String.fromCharCode(s.runes.first);
    if (parts.length == 1) {
      final p = parts.first;
      return p.length >= 2 ? p.substring(0, 2).toUpperCase() : p.toUpperCase();
    }
    return (firstChar(parts.first) + firstChar(parts.last)).toUpperCase();
  }

  Profile copyWith({
    int? xp,
    int? currentStreak,
    int? longestStreak,
    String? lastActiveDate,
    String? displayName,
    String? bio,
    String? visibility,
    bool? discoverable,
    String? publicKey,
  }) => Profile(
    id: id,
    username: username,
    displayName: displayName ?? this.displayName,
    avatarUrl: avatarUrl,
    bio: bio ?? this.bio,
    xp: xp ?? this.xp,
    currentStreak: currentStreak ?? this.currentStreak,
    longestStreak: longestStreak ?? this.longestStreak,
    lastActiveDate: lastActiveDate ?? this.lastActiveDate,
    createdAt: createdAt,
    visibility: visibility ?? this.visibility,
    discoverable: discoverable ?? this.discoverable,
    publicKey: publicKey ?? this.publicKey,
  );
}

class Habit {
  const Habit({
    required this.id,
    required this.userId,
    required this.title,
    this.color = 0xFFF59E0B,
    this.archived = false,
    this.notes = '',
    this.createdAt,
  });

  factory Habit.fromJson(Map<String, dynamic> json) => Habit(
    id: json['id'] as String,
    userId: json['ownerUid'] as String,
    title: json['title'] as String,
    color: (json['color'] as num?)?.toInt() ?? 0xFFF59E0B,
    archived: json['archived'] as bool? ?? false,
    notes: json['notes'] as String? ?? '',
    createdAt: _createdAt(json),
  );

  /// `createdAt` is Appwrite's system `$createdAt` — never sent by us.
  /// `notes` is NOT in toMap: the live `habits` table has no `notes`
  /// attribute yet (it is defined in scripts/setup_appwrite.mjs for a
  /// future re-run), so sending it on create would fail. Notes are
  /// written through HabitRepository.updateHabit, which falls back to
  /// on-device storage when the attribute is missing (see there).
  Map<String, dynamic> toMap(String userId) => {
    'ownerUid': userId,
    'title': title,
    'color': color,
    'archived': archived,
  };

  /// Local-cache JSON (v2.9.0 offline-first): the full habit,
  /// including id + notes, so the app can show it with no network.
  Map<String, dynamic> toLocalJson() => {
    'id': id,
    'ownerUid': userId,
    'title': title,
    'color': color,
    'archived': archived,
    'notes': notes,
  };

  factory Habit.fromLocalJson(Map<String, dynamic> json) => Habit(
    id: json['id'] as String,
    userId: json['ownerUid'] as String? ?? '',
    title: json['title'] as String? ?? '',
    color: (json['color'] as num?)?.toInt() ?? 0xFFF59E0B,
    archived: json['archived'] as bool? ?? false,
    notes: json['notes'] as String? ?? '',
  );

  final String id;
  final String userId;
  final String title;
  final int color;
  final bool archived;

  /// Free-text notes about this habit (18 Nov 2026). Shown as a small
  /// indicator on habit rows; edited in the habit edit dialog.
  final String notes;
  final DateTime? createdAt;

  Habit copyWith({String? title, int? color, bool? archived, String? notes}) =>
      Habit(
        id: id,
        userId: userId,
        title: title ?? this.title,
        color: color ?? this.color,
        archived: archived ?? this.archived,
        notes: notes ?? this.notes,
        createdAt: createdAt,
      );
}

class HabitLog {
  const HabitLog({
    required this.id,
    required this.habitId,
    required this.userId,
    required this.logDate,
    this.completed = true,
    this.xpEarned = 0,
  });

  factory HabitLog.fromJson(Map<String, dynamic> json) => HabitLog(
    id: json['id'] as String,
    habitId: json['habitId'] as String,
    userId: json['ownerUid'] as String,
    logDate: json['date'] as String,
    completed: json['completed'] as bool? ?? true,
    xpEarned: (json['xpEarned'] as num?)?.toInt() ?? 0,
  );

  /// Local-cache JSON (v2.9.0 offline-first). Round-trips through
  /// fromJson: the same keys the server document carries.
  Map<String, dynamic> toLocalJson() => {
    'id': id,
    'habitId': habitId,
    'ownerUid': userId,
    'date': logDate,
    'completed': completed,
    'xpEarned': xpEarned,
  };

  final String id;
  final String habitId;
  final String userId;
  final String logDate;
  final bool completed;
  final int xpEarned;
}

/// One sub-task inside a habit (v2.8.0, 18 Nov 2026): a habit can be
/// broken into smaller steps. Stored in the `habit_subtasks` table
/// (see scripts/setup_appwrite.mjs); completion per day lives in
/// `subtask_logs` (one row per sub-task per day, like habit_logs).
class HabitSubtask {
  const HabitSubtask({
    required this.id,
    required this.habitId,
    required this.title,
    required this.kind,
    required this.date,
    this.archived = false,
  });

  /// Recurs every day, due from its creation date onward.
  static const String kindDaily = 'daily';

  /// Only for one day: due on [date] and gone after that.
  static const String kindToday = 'today';

  factory HabitSubtask.fromJson(Map<String, dynamic> json) => HabitSubtask(
    id: json['id'] as String,
    habitId: json['habitId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    kind: json['kind'] as String? ?? kindDaily,
    date: json['date'] as String? ?? '',
    archived: json['archived'] as bool? ?? false,
  );

  /// The Appwrite document fields. The table has no ownerUid — rows
  /// are owner-only through row permissions, like habit_logs.
  Map<String, dynamic> toMap() => {
    'habitId': habitId,
    'title': title,
    'kind': kind,
    'date': date,
    'archived': archived,
  };

  /// Local-store JSON: the same fields plus the owner id, so sign-out
  /// can clear one account's sub-tasks (Appwrite never sees it).
  Map<String, dynamic> toJson(String ownerId) => {
    'id': id,
    'ownerId': ownerId,
    ...toMap(),
  };

  /// Due on [dateKey] ('YYYY-MM-DD'): a daily sub-task is due every
  /// day from its creation date onward; a today sub-task only on its
  /// own date. An empty date (legacy) counts as due.
  bool isDueOn(String dateKey) {
    if (kind == kindToday) return date == dateKey;
    if (date.isEmpty) return true;
    return date.compareTo(dateKey) <= 0;
  }

  HabitSubtask copyWith({String? title, bool? archived}) => HabitSubtask(
    id: id,
    habitId: habitId,
    title: title ?? this.title,
    kind: kind,
    date: date,
    archived: archived ?? this.archived,
  );

  final String id;
  final String habitId;
  final String title;

  /// 'daily' or 'today' (see [kindDaily] / [kindToday]).
  final String kind;

  /// For 'today': the date it applies to. For 'daily': the creation
  /// date. Always 'YYYY-MM-DD'.
  final String date;
  final bool archived;
}

/// One sub-task's completion for one day (v2.8.0). The document id is
/// `{subtaskId}_{date}`, so a retried tick can never duplicate it —
/// the same idempotency trick as habit_logs.
class SubtaskLog {
  const SubtaskLog({
    required this.id,
    required this.subtaskId,
    required this.date,
    this.completed = true,
  });

  factory SubtaskLog.fromJson(Map<String, dynamic> json) => SubtaskLog(
    id: json['id'] as String,
    subtaskId: json['subtaskId'] as String? ?? '',
    date: json['date'] as String? ?? '',
    completed: json['completed'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'subtaskId': subtaskId,
    'date': date,
    'completed': completed,
  };

  final String id;
  final String subtaskId;
  final String date;
  final bool completed;
}

class WeeklyTask {
  const WeeklyTask({
    required this.id,
    required this.userId,
    required this.title,
    required this.weekStart,
    this.done = false,
  });
  factory WeeklyTask.fromJson(Map<String, dynamic> json) => WeeklyTask(
    id: json['id'] as String,
    userId: json['ownerUid'] as String,
    title: json['title'] as String,
    weekStart: json['weekStart'] as String,
    done: json['done'] as bool? ?? false,
  );

  /// Local-cache JSON (v2.9.0 offline-first).
  Map<String, dynamic> toLocalJson() => {
    'id': id,
    'ownerUid': userId,
    'title': title,
    'weekStart': weekStart,
    'done': done,
  };

  factory WeeklyTask.fromLocalJson(Map<String, dynamic> json) =>
      WeeklyTask.fromJson(json);

  final String id;
  final String userId;
  final String title;
  final String weekStart;
  final bool done;
}

class MonthlyTask {
  const MonthlyTask({
    required this.id,
    required this.userId,
    required this.title,
    required this.month,
    this.done = false,
  });

  factory MonthlyTask.fromJson(Map<String, dynamic> json) => MonthlyTask(
    id: json['id'] as String,
    userId: json['ownerUid'] as String,
    title: json['title'] as String,
    month: json['month'] as String,
    done: json['done'] as bool? ?? false,
  );

  /// Local-cache JSON (v2.9.0 offline-first).
  Map<String, dynamic> toLocalJson() => {
    'id': id,
    'ownerUid': userId,
    'title': title,
    'month': month,
    'done': done,
  };

  factory MonthlyTask.fromLocalJson(Map<String, dynamic> json) =>
      MonthlyTask.fromJson(json);

  final String id;
  final String userId;
  final String title;
  final String month;
  final bool done;
}

/// A leaderboard row: a public profile plus its global rank.
class LeaderboardEntry {
  const LeaderboardEntry({required this.profile, required this.rank});

  final Profile profile;
  final int rank;
}

/// One feedback message a user sent from Profile → Support.
/// Stored in the `feedback` table (see APPWRITE.md).
class FeedbackEntry {
  const FeedbackEntry({
    required this.id,
    required this.userId,
    required this.text,
    this.createdAt,
  });

  factory FeedbackEntry.fromJson(Map<String, dynamic> json) => FeedbackEntry(
    id: json['id'] as String,
    userId: json['userId'] as String? ?? '',
    text: json['text'] as String? ?? '',
    createdAt: _parseDate(json['createdAt'] ?? json[r'$createdAt']),
  );

  final String id;
  final String userId;
  final String text;
  final DateTime? createdAt;
}

// ---------------------------------------------------------------------------
// v2.3.0: reminders + challenges.
//
// These live in LOCAL storage (SharedPreferences) for now — the Appwrite
// tables are defined in scripts/setup_appwrite.mjs but the API key is
// not available to this environment, so the tables could not be created
// yet. The models carry the same shape the tables will have, so the
// repositories can move to Appwrite later without changing the UI.
// See APPWRITE.md ("v2.3.0 — local fallback").
// ---------------------------------------------------------------------------

/// One reminder: a time of day attached to a habit or a weekly/monthly
/// task. One reminder per target — the id is derived from kind+targetId
/// so saving twice updates instead of duplicating.
class Reminder {
  const Reminder({
    required this.id,
    required this.ownerId,
    required this.kind,
    required this.targetId,
    required this.title,
    required this.hour,
    required this.minute,
    this.enabled = true,
  });

  /// Deterministic id: one reminder per target item.
  static String idFor(String kind, String targetId) => '${kind}_$targetId';

  factory Reminder.fromJson(Map<String, dynamic> json) => Reminder(
    id: json['id'] as String,
    ownerId: json['ownerId'] as String? ?? '',
    kind: json['kind'] as String? ?? 'habit',
    targetId: json['targetId'] as String? ?? '',
    title: json['title'] as String? ?? '',
    hour: (json['hour'] as num?)?.toInt() ?? 0,
    minute: (json['minute'] as num?)?.toInt() ?? 0,
    enabled: json['enabled'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ownerId': ownerId,
    'kind': kind,
    'targetId': targetId,
    'title': title,
    'hour': hour,
    'minute': minute,
    'enabled': enabled,
  };

  /// "HH:MM" (24-hour).
  String get timeKey =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  Reminder copyWith({int? hour, int? minute, bool? enabled, String? title}) =>
      Reminder(
        id: id,
        ownerId: ownerId,
        kind: kind,
        targetId: targetId,
        title: title ?? this.title,
        hour: hour ?? this.hour,
        minute: minute ?? this.minute,
        enabled: enabled ?? this.enabled,
      );

  final String id;
  final String ownerId;

  /// 'habit' | 'weekly' | 'monthly'.
  final String kind;
  final String targetId;

  /// Snapshot of the item's title (shown in the reminder itself).
  final String title;
  final int hour;
  final int minute;
  final bool enabled;
}

/// One habit inside a challenge, with its title snapshotted at the
/// moment it was added — the challenge keeps showing the name even if
/// the habit itself is later renamed or deleted.
class ChallengeHabitEntry {
  const ChallengeHabitEntry({required this.habitId, required this.title});

  factory ChallengeHabitEntry.fromJson(Map<String, dynamic> json) =>
      ChallengeHabitEntry(
        habitId: json['habitId'] as String? ?? '',
        title: json['title'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'habitId': habitId, 'title': title};

  final String habitId;
  final String title;
}

/// A challenge: a named, time-boxed commitment over a fixed set of
/// habits. Habits can change during the 3-day setup window after
/// creation, then lock for the whole challenge duration (see
/// logic/challenges.dart). Check-ins reuse the normal habit toggles —
/// challenge XP is computed from the existing habit logs, never from
/// a second XP system.
class Challenge {
  const Challenge({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.createdDate,
    required this.durationDays,
    this.habits = const [],
    this.memberIds = const [],
  });

  factory Challenge.fromJson(Map<String, dynamic> json) => Challenge(
    id: json['id'] as String,
    ownerId: json['ownerId'] as String? ?? '',
    name: json['name'] as String? ?? '',
    createdDate: json['createdDate'] as String? ?? '',
    durationDays: (json['durationDays'] as num?)?.toInt() ?? 7,
    habits:
        (json['habits'] as List<dynamic>? ?? [])
            .map(
              (e) => ChallengeHabitEntry.fromJson(
                Map<String, dynamic>.from(e as Map),
              ),
            )
            .toList(),
    memberIds:
        (json['memberIds'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ownerId': ownerId,
    'name': name,
    'createdDate': createdDate,
    'durationDays': durationDays,
    'habits': habits.map((h) => h.toJson()).toList(),
    'memberIds': memberIds,
  };

  Challenge copyWith({
    String? name,
    int? durationDays,
    List<ChallengeHabitEntry>? habits,
    List<String>? memberIds,
  }) => Challenge(
    id: id,
    ownerId: ownerId,
    name: name ?? this.name,
    createdDate: createdDate,
    durationDays: durationDays ?? this.durationDays,
    habits: habits ?? this.habits,
    memberIds: memberIds ?? this.memberIds,
  );

  final String id;
  final String ownerId;
  final String name;

  /// Creation date, 'YYYY-MM-DD'. The 3-day setup window and the
  /// active window are derived from this (see logic/challenges.dart).
  final String createdDate;
  final int durationDays;
  final List<ChallengeHabitEntry> habits;

  /// Member user ids. Solo challenges ship with just the owner; the
  /// list exists so friends can join later without a schema change.
  final List<String> memberIds;

  Set<String> get habitIds => habits.map((h) => h.habitId).toSet();
}

// ---------------------------------------------------------------------------
// v2.9.0: chat reminders (the Reminders tab).
//
// A chat-style reminder is a plain-language message the user typed
// ("Buy milk at 6pm") that the app parsed into a scheduled time
// (see logic/chat_reminders.dart and, when online, the AI parser in
// data/ai_reminder_parser.dart). Both the chat history and the
// scheduled reminders live in LOCAL storage (SharedPreferences) —
// the source of truth; they never block on the network, and the
// Android exact alarm fires even with the app closed.
// ---------------------------------------------------------------------------

/// One bubble in the Reminders chat: the user's message or the bot's
/// reply (confirmation, tip, or "couldn't find a time").
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.ownerId,
    required this.role,
    required this.text,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String? ?? '',
    ownerId: json['ownerId'] as String? ?? '',
    role: json['role'] as String? ?? 'user',
    text: json['text'] as String? ?? '',
    createdAt: _parseDate(json['createdAt']) ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ownerId': ownerId,
    'role': role,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
  };

  final String id;
  final String ownerId;

  /// 'user' or 'assistant'.
  final String role;
  final String text;
  final DateTime createdAt;
}

/// One scheduled reminder created from a chat message.
class ChatReminder {
  const ChatReminder({
    required this.id,
    required this.ownerId,
    required this.text,
    required this.scheduledAt,
    required this.createdAt,
    this.fired = false,
  });

  factory ChatReminder.fromJson(Map<String, dynamic> json) => ChatReminder(
    id: json['id'] as String? ?? '',
    ownerId: json['ownerId'] as String? ?? '',
    text: json['text'] as String? ?? '',
    scheduledAt:
        _parseDate(json['scheduledAt']) ?? DateTime.now(),
    createdAt: _parseDate(json['createdAt']) ?? DateTime.now(),
    fired: json['fired'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'ownerId': ownerId,
    'text': text,
    'scheduledAt': scheduledAt.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'fired': fired,
  };

  ChatReminder copyWith({bool? fired}) => ChatReminder(
    id: id,
    ownerId: ownerId,
    text: text,
    scheduledAt: scheduledAt,
    createdAt: createdAt,
    fired: fired ?? this.fired,
  );

  final String id;
  final String ownerId;

  /// The reminder text (time/date part removed).
  final String text;

  /// When it fires (local time).
  final DateTime scheduledAt;
  final DateTime createdAt;

  /// True once it has fired (so it never fires twice).
  final bool fired;
}
