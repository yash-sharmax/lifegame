/// Typing indicator (v2.11.5): ephemeral "X is typing…" state.
///
/// The app polls messages every 15 seconds and has no realtime
/// subscription, so typing rides on a tiny server table
/// (`typing_status`: one row per (conversation, user), refreshed
/// while typing, deleted when idle/sent/left) plus a 3-second poll
/// while a chat is open. Rows older than ~6 seconds are ignored
/// client-side, so a crashed client stops "typing" on its own.
///
/// Every call is best-effort: when the table does not exist yet
/// (the parent creates it via the console — see
/// scripts/setup_appwrite.mjs), the indicator simply never shows.
/// The chat itself still works.
library;

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;

import '../config.dart';
import 'appwrite_service.dart';
import 'repositories.dart';

TablesDB _requireDb(TablesDB? injected) {
  final d = injected ?? AppwriteService.dbOrNull;
  if (d == null) throw AppwriteNotConfigured();
  return d;
}

String get _dbId => AppConfig.databaseId;

Map<String, dynamic> _docJson(models.Row doc) => {
  'id': doc.$id,
  r'$createdAt': doc.$createdAt,
  ...doc.data,
};

/// A typing row is fresh for this long after its last keystroke.
/// Longer than the 3-second publish interval, so a steady typist
/// never flickers off; short enough that a crashed client stops
/// "typing" within seconds.
const Duration kTypingFreshFor = Duration(seconds: 6);

/// Publish at most this often while typing — no row per keystroke.
const Duration kTypingPublishInterval = Duration(seconds: 3);

/// Clear my typing row after this long without a keystroke.
const Duration kTypingIdleClearAfter = Duration(seconds: 5);

class TypingState {
  const TypingState({required this.userId, required this.updatedAt});

  factory TypingState.fromJson(Map<String, dynamic> json) => TypingState(
    userId: json['userId'] as String? ?? '',
    updatedAt:
        DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
  );

  final String userId;
  final DateTime updatedAt;
}

/// Pure: should I publish now? The first keystroke always
/// publishes; after that at most once per [kTypingPublishInterval].
bool shouldPublishTyping({
  required DateTime? lastPublished,
  required DateTime now,
}) {
  if (lastPublished == null) return true;
  return now.difference(lastPublished) >= kTypingPublishInterval;
}

/// Pure: user ids whose typing state is still fresh — excluding me
/// (I never show my own indicator to myself).
List<String> freshTypingUserIds({
  required List<TypingState> rows,
  required String myId,
  required DateTime now,
}) {
  final ids = <String>[];
  for (final row in rows) {
    if (row.userId.isEmpty || row.userId == myId) continue;
    if (now.difference(row.updatedAt) > kTypingFreshFor) continue;
    if (!ids.contains(row.userId)) ids.add(row.userId);
  }
  return ids;
}

/// Pure: the label for the typing row. DM: one name. Group: names
/// joined, or a count when there are many.
String typingLabel(List<String> names) {
  if (names.isEmpty) return '';
  if (names.length == 1) return '${names.first} is typing…';
  if (names.length == 2) return '${names[0]} and ${names[1]} are typing…';
  return '${names.length} people are typing…';
}

class TypingService {
  TypingService({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  String _myId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  /// When I last published for each conversation (throttle), and
  /// my typing row id per conversation (avoids a lookup per
  /// keystroke once it is known). Both keyed by conversation AND
  /// user — a shared device can switch accounts, and one user's
  /// row must never be updated as another user's.
  final Map<String, DateTime> _lastPublished = {};
  final Map<String, String> _myRowIds = {};

  String _keyFor(String conversationId, String myId) =>
      '$conversationId|$myId';

  /// Publishes "I am typing" for [conversationId], throttled to
  /// one write per [kTypingPublishInterval]. Silent when offline
  /// or when the table does not exist yet.
  Future<void> publishTyping(String conversationId) async {
    try {
      final myId = _myId();
      final key = _keyFor(conversationId, myId);
      final now = DateTime.now().toUtc();
      if (!shouldPublishTyping(
        lastPublished: _lastPublished[key],
        now: now,
      )) {
        return;
      }
      _lastPublished[key] = now;
      final stamp = now.toIso8601String();
      final rowId = _myRowIds[key];
      if (rowId != null) {
        try {
          await _d.updateRow(
            databaseId: _dbId,
            tableId: 'typing_status',
            rowId: rowId,
            data: {'updatedAt': stamp},
          );
          return;
        } catch (_) {
          // Row is gone (deleted elsewhere) — fall through and
          // re-create it below.
          _myRowIds.remove(key);
        }
      }
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'typing_status',
        queries: [
          Query.equal('conversationId', conversationId),
          Query.equal('userId', myId),
          Query.limit(1),
        ],
      );
      if (list.rows.isNotEmpty) {
        final id = _docJson(list.rows.first)['id'] as String;
        _myRowIds[key] = id;
        await _d.updateRow(
          databaseId: _dbId,
          tableId: 'typing_status',
          rowId: id,
          data: {'updatedAt': stamp},
        );
        return;
      }
      final doc = await _d.createRow(
        databaseId: _dbId,
        tableId: 'typing_status',
        rowId: ID.unique(),
        data: {
          'conversationId': conversationId,
          'userId': myId,
          'updatedAt': stamp,
        },
      );
      _myRowIds[key] = doc.$id;
    } catch (_) {
      // Offline, or the table is not created yet — typing just
      // does not show. Never crash the chat over it.
    }
  }

  /// Clears my typing row for [conversationId] (idle, sent, or
  /// left the chat). Best-effort.
  Future<void> clearTyping(String conversationId) async {
    final myIdForKey = AuthRepository.cachedUser?.uid ?? '';
    _lastPublished.remove(_keyFor(conversationId, myIdForKey));
    try {
      final myId = _myId();
      final key = _keyFor(conversationId, myId);
      var rowId = _myRowIds.remove(key);
      if (rowId == null) {
        final list = await _d.listRows(
          databaseId: _dbId,
          tableId: 'typing_status',
          queries: [
            Query.equal('conversationId', conversationId),
            Query.equal('userId', myId),
            Query.limit(1),
          ],
        );
        if (list.rows.isEmpty) return;
        rowId = _docJson(list.rows.first)['id'] as String;
      }
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'typing_status',
        rowId: rowId,
      );
    } catch (_) {}
  }

  /// Everyone typing in [conversationId] right now (raw rows —
  /// the caller filters for freshness and for self with
  /// [freshTypingUserIds]). [] when offline or the table is
  /// missing.
  Future<List<TypingState>> fetchTyping(String conversationId) async {
    try {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'typing_status',
        queries: [
          Query.equal('conversationId', conversationId),
          Query.limit(20),
        ],
      );
      return list.rows
          .map((doc) => TypingState.fromJson(_docJson(doc)))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
