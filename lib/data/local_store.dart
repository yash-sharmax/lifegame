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
  }
}
