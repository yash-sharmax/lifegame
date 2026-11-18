// Background sync (v2.9.0, offline-first).
//
// The app is local-first: habits, logs, tasks and the profile live in
// the on-device cache (LocalStore) and every change applies there
// immediately. The server (Appwrite) catches up in the background:
//
// - When the network returns (or the app starts online), [syncNow]
//   replays the pending outbox ops in order, oldest first. An op is
//   removed only after the server confirms it; a network failure stops
//   the replay (the rest stays queued) and a non-network failure drops
//   the op (it is unrecoverable — e.g. the row was deleted elsewhere).
// - A [Stream] reports whether the device is online, so the UI can
//   show a small "you're offline" line instead of a big error.
//
// All failures are swallowed: a sync that cannot run must never crash
// the app or block the UI.
library;

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'local_store.dart';
import 'repositories.dart';

/// The app is local-first (v2.9.0, offline-first): habits, logs, tasks
/// and the profile live in the on-device cache (LocalStore) and every
/// change applies there immediately. The server (Appwrite) catches up
/// in the background:
///
/// - When the network returns (or the app starts online), [syncNow]
///   replays the pending outbox ops in order, oldest first. An op is
///   removed only after the server confirms it; a network failure stops
///   the replay (the rest stays queued) and a non-network failure drops
///   the op (it is unrecoverable — e.g. the row was deleted elsewhere).
/// - A [Stream] reports whether the device is online, so the UI can
///   show a small "you're offline" line instead of a big error.
///
/// All failures are swallowed: a sync that cannot run must never crash
/// the app or block the UI.
class SyncService {
  SyncService._();

  static final SyncService instance = SyncService._();

  final _online = StreamController<bool>.broadcast();

  /// Emits the current online state whenever it changes. Screens
  /// listen to show the small offline line.
  Stream<bool> get online => _online.stream;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  bool _listening = false;
  bool _syncing = false;

  /// Starts the connectivity listener. Safe to call repeatedly.
  /// [onSync] runs after the network returns (the caller wires it to
  /// [syncNow]).
  Future<void> init() async {
    if (_listening) return;
    _listening = true;
    try {
      final results = await Connectivity().checkConnectivity();
      _setOnline(!results.contains(ConnectivityResult.none));
    } catch (_) {
      // Unknown connectivity — assume online; a failed call still
      // degrades to the local cache.
      _setOnline(true);
    }
    try {
      Connectivity().onConnectivityChanged.listen((results) {
        final online = !results.contains(ConnectivityResult.none);
        if (online && !_isOnline) {
          // Just came back online: sync in the background.
          _setOnline(true);
          unawaited(syncNow());
        } else {
          _setOnline(online);
        }
      });
    } catch (_) {
      // No connectivity plugin (e.g. a test) — stays online.
    }
  }

  void _setOnline(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    if (!_online.isClosed) _online.add(online);
  }

  /// Test-only: forces the online state (so tests can simulate a
  /// reconnect without a real network change).
  void debugSetOnlineForTest(bool online) {
    _isOnline = online;
    if (!_online.isClosed) _online.add(online);
  }

  /// Replays the outbox (oldest first) and heals derived XP. Silent
  /// and best-effort: returns when done or when the network fails.
  /// Only one sync runs at a time; a concurrent call waits for it.
  Future<void> syncNow() async {
    if (_syncing) return;
    _syncing = true;
    try {
      final user = AuthRepository.cachedUser;
      if (user == null) return;
      final store = await LocalStore.getInstance();
      while (true) {
        final ops = store.loadOutbox();
        if (ops.isEmpty) break;
        final op = ops.first;
        // The op's full content is its identity: if a newer toggle
        // for the same habit+date replaced it while we worked, the
        // content differs and the newer op must NOT be removed — it
        // still needs replaying.
        final identity = _opIdentity(op);
        try {
          await _replayOp(op);
        } on Object catch (e) {
          if (isNetworkError(e)) {
            // Still offline — stop, keep the rest queued.
            return;
          }
          // Unrecoverable (e.g. the row is gone) — drop it below.
        }
        final remaining = store.loadOutbox();
        remaining.removeWhere((o) => _opIdentity(o) == identity);
        await store.saveOutbox(remaining);
      }
      // Heal derived XP from the server now that we are in sync.
      try {
        await ProfileRepository().recomputeDerivedXp();
      } catch (_) {}
    } catch (_) {
      // Best-effort (see the header).
    } finally {
      _syncing = false;
    }
  }

  /// The outbox op's identity: its full JSON content. Two ops with
  /// identical content are interchangeable; a newer desired state for
  /// the same habit+date has different content and survives.
  String _opIdentity(Map<String, dynamic> op) {
    // jsonEncode is deterministic for the small maps we store.
    return op.entries.map((e) => '${e.key}=${e.value}').join('&');
  }

  Future<void> _replayOp(Map<String, dynamic> op) async {
    final kind = op['kind'] as String? ?? '';
    final habits = HabitRepository();
    final tasks = TaskRepository();
    final profiles = ProfileRepository();
    switch (kind) {
      case 'log':
        await habits.replayLogOp(
          habitId: op['habitId'] as String? ?? '',
          date: op['date'] as String? ?? '',
          done: op['done'] as bool? ?? false,
        );
      case 'habit_add':
        await habits.replayHabitAdd(
          id: op['id'] as String? ?? '',
          title: op['title'] as String? ?? '',
          color: (op['color'] as num?)?.toInt() ?? 0,
        );
      case 'habit_update':
        await habits.replayHabitUpdate(
          id: op['id'] as String? ?? '',
          title: op['title'] as String?,
          color: (op['color'] as num?)?.toInt(),
          notes: op['notes'] as String?,
        );
      case 'habit_archive':
        await habits.replayHabitArchive(op['id'] as String? ?? '');
      case 'habit_delete':
        await habits.replayHabitDelete(op['id'] as String? ?? '');
      case 'subtask_log':
        await habits.replaySubtaskLog(
          subtaskId: op['subtaskId'] as String? ?? '',
          date: op['date'] as String? ?? '',
          done: op['done'] as bool? ?? false,
        );
      case 'subtask_add':
        await habits.replaySubtaskAdd(
          id: op['id'] as String? ?? '',
          habitId: op['habitId'] as String? ?? '',
          title: op['title'] as String? ?? '',
          kind: op['subtaskKind'] as String? ?? 'daily',
          date: op['date'] as String? ?? '',
        );
      case 'subtask_delete':
        await habits.replaySubtaskDelete(op['id'] as String? ?? '');
      case 'task_add_weekly':
        await tasks.replayTaskAdd(
          weekly: true,
          id: op['id'] as String? ?? '',
          title: op['title'] as String? ?? '',
          key: op['key'] as String? ?? '',
        );
      case 'task_add_monthly':
        await tasks.replayTaskAdd(
          weekly: false,
          id: op['id'] as String? ?? '',
          title: op['title'] as String? ?? '',
          key: op['key'] as String? ?? '',
        );
      case 'task_toggle_weekly':
        await tasks.replayTaskToggle(
          weekly: true,
          id: op['id'] as String? ?? '',
          done: op['done'] as bool? ?? false,
        );
      case 'task_toggle_monthly':
        await tasks.replayTaskToggle(
          weekly: false,
          id: op['id'] as String? ?? '',
          done: op['done'] as bool? ?? false,
        );
      case 'task_delete_weekly':
        await tasks.replayTaskDelete(
          weekly: true,
          id: op['id'] as String? ?? '',
        );
      case 'task_delete_monthly':
        await tasks.replayTaskDelete(
          weekly: false,
          id: op['id'] as String? ?? '',
        );
      case 'profile_update':
        await profiles.replayProfileUpdate(
          Map<String, dynamic>.from(op['data'] as Map? ?? {}),
        );
    }
  }
}
