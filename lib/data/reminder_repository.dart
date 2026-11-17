// Reminders: one time-of-day alarm per habit or weekly/monthly task.
//
// Stored locally (see local_store.dart) until the Appwrite `reminders`
// table exists. The repository notifies [onChanged] so the Schedule
// screen and Home tiles refresh when a reminder is set or removed.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_store.dart';
import 'models.dart';
import 'repositories.dart';

class ReminderRepository {
  ReminderRepository({this._prefs, this._store});

  // The store is acquired lazily inside each method — never in the
  // constructor. A Future created in the constructor that is never
  // awaited (e.g. when the user check throws first) would complete
  // with an error nobody handles, which the test framework reports
  // as an unhandled async error (SharedPreferences has no platform
  // channel in widget tests).
  final SharedPreferences? _prefs;
  final LocalStore? _store;

  Future<LocalStore> _storeFuture() async {
    if (_store != null) return _store;
    if (_prefs != null) return LocalStore(_prefs);
    return LocalStore.getInstance();
  }

  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get onChanged => _changes.stream;
  static void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static void notifyChangedForTest() => _notifyChanged();

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  Future<List<Reminder>> listMyReminders() async {
    final userId = _requireUserId();
    final store = await _storeFuture();
    return store.loadReminders().where((r) => r.ownerId == userId).toList();
  }

  Future<Map<String, Reminder>> remindersByTarget() async {
    final list = await listMyReminders();
    return {for (final r in list) '${r.kind}:${r.targetId}': r};
  }

  Future<Reminder?> reminderFor(String kind, String targetId) async {
    final map = await remindersByTarget();
    return map['$kind:$targetId'];
  }

  /// Creates or updates the reminder for one item. One reminder per
  /// target: saving again with a new time overwrites the old one.
  Future<Reminder> setReminder({
    required String kind,
    required String targetId,
    required String title,
    required int hour,
    required int minute,
    bool enabled = true,
  }) async {
    final userId = _requireUserId();
    final store = await _storeFuture();
    final id = Reminder.idFor(kind, targetId);
    final reminder = Reminder(
      id: id,
      ownerId: userId,
      kind: kind,
      targetId: targetId,
      title: title,
      hour: hour,
      minute: minute,
      enabled: enabled,
    );
    final all = store.loadReminders();
    final index = all.indexWhere((r) => r.id == id);
    if (index >= 0) {
      all[index] = reminder;
    } else {
      all.add(reminder);
    }
    await store.saveReminders(all);
    _notifyChanged();
    return reminder;
  }

  Future<void> setEnabled(Reminder reminder, bool enabled) async {
    final store = await _storeFuture();
    final all = store.loadReminders();
    final index = all.indexWhere((r) => r.id == reminder.id);
    if (index < 0) return;
    all[index] = all[index].copyWith(enabled: enabled);
    await store.saveReminders(all);
    _notifyChanged();
  }

  Future<void> deleteReminder(String kind, String targetId) async {
    final store = await _storeFuture();
    final id = Reminder.idFor(kind, targetId);
    final all = store.loadReminders();
    all.removeWhere((r) => r.id == id);
    await store.saveReminders(all);
    _notifyChanged();
  }

  /// Removes reminders whose target no longer exists (e.g. a habit was
  /// deleted). Called opportunistically by the Schedule screen.
  Future<void> pruneOrphaned(Set<String> liveTargetKeys) async {
    final store = await _storeFuture();
    final all = store.loadReminders();
    final before = all.length;
    all.removeWhere((r) => !liveTargetKeys.contains('${r.kind}:${r.targetId}'));
    if (all.length != before) {
      await store.saveReminders(all);
      _notifyChanged();
    }
  }
}
