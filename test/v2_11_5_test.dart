/// v2.11.5 tests — fast + offline chats, typing indicator, rank
/// tie, and the imgbb key wired (upload covered with a mocked
/// HTTP client — no real network, no real key in the test).
///
/// Pure rules are tested directly; service behaviour (cache
/// round-trip, outbox drain, typing rows, leaderboard tie) runs
/// against an in-memory fake TablesDB (same shape as the v2.11.2
/// fake, plus greaterThan for the rank query). No Appwrite, no
/// network.
library;

import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lifegame/data/imgbb.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/messaging_models.dart';
import 'package:lifegame/data/messaging_service.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/data/sync_service.dart';
import 'package:lifegame/data/typing_service.dart';
import 'package:lifegame/logic/xp.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [Client] that never talks to anything (same trick as the
/// v2.9.0 tests).
class _StubClient implements Client {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Row {
  _Row({required this.id, required this.createdAt, required this.data});

  final String id;
  final String createdAt;
  final Map<String, dynamic> data;
}

/// Compact in-memory [TablesDB] (same shape as the v2.11.2 fake):
/// equal / greaterThan / startsWith / orderAsc / orderDesc /
/// limit / offset.
class _FakeDB extends TablesDB {
  _FakeDB() : super(_StubClient());

  final Map<String, Map<String, _Row>> _tables = {};
  int _seq = 0;

  Map<String, _Row> _rowsOf(String tableId) =>
      _tables.putIfAbsent(tableId, () => {});

  String _now() {
    // Real-now stamps (not a fixed date): the merge window in
    // mergeCachedMessages compares server and pending createdAt
    // values, so a fake 2026-01-01 clock would never match a
    // pending message stamped with the real clock.
    final stamp = DateTime.now().toUtc().add(Duration(milliseconds: _seq++));
    return stamp.toIso8601String();
  }

  models.Row _toRow(String tableId, _Row row) => models.Row(
    $id: row.id,
    $sequence: '0',
    $tableId: tableId,
    $databaseId: 'lifegame',
    $createdAt: row.createdAt,
    $updatedAt: row.createdAt,
    $permissions: const [],
    data: Map<String, dynamic>.from(row.data),
  );

  @override
  Future<models.Row> createRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    required Map data,
    List<String>? permissions,
    String? transactionId,
  }) async {
    final rows = _rowsOf(tableId);
    if (rows.containsKey(rowId)) {
      throw AppwriteException(
        'Row already exists',
        409,
        'document_already_exists',
      );
    }
    final row = _Row(
      id: rowId,
      createdAt: _now(),
      data: Map<String, dynamic>.from(data),
    );
    rows[rowId] = row;
    return _toRow(tableId, row);
  }

  @override
  Future<models.Row> getRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    List<String>? queries,
    String? transactionId,
  }) async {
    final row = _rowsOf(tableId)[rowId];
    if (row == null) {
      throw AppwriteException('Row not found', 404, 'document_not_found');
    }
    return _toRow(tableId, row);
  }

  @override
  Future<models.Row> updateRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    Map? data,
    List<String>? permissions,
    String? transactionId,
  }) async {
    final row = _rowsOf(tableId)[rowId];
    if (row == null) {
      throw AppwriteException('Row not found', 404, 'document_not_found');
    }
    if (data != null) row.data.addAll(Map<String, dynamic>.from(data));
    return _toRow(tableId, row);
  }

  @override
  Future<dynamic> deleteRow({
    required String databaseId,
    required String tableId,
    required String rowId,
    String? transactionId,
  }) async {
    final removed = _rowsOf(tableId).remove(rowId);
    if (removed == null) {
      throw AppwriteException('Row not found', 404, 'document_not_found');
    }
    return null;
  }

  @override
  Future<models.RowList> listRows({
    required String databaseId,
    required String tableId,
    List<String>? queries,
    String? transactionId,
    bool? total,
    int? ttl,
  }) async {
    var rows = _rowsOf(tableId).values.toList();
    var limit = 25;
    var offset = 0;
    for (final q in queries ?? const <String>[]) {
      final parsed = jsonDecode(q) as Map<String, dynamic>;
      final method = parsed['method'] as String;
      final attribute = parsed['attribute'] as String?;
      final values = (parsed['values'] as List?) ?? const [];
      switch (method) {
        case 'equal':
          rows = rows
              .where((r) => values.contains(_valueOf(r, attribute!)))
              .toList();
        case 'greaterThan':
          rows = rows.where((r) {
            final v = _valueOf(r, attribute!);
            return v is Comparable &&
                values.isNotEmpty &&
                v.compareTo(values.first) > 0;
          }).toList();
        case 'startsWith':
          rows = rows
              .where(
                (r) => (_valueOf(r, attribute!) as String).startsWith(
                  values.first as String,
                ),
              )
              .toList();
        case 'orderAsc':
          final attrAsc = attribute!;
          rows.sort(
            (a, b) => _compare(_valueOf(a, attrAsc), _valueOf(b, attrAsc)),
          );
        case 'orderDesc':
          final attrDesc = attribute!;
          rows.sort(
            (a, b) => _compare(_valueOf(b, attrDesc), _valueOf(a, attrDesc)),
          );
        case 'limit':
          limit = values.first as int;
        case 'offset':
          offset = values.first as int;
      }
    }
    final filteredTotal = rows.length;
    final page = rows.skip(offset).take(limit).toList();
    return models.RowList(
      total: filteredTotal,
      rows: page.map((r) => _toRow(tableId, r)).toList(),
    );
  }

  dynamic _valueOf(_Row row, String attribute) {
    if (attribute == r'$createdAt') return row.createdAt;
    if (attribute == r'$id') return row.id;
    return row.data[attribute];
  }

  int _compare(dynamic a, dynamic b) {
    if (a is Comparable && b is Comparable) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }

  int rowCount(String tableId) => _rowsOf(tableId).length;
}

void main() {
  SharedPreferences.setMockInitialValues({});

  void asUser(String uid) {
    AuthRepository.debugSetCachedUserForTest(
      AppAuthUser(uid: uid, email: '$uid@example.com'),
    );
  }

  /// The fire-and-forget cache writes in the service need a moment
  /// to land in the mocked prefs.
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  DmMessage plainMessage({
    required String id,
    required String conversationId,
    required String senderId,
    required String text,
    DateTime? createdAt,
  }) => DmMessage(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    createdAt: createdAt ?? DateTime.utc(2026, 11, 19, 10, 0),
    expiresAt: DateTime.utc(2026, 11, 19, 22, 0),
    type: 'text',
    text: text,
    decryptedText: text,
  );

  Future<void> seedDm(_FakeDB db, String conversationId) async {
    await db.createRow(
      databaseId: 'lifegame',
      tableId: 'conversations',
      rowId: conversationId,
      data: {
        'type': 'dm',
        'title': null,
        'createdBy': 'user-1',
        'createdAt': '2026-11-19T09:00:00.000Z',
        'lastMessageAt': '2026-11-19T10:02:00.000Z',
        'lastMessagePreview': 'Hello',
        'status': 'active',
      },
    );
    for (final uid in ['user-1', 'user-2']) {
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'conversation_members',
        rowId: 'm_${conversationId}_$uid',
        data: {
          'conversationId': conversationId,
          'userId': uid,
          'role': 'member',
          'joinedAt': '2026-11-19T09:00:00.000Z',
          'lastReadAt': null,
        },
      );
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'users',
        rowId: uid,
        data: {
          'username': uid == 'user-1' ? 'muse_demo' : 'yashsharma',
          'displayName': uid == 'user-1' ? 'Muse Demo' : 'Yash Sharma',
          'xp': 0,
          'visibility': 'public',
          'discoverable': true,
        },
      );
    }
  }

  Future<void> seedPlainMessage(
    _FakeDB db,
    String rowId,
    String conversationId,
    String senderId,
    String text,
  ) async {
    await db.createRow(
      databaseId: 'lifegame',
      tableId: 'messages',
      rowId: rowId,
      data: {
        'conversationId': conversationId,
        'senderId': senderId,
        'type': 'text',
        'text': text,
        'createdAt': '2026-11-19T10:00:00.000Z',
        'expiresAt': '2026-11-19T22:00:00.000Z',
        'encrypted': false,
        'ciphertext': null,
        'encryptedKeys': null,
        'deletedForAll': false,
        'isViewOnce': false,
        'viewOnceViewed': false,
        'forwarded': false,
      },
    );
  }

  // -- FIX 3: rank tie -------------------------------------------------
  group('rank tie — Profile and Leaderboard use the same rule', () {
    test('competitionRanks: ties share a rank, the next rank skips', () {
      expect(competitionRanks([4, 2, 0, 0]), [1, 2, 3, 3]);
      expect(competitionRanks([10, 10, 5]), [1, 1, 3]);
      expect(competitionRanks([7]), [1]);
      expect(competitionRanks([]), isEmpty);
    });

    test('a 0 XP tie: Profile rank == Leaderboard rank', () async {
      final db = _FakeDB();
      final profiles = ProfileRepository(db: db);
      asUser('me');
      // xp: 4, 2, 0, 0, 0 (me) — plus a hidden user at 99 who
      // must count for NOBODY (not on the board, not in my rank).
      for (final (uid, xp, discoverable) in [
        ('u1', 4, true),
        ('u2', 2, true),
        ('u3', 0, true),
        ('u4', 0, true),
        ('me', 0, true),
        ('hidden', 99, false),
      ]) {
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'users',
          rowId: uid,
          data: {
            'username': uid,
            'displayName': uid,
            'xp': xp,
            'visibility': 'public',
            'discoverable': discoverable,
          },
        );
      }
      final board = await profiles.fetchGlobalLeaderboard();
      expect(board.map((e) => e.rank), [1, 2, 3, 3, 3]);
      expect(board.map((e) => e.profile.id), [
        'u1',
        'u2',
        'u3',
        'u4',
        'me',
      ]);
      final myRank = await profiles.fetchGlobalRank();
      final myBoardRank = board
          .firstWhere((e) => e.profile.id == 'me')
          .rank;
      expect(myRank, 3);
      expect(myRank, myBoardRank);
    });
  });

  // -- FIX 1: offline cache --------------------------------------------
  group('offline chat cache', () {
    test('message cache JSON keeps decrypted text + pending flag', () {
      final message = plainMessage(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'user-1',
        text: 'hello offline',
      ).copyWith(pending: true);
      final restored = DmMessage.fromCacheJson(message.toCacheJson());
      expect(restored.id, 'm1');
      expect(restored.displayText, 'hello offline');
      expect(restored.decryptedText, 'hello offline');
      expect(restored.pending, isTrue);
    });

    test('merge: server wins, unmatched pending stays, matched pending drops', () {
      final now = DateTime.utc(2026, 11, 19, 10, 0);
      final server = [
        plainMessage(
          id: 'srv-1',
          conversationId: 'c1',
          senderId: 'user-1',
          text: 'hi',
          createdAt: now,
        ),
      ];
      final pendingSame = plainMessage(
        id: 'pending_1',
        conversationId: 'c1',
        senderId: 'user-1',
        text: 'hi',
        createdAt: now.add(const Duration(seconds: 5)),
      ).copyWith(pending: true);
      final pendingOther = plainMessage(
        id: 'pending_2',
        conversationId: 'c1',
        senderId: 'user-1',
        text: 'still offline',
        createdAt: now.add(const Duration(seconds: 10)),
      ).copyWith(pending: true);
      // The replayed send landed on the server within 120s of the
      // offline tap — the pending copy must not duplicate it.
      final merged = mergeCachedMessages(
        server: server,
        cached: [pendingSame, pendingOther],
      );
      expect(merged.map((m) => m.id), ['srv-1', 'pending_2']);
      // Nothing on the server yet — both pending messages stay.
      final mergedEmpty = mergeCachedMessages(
        server: [],
        cached: [pendingSame, pendingOther],
      );
      expect(mergedEmpty.map((m) => m.id), ['pending_1', 'pending_2']);
    });

    test('listMessages caches, listMessagesCached reads without server', () async {
      final db = _FakeDB();
      final service = MessagingService(db: db);
      asUser('user-1');
      await seedDm(db, 'c-cache');
      await seedPlainMessage(db, 'msg-1', 'c-cache', 'user-2', 'Hello');
      await seedPlainMessage(db, 'msg-2', 'c-cache', 'user-1', 'Hi back');
      final server = await service.listMessages('c-cache');
      expect(server.length, 2);
      await settle();
      final cached = await service.listMessagesCached('c-cache');
      expect(cached.map((m) => m.id), ['msg-1', 'msg-2']);
      expect(cached.map((m) => m.displayText), ['Hello', 'Hi back']);
    });

    test('listMyConversations caches, cached list renders the same row', () async {
      final db = _FakeDB();
      final service = MessagingService(db: db);
      asUser('user-1');
      await seedDm(db, 'c-list');
      await seedPlainMessage(db, 'msg-1', 'c-list', 'user-2', 'Hello');
      final server = await service.listMyConversations();
      expect(server.map((i) => i.conversation.id), ['c-list']);
      await settle();
      final cached = await service.listMyConversationsCached();
      expect(cached.map((i) => i.conversation.id), ['c-list']);
      expect(cached.first.unread, server.first.unread);
    });

    test('cached messages cap at the newest 50', () async {
      final store = await LocalStore.getInstance();
      final messages = List.generate(
        60,
        (i) => plainMessage(
          id: 'm$i',
          conversationId: 'c-cap',
          senderId: 'user-1',
          text: 'msg $i',
        ).toCacheJson(),
      );
      await store.saveCachedChatMessages('user-1', 'c-cap', messages);
      final entries = store.loadCachedChatMessageEntries('user-1');
      final entry = entries.firstWhere(
        (e) => e['conversationId'] == 'c-cap',
      );
      final saved = entry['messages'] as List<dynamic>;
      expect(saved.length, 50);
      expect((saved.first as Map)['id'], 'm10');
      expect((saved.last as Map)['id'], 'm59');
    });
  });

  // -- FIX 1: offline send + outbox drain -------------------------------
  group('offline send + outbox drain', () {
    late _FakeDB db;
    late MessagingService service;

    setUp(() async {
      db = _FakeDB();
      service = MessagingService(db: db);
      asUser('user-1');
      final store = await LocalStore.getInstance();
      await store.saveOutbox([]);
      SyncService.debugMessagingService = service;
      SyncService.instance.debugSetOnlineForTest(true);
    });

    tearDown(() {
      SyncService.debugMessagingService = null;
    });

    test('queueOfflineText shows pending now and enqueues the op', () async {
      await seedDm(db, 'c-offline');
      final pending = await service.queueOfflineText(
        'c-offline',
        'hello offline',
      );
      expect(pending.pending, isTrue);
      expect(pending.displayText, 'hello offline');
      final store = await LocalStore.getInstance();
      final ops = store.loadOutbox();
      expect(ops.length, 1);
      expect(ops.first['kind'], 'chat_send');
      expect(ops.first['text'], 'hello offline');
      expect(ops.first['localId'], pending.id);
      final cached = await service.listMessagesCached('c-offline');
      expect(cached.map((m) => m.id), [pending.id]);
    });

    test('syncNow drains the queued message and the cache heals', () async {
      await seedDm(db, 'c-drain');
      final pending = await service.queueOfflineText(
        'c-drain',
        'hello offline',
      );
      await SyncService.instance.syncNow();
      final store = await LocalStore.getInstance();
      expect(store.loadOutbox(), isEmpty);
      expect(db.rowCount('messages'), 1);
      // The server row is back; the pending copy must not
      // duplicate it on the next load.
      final server = await service.listMessages('c-drain');
      expect(server.length, 1);
      expect(server.first.pending, isFalse);
      expect(server.first.displayText, 'hello offline');
      await settle();
      final cached = await service.listMessagesCached('c-drain');
      expect(cached.length, 1);
      expect(cached.first.id, isNot(pending.id));
    });
  });

  // -- FIX 2: typing indicator ------------------------------------------
  group('typing indicator', () {
    test('shouldPublishTyping: first keystroke yes, then throttled', () {
      final now = DateTime.utc(2026, 11, 19, 10, 0);
      expect(shouldPublishTyping(lastPublished: null, now: now), isTrue);
      expect(
        shouldPublishTyping(
          lastPublished: now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isFalse,
      );
      expect(
        shouldPublishTyping(
          lastPublished: now.subtract(const Duration(seconds: 3)),
          now: now,
        ),
        isTrue,
      );
    });

    test('freshTypingUserIds: fresh only, never me, deduped', () {
      final now = DateTime.utc(2026, 11, 19, 10, 0);
      final rows = [
        TypingState(
          userId: 'user-2',
          updatedAt: now.subtract(const Duration(seconds: 2)),
        ),
        TypingState(
          userId: 'user-3',
          updatedAt: now.subtract(const Duration(seconds: 10)),
        ),
        TypingState(userId: 'user-1', updatedAt: now),
        TypingState(
          userId: 'user-2',
          updatedAt: now.subtract(const Duration(seconds: 1)),
        ),
      ];
      expect(
        freshTypingUserIds(rows: rows, myId: 'user-1', now: now),
        ['user-2'],
      );
    });

    test('typingLabel: one, two, many', () {
      expect(typingLabel([]), '');
      expect(typingLabel(['Asha']), 'Asha is typing…');
      expect(typingLabel(['Asha', 'Ravi']), 'Asha and Ravi are typing…');
      expect(
        typingLabel(['Asha', 'Ravi', 'Meera']),
        '3 people are typing…',
      );
    });

    test('publish/fetch/clear round-trip, throttled, per-user rows', () async {
      final db = _FakeDB();
      final typing = TypingService(db: db);
      asUser('user-1');
      await typing.publishTyping('c1');
      expect(db.rowCount('typing_status'), 1);
      // A second publish 0s later is throttled — still one row.
      await typing.publishTyping('c1');
      expect(db.rowCount('typing_status'), 1);
      var rows = await typing.fetchTyping('c1');
      expect(rows.map((r) => r.userId), ['user-1']);
      // A second user gets their own row (shared-device keying).
      asUser('user-2');
      await typing.publishTyping('c1');
      expect(db.rowCount('typing_status'), 2);
      rows = await typing.fetchTyping('c1');
      expect(rows.map((r) => r.userId).toSet(), {'user-1', 'user-2'});
      // Clearing only clears MY row.
      await typing.clearTyping('c1');
      rows = await typing.fetchTyping('c1');
      expect(rows.map((r) => r.userId), ['user-1']);
      asUser('user-1');
      await typing.clearTyping('c1');
      expect(db.rowCount('typing_status'), 0);
    });
  });

  // -- imgbb key wired (mocked upload) ----------------------------------
  group('imgbb upload (mocked)', () {
    test('the key is set — image attachments are configured', () {
      expect(isImgbbConfigured, isTrue);
    });

    test('upload returns the public URL + delete URL', () async {
      var keySent = '';
      // MockClient.streaming (not the plain MockClient): the plain
      // one rebuilds the request as a generic http.Request, losing
      // the multipart fields; streaming passes the original
      // MultipartRequest through.
      final client = MockClient.streaming((request, bodyStream) async {
        final multipart = request as http.MultipartRequest;
        keySent = multipart.fields['key'] ?? '';
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'success': true,
                'data': {
                  'url': 'https://i.ibb.co/test.jpg',
                  'delete_url': 'https://ibb.co/delete/abc',
                },
              }),
            ),
          ),
          200,
        );
      });
      final upload = await uploadImageToImgbb(
        [1, 2, 3],
        filename: 'photo.png',
        contentType: 'image/png',
        client: client,
      );
      expect(upload.url, 'https://i.ibb.co/test.jpg');
      expect(upload.deleteUrl, 'https://ibb.co/delete/abc');
      // The configured key is what goes on the wire.
      expect(keySent, imgbbApiKey);
      expect(keySent, isNotEmpty);
    });

    test('a failed upload throws instead of returning a bad URL', () async {
      final client = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'success': false,
            'error': {'message': 'bad key'},
          }),
          400,
        );
      });
      await expectLater(
        uploadImageToImgbb([1, 2, 3], client: client),
        throwsA(isA<Exception>()),
      );
    });
  });
}
