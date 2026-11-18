// Local persistence for v2.3.0 data (reminders + challenges).
//
// The Appwrite tables for these features are defined in
// scripts/setup_appwrite.mjs but could not be created yet — the API key
// is not available in this environment. Until the tables exist, the new
// features persist on-device in SharedPreferences (localStorage on web,
// private app storage on Android). The shape matches the future tables
// one-to-one, so moving to Appwrite later is a repository swap, not a
// UI change.
//
// Reminder data is per-account (ownerId): signing out clears it, so a
// different account on the same device never sees someone else's
// reminders or challenges.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class LocalStore {
  LocalStore(this._prefs);

  final SharedPreferences _prefs;

  static const _remindersKey = 'lifegame_reminders_v1';
  static const _challengesKey = 'lifegame_challenges_v1';
  static const _firedKey = 'lifegame_reminder_fired_v1';

  /// Habit notes fallback (18 Nov 2026): the live `habits` table has no
  /// `notes` attribute yet, so notes live on-device until the attribute
  /// exists (see HabitRepository.updateHabit). Keyed by owner id, a
  /// pipe, then habit id.
  static const _habitNotesKey = 'lifegame_habit_notes_v1';

  /// Habit sub-tasks fallback (v2.8.0, 18 Nov 2026): the
  /// `habit_subtasks` / `subtask_logs` tables may not exist yet, so
  /// sub-tasks live on-device until they do (see HabitRepository).
  /// Sub-tasks are stored as their local JSON (which carries the
  /// owner id); logs as plain SubtaskLog JSON.
  static const _subtasksKey = 'lifegame_subtasks_v1';
  static const _subtaskLogsKey = 'lifegame_subtask_logs_v1';

  /// v2.9.0 offline-first caches: the app's own data, kept on-device
  /// so it works with no network. The server is still the shared
  /// truth when online; these caches are the fallback when it cannot
  /// be reached, and the outbox (below) is what gets replayed to the
  /// server when the network returns.
  static const _habitsCacheKey = 'lifegame_habits_cache_v1';
  static const _habitLogsCacheKey = 'lifegame_habit_logs_cache_v1';
  static const _profileCacheKey = 'lifegame_profile_cache_v1';
  static const _tasksCacheKey = 'lifegame_tasks_cache_v1';

  /// Pending server writes (the outbox, v2.9.0): one JSON object per
  /// op, e.g. {'kind': 'log', 'habitId': ..., 'date': ...,
  /// 'done': true}. Replayed in order by SyncService when the network
  /// returns; an op is removed only after the server confirms it.
  static const _outboxKey = 'lifegame_outbox_v1';

  /// Reminders chat (v2.9.0): the chat bubbles + the scheduled
  /// reminders, per account (ownerId in each row).
  static const _chatMessagesKey = 'lifegame_chat_messages_v1';
  static const _chatRemindersKey = 'lifegame_chat_reminders_v1';

  // -- Offline caches (v2.9.0) --------------------------------------------

  List<Habit> loadCachedHabits(String ownerId) {
    final raw = _prefs.getString(_habitsCacheKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Habit.fromLocalJson(Map<String, dynamic>.from(e as Map)))
          .where((h) => h.userId == ownerId && !h.archived)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCachedHabits(
    String ownerId,
    List<Habit> habits,
  ) async {
    final all = <Habit>[];
    // Keep other accounts' cached habits (a shared device).
    try {
      final raw = _prefs.getString(_habitsCacheKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        all.addAll(
          list
              .map(
                (e) => Habit.fromLocalJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .where((h) => h.userId != ownerId),
        );
      }
    } catch (_) {}
    all.addAll(habits);
    await _prefs.setString(
      _habitsCacheKey,
      jsonEncode(all.map((h) => h.toLocalJson()).toList()),
    );
  }

  /// Merges one habit into the cache (add/update) without dropping
  /// the others.
  Future<void> upsertCachedHabit(Habit habit) async {
    final mine = loadCachedHabits(habit.userId);
    final index = mine.indexWhere((h) => h.id == habit.id);
    if (index >= 0) {
      mine[index] = habit;
    } else {
      mine.add(habit);
    }
    await saveCachedHabits(habit.userId, mine);
  }

  Future<void> removeCachedHabit(String ownerId, String habitId) async {
    final mine = loadCachedHabits(
      ownerId,
    ).where((h) => h.id != habitId).toList();
    await saveCachedHabits(ownerId, mine);
  }

  List<HabitLog> loadCachedHabitLogs(String ownerId) {
    final raw = _prefs.getString(_habitLogsCacheKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => HabitLog.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .where((l) => l.userId == ownerId)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveCachedHabitLogs(
    String ownerId,
    List<HabitLog> logs,
  ) async {
    final all = <HabitLog>[];
    try {
      final raw = _prefs.getString(_habitLogsCacheKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        all.addAll(
          list
              .map(
                (e) => HabitLog.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .where((l) => l.userId != ownerId),
        );
      }
    } catch (_) {}
    all.addAll(logs);
    await _prefs.setString(
      _habitLogsCacheKey,
      jsonEncode(all.map((l) => l.toLocalJson()).toList()),
    );
  }

  /// Applies one log toggle to the cache (add when done, remove when
  /// undone) — the local source of truth while offline.
  Future<void> applyCachedLog({
    required String ownerId,
    required String habitId,
    required String date,
    required bool done,
  }) async {
    final logs = loadCachedHabitLogs(ownerId);
    final id = '${habitId}_$date';
    logs.removeWhere((l) => l.id == id);
    if (done) {
      logs.add(
        HabitLog(
          id: id,
          habitId: habitId,
          userId: ownerId,
          logDate: date,
          completed: true,
          xpEarned: 2,
        ),
      );
    }
    await saveCachedHabitLogs(ownerId, logs);
  }

  Profile? loadCachedProfile(String ownerId) {
    final raw = _prefs.getString(_profileCacheKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final profile = Profile.fromJson({
        'id': map['id'],
        ...map,
      });
      return profile.id == ownerId ? profile : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveCachedProfile(Profile profile) async {
    await _prefs.setString(
      _profileCacheKey,
      jsonEncode({
        'id': profile.id,
        'username': profile.username,
        'displayName': profile.displayName,
        'avatarUrl': profile.avatarUrl,
        'bio': profile.bio,
        'xp': profile.xp,
        'currentStreak': profile.currentStreak,
        'longestStreak': profile.longestStreak,
        'lastActiveDate': profile.lastActiveDate,
        'visibility': profile.visibility,
        'discoverable': profile.discoverable,
      }),
    );
  }

  /// Weekly + monthly tasks, cached together (v2.9.0 offline-first).
  ({List<WeeklyTask> weekly, List<MonthlyTask> monthly}) loadCachedTasks(
    String ownerId,
  ) {
    final raw = _prefs.getString(_tasksCacheKey);
    if (raw == null || raw.isEmpty) {
      return (weekly: <WeeklyTask>[], monthly: <MonthlyTask>[]);
    }
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final weekly =
          (map['weekly'] as List<dynamic>? ?? [])
              .map(
                (e) => WeeklyTask.fromLocalJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .where((t) => t.userId == ownerId)
              .toList();
      final monthly =
          (map['monthly'] as List<dynamic>? ?? [])
              .map(
                (e) => MonthlyTask.fromLocalJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .where((t) => t.userId == ownerId)
              .toList();
      return (weekly: weekly, monthly: monthly);
    } catch (_) {
      return (weekly: <WeeklyTask>[], monthly: <MonthlyTask>[]);
    }
  }

  Future<void> saveCachedTasks(
    String ownerId,
    List<WeeklyTask> weekly,
    List<MonthlyTask> monthly,
  ) async {
    // Keep other accounts' tasks.
    var keptWeekly = <WeeklyTask>[];
    var keptMonthly = <MonthlyTask>[];
    try {
      final raw = _prefs.getString(_tasksCacheKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        keptWeekly =
            (map['weekly'] as List<dynamic>? ?? [])
                .map(
                  (e) => WeeklyTask.fromLocalJson(
                    Map<String, dynamic>.from(e as Map),
                  ),
                )
                .where((t) => t.userId != ownerId)
                .toList();
        keptMonthly =
            (map['monthly'] as List<dynamic>? ?? [])
                .map(
                  (e) => MonthlyTask.fromLocalJson(
                    Map<String, dynamic>.from(e as Map),
                  ),
                )
                .where((t) => t.userId != ownerId)
                .toList();
      }
    } catch (_) {}
    await _prefs.setString(
      _tasksCacheKey,
      jsonEncode({
        'weekly': [
          ...keptWeekly.map((t) => t.toLocalJson()),
          ...weekly.map((t) => t.toLocalJson()),
        ],
        'monthly': [
          ...keptMonthly.map((t) => t.toLocalJson()),
          ...monthly.map((t) => t.toLocalJson()),
        ],
      }),
    );
  }

  // -- Outbox (v2.9.0) -------------------------------------------------------

  List<Map<String, dynamic>> loadOutbox() {
    final raw = _prefs.getString(_outboxKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveOutbox(List<Map<String, dynamic>> ops) async {
    await _prefs.setString(_outboxKey, jsonEncode(ops));
  }

  Future<void> enqueueOutboxOp(Map<String, dynamic> op) async {
    final ops = loadOutbox();
    // A log toggle for the same habit+date replaces the earlier one
    // (only the latest desired state matters).
    if (op['kind'] == 'log') {
      ops.removeWhere(
        (o) =>
            o['kind'] == 'log' &&
            o['habitId'] == op['habitId'] &&
            o['date'] == op['date'],
      );
    }
    ops.add(op);
    await saveOutbox(ops);
  }

  // -- Reminders chat (v2.9.0) ----------------------------------------------

  List<ChatMessage> loadChatMessages(String ownerId) {
    final raw = _prefs.getString(_chatMessagesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => ChatMessage.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .where((m) => m.ownerId == ownerId)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveChatMessages(
    String ownerId,
    List<ChatMessage> messages,
  ) async {
    final all = <Map<String, dynamic>>[];
    try {
      final raw = _prefs.getString(_chatMessagesKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        for (final e in list) {
          final map = Map<String, dynamic>.from(e as Map);
          if ((map['ownerId'] as String? ?? '') != ownerId) {
            all.add(map);
          }
        }
      }
    } catch (_) {}
    for (final m in messages) {
      all.add(m.toJson());
    }
    await _prefs.setString(_chatMessagesKey, jsonEncode(all));
  }

  List<ChatReminder> loadChatReminders(String ownerId) {
    final raw = _prefs.getString(_chatRemindersKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => ChatReminder.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .where((r) => r.ownerId == ownerId)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveChatReminders(List<ChatReminder> reminders) async {
    await _prefs.setString(
      _chatRemindersKey,
      jsonEncode(reminders.map((r) => r.toJson()).toList()),
    );
  }

  // -- App update notices (v2.10.0) --------------------------------------
  // The version the user dismissed an update for (do not show it
  // again) and the latest update version already shown (dedupe).

  static const _updateDismissedKey = 'lifegame_update_dismissed_v1';
  static const _updateSeenKey = 'lifegame_update_seen_v1';

  String? get updateDismissedVersion =>
      _prefs.getString(_updateDismissedKey);

  Future<void> setUpdateDismissedVersion(String version) async {
    await _prefs.setString(_updateDismissedKey, version);
  }

  String? get lastSeenUpdateVersion => _prefs.getString(_updateSeenKey);

  Future<void> setLastSeenUpdateVersion(String version) async {
    await _prefs.setString(_updateSeenKey, version);
  }

  /// Raw locally stored sub-task rows (any owner). Each map carries
  /// its owner id under 'ownerId'.
  List<Map<String, dynamic>> loadSubtaskMaps() {
    final raw = _prefs.getString(_subtasksKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSubtaskMaps(List<Map<String, dynamic>> maps) async {
    await _prefs.setString(_subtasksKey, jsonEncode(maps));
  }

  /// All locally stored sub-tasks (any owner), parsed.
  List<HabitSubtask> loadSubtasks() =>
      loadSubtaskMaps().map(HabitSubtask.fromJson).toList();

  /// The owner id a locally stored sub-task row belongs to (the JSON
  /// carries it; Appwrite rows do not have it).
  static String subtaskOwnerId(Map<String, dynamic> json) =>
      json['ownerId'] as String? ?? '';

  List<SubtaskLog> loadSubtaskLogs() {
    final raw = _prefs.getString(_subtaskLogsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => SubtaskLog.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSubtaskLogs(List<SubtaskLog> logs) async {
    final raw = jsonEncode(logs.map((l) => l.toJson()).toList());
    await _prefs.setString(_subtaskLogsKey, raw);
  }

  Map<String, String> loadHabitNotes() {
    final raw = _prefs.getString(_habitNotesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v.toString()));
    } catch (_) {
      return {};
    }
  }

  Future<void> saveHabitNote(
    String ownerId,
    String habitId,
    String notes,
  ) async {
    final map = loadHabitNotes();
    final key = '$ownerId|$habitId';
    if (notes.trim().isEmpty) {
      map.remove(key);
    } else {
      map[key] = notes;
    }
    await _prefs.setString(_habitNotesKey, jsonEncode(map));
  }

  Future<void> deleteHabitNote(String ownerId, String habitId) async {
    final map = loadHabitNotes();
    if (map.remove('$ownerId|$habitId') != null) {
      await _prefs.setString(_habitNotesKey, jsonEncode(map));
    }
  }

  static Future<LocalStore> getInstance() async {
    final prefs = await SharedPreferences.getInstance();
    return LocalStore(prefs);
  }

  List<Reminder> loadReminders() {
    final raw = _prefs.getString(_remindersKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => Reminder.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveReminders(List<Reminder> reminders) async {
    final raw = jsonEncode(reminders.map((r) => r.toJson()).toList());
    await _prefs.setString(_remindersKey, raw);
  }

  List<Challenge> loadChallenges() {
    final raw = _prefs.getString(_challengesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map(
            (e) => Challenge.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveChallenges(List<Challenge> challenges) async {
    final raw = jsonEncode(challenges.map((c) => c.toJson()).toList());
    await _prefs.setString(_challengesKey, raw);
  }

  /// Date key (YYYY-MM-DD) a reminder last fired, or null.
  String? lastFiredDate(String reminderId) {
    final raw = _prefs.getString(_firedKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map[reminderId] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> markFired(String reminderId, String dateKey) async {
    var map = <String, dynamic>{};
    final raw = _prefs.getString(_firedKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        map = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {}
    }
    map[reminderId] = dateKey;
    await _prefs.setString(_firedKey, jsonEncode(map));
  }

  /// Removes all v2.3.0 data belonging to [ownerId] (called on sign-out
  /// and account delete so another account on the same device never
  /// inherits it).
  Future<void> clearForUser(String ownerId) async {
    final reminders = loadReminders()
        .where((r) => r.ownerId != ownerId)
        .toList();
    await saveReminders(reminders);
    final challenges = loadChallenges()
        .where((c) => c.ownerId != ownerId)
        .toList();
    await saveChallenges(challenges);
    // Habit notes are per-owner too (key "<ownerId>|<habitId>").
    final notes = loadHabitNotes();
    notes.removeWhere((key, _) => key.startsWith('$ownerId|'));
    await _prefs.setString(_habitNotesKey, jsonEncode(notes));
    // Sub-tasks + their logs: keep only other owners' rows (the raw
    // maps carry the owner id, which fromJson drops — so filter the
    // raw JSON, not the parsed models).
    final mySubtaskIds = <String>{};
    final keptSubtaskMaps = <Map<String, dynamic>>[];
    for (final map in loadSubtaskMaps()) {
      if (subtaskOwnerId(map) == ownerId) {
        mySubtaskIds.add(map['id'] as String? ?? '');
      } else {
        keptSubtaskMaps.add(map);
      }
    }
    await saveSubtaskMaps(keptSubtaskMaps);
    final logs = loadSubtaskLogs()
        .where((l) => !mySubtaskIds.contains(l.subtaskId))
        .toList();
    await saveSubtaskLogs(logs);
    // v2.9.0 offline caches + outbox + chat: keep only other owners'.
    await saveCachedHabits(
      ownerId,
      loadCachedHabits(ownerId).where((h) => h.userId != ownerId).toList(),
    );
    await saveCachedHabitLogs(
      ownerId,
      loadCachedHabitLogs(ownerId).where((l) => l.userId != ownerId).toList(),
    );
    final cachedProfile = loadCachedProfile(ownerId);
    if (cachedProfile != null) {
      await _prefs.remove(_profileCacheKey);
    }
    final tasks = loadCachedTasks(ownerId);
    await saveCachedTasks(
      ownerId,
      tasks.weekly.where((t) => t.userId != ownerId).toList(),
      tasks.monthly.where((t) => t.userId != ownerId).toList(),
    );
    final ops = loadOutbox().where((o) => o['ownerUid'] != ownerId).toList();
    await saveOutbox(ops);
    await saveChatMessages(
      ownerId,
      loadChatMessages(ownerId).where((m) => m.ownerId != ownerId).toList(),
    );
    final chatReminders = loadChatReminders(ownerId)
        .where((r) => r.ownerId != ownerId)
        .toList();
    await saveChatReminders(chatReminders);
  }
}
