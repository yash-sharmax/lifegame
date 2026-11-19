/// v2.11.2 tests — the bugs the user reported live on 19 Nov 2026
/// ("fix all bugs"): duplicate DM, hidden-chat reveal, phantom
/// undecryptable bubble, IST/UTC timestamps, stale list previews,
/// missing request banner, the reminders-smart failures, the
/// bubble lock icon removal (no test — pure UI), and Find People
/// returning nothing.
///
/// Pure rules are tested directly; service behaviour (startDm race,
/// listMessages filter, search) runs against the same in-memory
/// fake TablesDB the v2.9.0 tests use. No Appwrite, no network.
library;

import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/messaging_models.dart';
import 'package:lifegame/data/messaging_service.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/reminder_service.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/logic/chat_reminders.dart';
import 'package:lifegame/logic/ist_time.dart';
import 'package:lifegame/screens/chats_screen.dart';
import 'package:lifegame/screens/reminders_screen.dart';
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

/// Compact in-memory [TablesDB] (same shape as the v2.9.0 fake):
/// equal / startsWith / orderAsc / orderDesc / limit / offset.
class _FakeDB extends TablesDB {
  _FakeDB() : super(_StubClient());

  final Map<String, Map<String, _Row>> _tables = {};
  int _seq = 0;

  Map<String, _Row> _rowsOf(String tableId) =>
      _tables.putIfAbsent(tableId, () => {});

  String _now() {
    final stamp = DateTime.utc(2026, 1, 1).add(Duration(milliseconds: _seq++));
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

  // -- A.1: the exact failures from the user's screenshots ------------
  // Reference moment: 19 Nov 2026, ~3:09 PM IST (Asia/Kolkata).
  group('reminder parsing — bare times, dot times, corrections', () {
    test('"remind me to drink water at 3:09" at 3:00 PM means 3:09 PM today', () {
      final now = DateTime(2026, 11, 19, 15, 0);
      final parsed = parseChatReminder(
        'remind me to drink water at 3:09',
        now,
      );
      expect(parsed, isNotNull);
      expect(parsed!.when, DateTime(2026, 11, 19, 15, 9));
      expect(parsed.text, 'Drink water');
    });

    test('a bare PM time already past today rolls to tomorrow — still PM', () {
      final now = DateTime(2026, 11, 19, 15, 10);
      final parsed = parseChatReminder(
        'remind me to drink water at 3:09',
        now,
      );
      expect(parsed, isNotNull);
      // Tomorrow at 3:09 PM — never silently 3:09 AM.
      expect(parsed!.when, DateTime(2026, 11, 20, 15, 9));
      expect(parsed.text, 'Drink water');
    });

    test('"remind me to drink water at 3.08pm" parses the dot time', () {
      final now = DateTime(2026, 11, 19, 15, 0);
      final parsed = parseChatReminder(
        'remind me to drink water at 3.08pm',
        now,
      );
      expect(parsed, isNotNull);
      expect(parsed!.when, DateTime(2026, 11, 19, 15, 8));
      expect(parsed.text, 'Drink water');
    });

    test('dot-time variants: "3:08pm", "3.08 pm", "3:08" (bare → PM)', () {
      final now = DateTime(2026, 11, 19, 15, 0);
      expect(
        parseChatReminder('remind me to drink water at 3:08pm', now)!.when,
        DateTime(2026, 11, 19, 15, 8),
      );
      expect(
        parseChatReminder('remind me to drink water at 3.08 pm', now)!.when,
        DateTime(2026, 11, 19, 15, 8),
      );
      expect(
        parseChatReminder('remind me to drink water at 3:08', now)!.when,
        DateTime(2026, 11, 19, 15, 8),
      );
      expect(
        parseChatReminder('remind me to drink water at 3.08', now)!.text,
        'Drink water',
      );
    });

    test('a bare morning time means AM in the morning', () {
      final now = DateTime(2026, 11, 19, 8, 0);
      final parsed = parseChatReminder(
        'remind me to drink water at 9:30',
        now,
      );
      expect(parsed, isNotNull);
      expect(parsed!.when, DateTime(2026, 11, 19, 9, 30));
      expect(parsed.text, 'Drink water');
    });

    test('explicit am/pm and 24-hour times are untouched', () {
      final now = DateTime(2026, 11, 19, 15, 0);
      expect(
        parseChatReminder('Buy milk at 6pm', now)!.when,
        DateTime(2026, 11, 19, 18, 0),
      );
      expect(
        parseChatReminder('Call mom at 18:00', now)!.when,
        DateTime(2026, 11, 19, 18, 0),
      );
      expect(
        parseChatReminder('Buy milk at 6am', now)!.when,
        DateTime(2026, 11, 20, 6, 0),
      );
    });

    test('the old dot-time regression: "12.26am 19nov" still parses', () {
      final now = DateTime(2026, 11, 18, 19, 30);
      final parsed = parseChatReminder(
        'checking messages remind me at 12.26am 19nov',
        now,
      );
      expect(parsed, isNotNull);
      expect(parsed!.when, DateTime(2026, 11, 19, 0, 26));
      expect(parsed.text, 'Checking messages');
    });
  });

  group('corrections — edit the last reminder, never a new one', () {
    test('"not 8 it\'s 3:08pm" is a correction with no new task', () {
      expect(looksLikeCorrection("not 8 it's 3:08pm"), isTrue);
      expect(correctionTaskText("not 8 it's 3:08pm"), isEmpty);
      // …and the time in it still parses to 3:08 PM.
      final parsed = parseChatReminder(
        "not 8 it's 3:08pm",
        DateTime(2026, 11, 19, 15, 0),
      );
      expect(parsed, isNotNull);
      expect(parsed!.when, DateTime(2026, 11, 19, 15, 8));
    });

    test('a correction carrying a new task keeps the task', () {
      expect(looksLikeCorrection('no, I meant call mom at 4pm'), isTrue);
      expect(
        correctionTaskText('no, I meant call mom at 4pm'),
        'Call mom',
      );
    });

    test('ordinary messages are not corrections', () {
      expect(looksLikeCorrection('remind me to drink water at 3:09'), isFalse);
      expect(looksLikeCorrection('Buy milk at 6pm'), isFalse);
      expect(looksLikeCorrection('not now'), isFalse);
    });
  });

  group('ambiguity + clear task', () {
    // v2.11.3: the Tip rule changed — the tip NEVER appears on a
    // successful set (not even for a bare time). reminderParseWasAmbiguous
    // is deleted; the no-Tip rule is covered by the v2.11.3 widget
    // test (a successful set shows the confirmation and no Tip).

    test('a message with no clear task is not a task', () {
      expect(hasClearTask('Drink water'), isTrue);
      expect(hasClearTask(''), isFalse);
      expect(hasClearTask('5'), isFalse);
      expect(hasClearTask('  '), isFalse);
    });
  });

  // -- FIX 4: chat timestamps are device-local --------------------------
  group('chat timestamps (FIX 4)', () {
    test('the same instant formats the same from UTC and IST notations', () {
      final fromUtc = formatChatTime(
        DateTime.parse('2026-11-19T09:32:00.000Z'),
      );
      final fromIst = formatChatTime(
        DateTime.parse('2026-11-19T15:02:00.000+05:30'),
      );
      // Both are 09:32 UTC = 15:02 IST — one instant, one label.
      expect(fromUtc, fromIst);
      expect(fromUtc, '9:32 AM');
    });

    test('yesterday still reads "Yesterday"', () {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      expect(formatChatTime(yesterday), 'Yesterday');
    });
  });

  // -- FIX 2: hidden-chat reveal ----------------------------------------
  group('hidden-chat reveal filter (FIX 2)', () {
    ConversationItem item(String id) => ConversationItem(
      conversation: Conversation(
        id: id,
        type: 'dm',
        createdBy: 'user-1',
        createdAt: DateTime(2026, 11, 19),
      ),
      unread: false,
      otherUserId: 'user-2',
    );

    test('typing the exact keyword shows the hidden chats, unfiltered', () {
      final items = [item('c1'), item('c2')];
      final visible = visibleChatItems(
        items: items,
        query: 'pineapple',
        revealActive: true,
        nameFor: (_) => 'Yash Sharma',
      );
      expect(visible.length, 2);
    });

    test('a plain name search still filters by name', () {
      final items = [item('c1'), item('c2')];
      final visible = visibleChatItems(
        items: items,
        query: 'yash',
        revealActive: false,
        nameFor: (i) => i.conversation.id == 'c1' ? 'Yash Sharma' : 'Muse Demo',
      );
      expect(visible.map((i) => i.conversation.id), ['c1']);
    });

    test('an empty query shows everything', () {
      final items = [item('c1')];
      expect(
        visibleChatItems(
          items: items,
          query: '',
          revealActive: false,
          nameFor: (_) => 'Yash Sharma',
        ).length,
        1,
      );
    });
  });

  // -- FIX 3 / FIX 5 / FIX 6: pure message rules ------------------------
  group('establishment, preview, request banner (FIX 3/5/6)', () {
    DmMessage msg({
      String id = 'm1',
      bool encrypted = false,
      String? ciphertext,
      String? encryptedKeys,
      String? text,
      String? decryptedText,
      bool isImage = false,
      bool isViewOnce = false,
      bool deletedForAll = false,
    }) => DmMessage(
      id: id,
      conversationId: 'c1',
      senderId: 'user-1',
      createdAt: DateTime(2026, 11, 19, 15, 0),
      expiresAt: DateTime(2026, 11, 20, 3, 0),
      type: isImage ? 'image' : 'text',
      text: text,
      encrypted: encrypted,
      ciphertext: ciphertext,
      encryptedKeys: encryptedKeys,
      isViewOnce: isViewOnce,
      deletedForAll: deletedForAll,
      decryptedText: decryptedText,
    );

    test('an epoch carrier is an establishment message; legacy is not', () {
      expect(
        msg(
          encrypted: true,
          ciphertext: 'v2:1:AAAA:BBBB:CCCC',
          encryptedKeys: '{"user-1":"xxx"}',
        ).isEstablishment,
        isTrue,
      );
      expect(
        msg(
          encrypted: true,
          ciphertext: 'aabbcc:ddeeff',
          encryptedKeys: '{"user-1":"xxx"}',
        ).isEstablishment,
        isFalse,
      );
      expect(msg(text: 'hello').isEstablishment, isFalse);
    });

    test('preview shows decrypted text, honest labels otherwise', () {
      expect(chatPreviewForMessage(msg(text: 'hello')), 'hello');
      expect(
        chatPreviewForMessage(
          msg(encrypted: true, decryptedText: 'secret hello'),
        ),
        'secret hello',
      );
      expect(
        chatPreviewForMessage(msg(encrypted: true)),
        'Encrypted message',
      );
      expect(chatPreviewForMessage(msg(isImage: true)), 'Photo');
      expect(
        chatPreviewForMessage(msg(isImage: true, isViewOnce: true)),
        'View once photo',
      );
      expect(
        chatPreviewForMessage(msg(deletedForAll: true)),
        'This message was deleted',
      );
    });

    test('request banner: waiting when I sent it, decision when I got it', () {
      Conversation conv({String status = 'active', String createdBy = 'user-1'}) =>
          Conversation(
            id: 'c1',
            type: 'dm',
            createdBy: createdBy,
            createdAt: DateTime(2026, 11, 19),
            status: status,
          );
      expect(
        requestBannerFor(conversation: conv(), myId: 'user-1'),
        isNull,
      );
      expect(
        requestBannerFor(
          conversation: conv(status: 'requested', createdBy: 'user-1'),
          myId: 'user-1',
        ),
        RequestBanner.waiting,
      );
      expect(
        requestBannerFor(
          conversation: conv(status: 'requested', createdBy: 'user-2'),
          myId: 'user-1',
        ),
        RequestBanner.decision,
      );
    });
  });

  // -- FIX 1: duplicate DM ----------------------------------------------
  group('duplicate DM + race-safe startDm (FIX 1)', () {
    late _FakeDB db;
    late MessagingService service;

    setUp(() {
      db = _FakeDB();
      service = MessagingService(db: db);
      asUser('user-1');
    });

    Future<void> seedFollow(String follower, String following) async {
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'follows',
        rowId: 'f_${follower}_$following',
        data: {
          'followerUid': follower,
          'followingUid': following,
          'status': 'accepted',
        },
      );
    }

    test('two rapid concurrent startDm calls create ONE conversation', () async {
      await seedFollow('user-1', 'user-2');
      final results = await Future.wait([
        service.startDm('user-2'),
        service.startDm('user-2'),
      ]);
      expect(results[0].id, results[1].id);
      expect(db.rowCount('conversations'), 1);
    });

    test('a second startDm reopens the same DM', () async {
      await seedFollow('user-1', 'user-2');
      final first = await service.startDm('user-2');
      final second = await service.startDm('user-2');
      expect(second.id, first.id);
      expect(db.rowCount('conversations'), 1);
    });

    test('listMyConversations dedupes duplicate member rows', () async {
      await seedFollow('user-1', 'user-2');
      final conv = await service.startDm('user-2');
      // A duplicated member row for the same conversation (the live
      // duplicate-DM shape) must not render a second list row.
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'conversation_members',
        rowId: 'dup-member-row',
        data: {
          'conversationId': conv.id,
          'userId': 'user-1',
          'role': 'member',
          'joinedAt': '2026-11-19T10:00:00.000Z',
          'lastReadAt': null,
        },
      );
      final items = await service.listMyConversations();
      expect(items.map((i) => i.conversation.id), [conv.id]);
    });
  });

  // -- FIX 3: phantom establishment bubble -------------------------------
  group('phantom establishment bubble (FIX 3)', () {
    late _FakeDB db;
    late MessagingService service;

    setUp(() {
      db = _FakeDB();
      service = MessagingService(db: db);
      asUser('user-1');
    });

    Future<void> seedDmWithMessages() async {
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'conversations',
        rowId: 'c1',
        data: {
          'type': 'dm',
          'title': null,
          'createdBy': 'user-1',
          'createdAt': '2026-11-19T09:00:00.000Z',
          'lastMessageAt': '2026-11-19T10:02:00.000Z',
          'lastMessagePreview': 'Encrypted message',
          'status': 'active',
        },
      );
      for (final uid in ['user-1', 'user-2']) {
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'conversation_members',
          rowId: 'm_$uid',
          data: {
            'conversationId': 'c1',
            'userId': uid,
            'role': 'member',
            'joinedAt': '2026-11-19T09:00:00.000Z',
            'lastReadAt': null,
          },
        );
      }
      // The epoch establishment carrier: undecryptable on this
      // device (no keys in the mock prefs) — must NOT render.
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'messages',
        rowId: 'msg-est',
        data: {
          'conversationId': 'c1',
          'senderId': 'user-1',
          'type': 'text',
          'text': null,
          'createdAt': '2026-11-19T10:00:00.000Z',
          'expiresAt': '2026-11-19T22:00:00.000Z',
          'encrypted': true,
          'ciphertext': 'v2:1:AAAA:BBBB:CCCC',
          'encryptedKeys': '{"user-1":"xxx","user-2":"yyy"}',
          'deletedForAll': false,
          'isViewOnce': false,
          'viewOnceViewed': false,
          'forwarded': false,
        },
      );
      // A plain readable message — must render.
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'messages',
        rowId: 'msg-plain',
        data: {
          'conversationId': 'c1',
          'senderId': 'user-2',
          'type': 'text',
          'text': 'hello there',
          'createdAt': '2026-11-19T10:01:00.000Z',
          'expiresAt': '2026-11-19T22:01:00.000Z',
          'encrypted': false,
          'ciphertext': null,
          'encryptedKeys': null,
          'deletedForAll': false,
          'isViewOnce': false,
          'viewOnceViewed': false,
          'forwarded': false,
        },
      );
      // A legacy undecryptable message (NOT an establishment
      // carrier) — stays, with its honest label.
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'messages',
        rowId: 'msg-legacy',
        data: {
          'conversationId': 'c1',
          'senderId': 'user-2',
          'type': 'text',
          'text': null,
          'createdAt': '2026-11-19T10:02:00.000Z',
          'expiresAt': '2026-11-19T22:02:00.000Z',
          'encrypted': true,
          'ciphertext': 'aabbcc:ddeeff',
          'encryptedKeys': '{"user-1":"xxx"}',
          'deletedForAll': false,
          'isViewOnce': false,
          'viewOnceViewed': false,
          'forwarded': false,
        },
      );
    }

    test('a fresh DM shows no phantom bubble', () async {
      await seedDmWithMessages();
      final messages = await service.listMessages('c1');
      expect(messages.map((m) => m.id), ['msg-plain', 'msg-legacy']);
      // …but the establishment row is still stored (crypto intact).
      expect(db.rowCount('messages'), 3);
    });

    test('latestVisibleMessage is the newest renderable message', () async {
      await seedDmWithMessages();
      final latest = await service.latestVisibleMessage('c1');
      expect(latest?.id, 'msg-legacy');
    });
  });

  // -- FIX C: Find People --------------------------------------------------
  group('search (FIX C)', () {
    late _FakeDB db;
    late ProfileRepository profiles;

    setUp(() {
      db = _FakeDB();
      profiles = ProfileRepository(db: db);
      asUser('user-1');
    });

    Future<void> seedUser(
      String id,
      String username,
      String name, {
      bool? discoverable,
      bool withUsernamesRow = true,
    }) async {
      final userData = <String, dynamic>{
        'username': username,
        'displayName': name,
        'bio': '',
        'xp': 0,
        'currentStreak': 0,
        'longestStreak': 0,
        'lastActiveDate': null,
        'visibility': 'public',
      };
      if (discoverable != null) userData['discoverable'] = discoverable;
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'users',
        rowId: id,
        data: userData,
      );
      if (withUsernamesRow) {
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'usernames',
          rowId: 'un_$id',
          data: {'username': username, 'ownerUid': id},
        );
      }
    }

    test('finds people by username, display name, and single letters', () async {
      await seedUser('user-1', 'tester', 'Tester');
      await seedUser('user-2', 'yashsharma', 'Yash Sharma');
      await seedUser('user-3', 'muse_demo', 'Muse Demo');
      await seedUser('user-4', 'rishikaa', 'Rishikaa', discoverable: false);
      expect(
        (await profiles.searchProfiles('yashsharma')).map((p) => p.username),
        ['yashsharma'],
      );
      expect(
        (await profiles.searchProfiles('Yash')).map((p) => p.username),
        ['yashsharma'],
      );
      expect(
        (await profiles.searchProfiles('Sharma')).map((p) => p.username),
        ['yashsharma'],
      );
      expect(
        (await profiles.searchProfiles('muse')).map((p) => p.username),
        ['muse_demo'],
      );
      // 'a' matches yashsharma (username + display name); the hidden
      // rishikaa stays out.
      expect(
        (await profiles.searchProfiles('a')).map((p) => p.username),
        ['yashsharma'],
      );
      expect(await profiles.searchProfiles('zzz'), isEmpty);
      expect(await profiles.searchProfiles(''), isEmpty);
    });

    test('finds a user whose usernames row is missing', () async {
      await seedUser('user-1', 'tester', 'Tester');
      await seedUser(
        'user-5',
        'amit',
        'Amit',
        withUsernamesRow: false,
      );
      expect(
        (await profiles.searchProfiles('amit')).map((p) => p.username),
        ['amit'],
      );
    });
  });

  // -- A.2/A.3: reminder firing posts the chat message ---------------------
  group('reminder firing (A.2/A.3)', () {
    test('an overdue reminder fires on refresh: chat message + out of Active',
        () async {
      asUser('user-1');
      final store = await LocalStore.getInstance();
      // v2.11.3: fixtures are IST wall times, like stored data.
      final past = istNow().subtract(const Duration(minutes: 5));
      await store.saveChatReminders([
        ChatReminder(
          id: 'r1',
          ownerId: 'user-1',
          text: 'Drink water',
          scheduledAt: past,
          createdAt: past,
        ),
      ]);
      await store.saveChatMessages('user-1', []);
      // Start/resume due-check (the same path the 30s timer uses).
      await ReminderService.instance.refresh();
      final reminders = store.loadChatReminders('user-1');
      expect(reminders.single.fired, isTrue);
      final messages = store.loadChatMessages('user-1');
      expect(
        messages.any((m) => m.text == 'Reminder: Drink water'),
        isTrue,
      );
      // A future reminder does NOT fire.
      final future = istNow().add(const Duration(hours: 2));
      await store.saveChatReminders([
        ChatReminder(
          id: 'r2',
          ownerId: 'user-1',
          text: 'Call mom',
          scheduledAt: future,
          createdAt: istNow(),
        ),
      ]);
      await ReminderService.instance.refresh();
      expect(store.loadChatReminders('user-1').single.fired, isFalse);
      expect(
        store
            .loadChatMessages('user-1')
            .any((m) => m.text == 'Reminder: Call mom'),
        isFalse,
      );
    });
  });

  // -- A.4: Active reminders collapsible -----------------------------------
  group('Active reminders section (A.4)', () {
    testWidgets('collapsed by default, expands on tap', (tester) async {
      asUser('user-1');
      final store = await LocalStore.getInstance();
      final future = istNow().add(const Duration(hours: 2));
      await store.saveChatReminders([
        ChatReminder(
          id: 'r1',
          ownerId: 'user-1',
          text: 'Drink water',
          scheduledAt: future,
          createdAt: istNow(),
        ),
      ]);
      await store.saveChatMessages('user-1', []);
      await tester.pumpWidget(
        const MaterialApp(home: RemindersScreen()),
      );
      await tester.pumpAndSettle();
      expect(find.text('Active reminders (1)'), findsOneWidget);
      expect(find.textContaining('Drink water'), findsNothing);
      await tester.tap(find.text('Active reminders (1)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Drink water'), findsWidgets);
    });
  });
}
