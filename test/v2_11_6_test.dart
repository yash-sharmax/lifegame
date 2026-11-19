/// v2.11.6 tests — the two live-retest FAILs from v2.11.5.
///
/// FAIL A: the DM still opened to a ~5s blank loading screen on every
/// open, cache or not. Root cause: `_open()` awaited markRead +
/// settings + title (three sequential Appwrite round trips) BEFORE
/// calling `_loadMessages`, where the v2.11.5 cache read lives — the
/// cache was never reached in time. The widget test below proves the
/// open flow paints cached messages while every network call is still
/// pending (it fails on the old order: markRead hangs first, so the
/// cache is never read and the spinner stays up).
///
/// FAIL B: typing publish never wrote rows. Root cause: the v2.11.5
/// publish was gated behind a `listRows` lookup — a failing read
/// silently aborted the publish before any write was attempted, and
/// the blanket try/catch hid it (the fake never throws, so the
/// v2.11.5 test passed). v2.11.6 writes first (createRow) and only
/// falls back to the lookup to adopt an unknown row; a failed publish
/// is now visible via [TypingService.lastPublishError]. There is no
/// accepted-status gate anywhere in this path — typing works in a
/// pending-request DM exactly like any other chat, and the test
/// publishes for one.
///
/// No Appwrite, no network. Service behaviour runs against an
/// in-memory fake TablesDB.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/messaging_models.dart';
import 'package:lifegame/data/messaging_service.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/data/typing_service.dart';
import 'package:lifegame/screens/chat_screen.dart';
import 'package:lifegame/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [Client] that never talks to anything.
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

/// Compact in-memory [TablesDB]: equal / limit, plus failure flags
/// and a create-call log so tests can assert the exact write the
/// service attempted (table id + attribute names + values).
class _FakeDB extends TablesDB {
  _FakeDB() : super(_StubClient());

  final Map<String, Map<String, _Row>> _tables = {};
  int _seq = 0;

  /// When true, every listRows call throws (a failing read live).
  bool failListRows = false;

  /// When true, every createRow call throws.
  bool failCreate = false;

  /// Every createRow attempt: {'tableId', 'rowId', 'data'}.
  final List<Map<String, dynamic>> creates = [];

  Map<String, _Row> _rowsOf(String tableId) =>
      _tables.putIfAbsent(tableId, () => {});

  String _now() {
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
    creates.add({
      'tableId': tableId,
      'rowId': rowId,
      'data': Map<String, dynamic>.from(data),
    });
    if (failCreate) {
      throw AppwriteException('create failed', 500, 'create_failed');
    }
    final rows = _rowsOf(tableId);
    final id = rowId == 'unique()' ? 'row_${_seq++}' : rowId;
    if (rows.containsKey(id)) {
      throw AppwriteException(
        'Row already exists',
        409,
        'document_already_exists',
      );
    }
    final row = _Row(
      id: id,
      createdAt: _now(),
      data: Map<String, dynamic>.from(data),
    );
    rows[id] = row;
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
    if (failListRows) {
      throw AppwriteException('list failed', 500, 'list_failed');
    }
    var rows = _rowsOf(tableId).values.toList();
    var limit = 25;
    for (final q in queries ?? const <String>[]) {
      final parsed = jsonDecode(q) as Map<String, dynamic>;
      final method = parsed['method'] as String;
      final attribute = parsed['attribute'] as String?;
      final values = (parsed['values'] as List?) ?? const [];
      switch (method) {
        case 'equal':
          rows = rows
              .where((r) => values.contains(r.data[attribute]))
              .toList();
        case 'limit':
          limit = values.first as int;
      }
    }
    final page = rows.take(limit).toList();
    return models.RowList(
      total: rows.length,
      rows: page.map((r) => _toRow(tableId, r)).toList(),
    );
  }

  int rowCount(String tableId) => _rowsOf(tableId).length;

  List<_Row> rowsOf(String tableId) => _rowsOf(tableId).values.toList();
}

/// A [MessagingService] whose network calls never complete — the
/// live DM open, where markRead + settings + title each take ~1s.
/// The real [MessagingService.listMessagesCached] still runs, so the
/// test proves the cached messages paint without the network.
class _HangingMessagingService extends MessagingService {
  @override
  Future<void> markRead(String conversationId) =>
      Completer<void>().future;

  @override
  Future<ChatSettings> settingsFor(String conversationId) =>
      Completer<ChatSettings>().future;

  @override
  Future<List<ConversationMember>> memberRows(String conversationId) =>
      Completer<List<ConversationMember>>().future;

  @override
  Future<List<DmMessage>> listMessages(
    String conversationId, {
    int limit = 200,
  }) => Completer<List<DmMessage>>().future;
}

void main() {
  SharedPreferences.setMockInitialValues({});

  void asUser(String uid) {
    AuthRepository.debugSetCachedUserForTest(
      AppAuthUser(uid: uid, email: '$uid@example.com'),
    );
  }

  group('FAIL A: DM opens from the cache without the network', () {
    testWidgets('cached messages paint while network calls hang',
        (tester) async {
      asUser('user-1');
      // Seed the real offline cache with one message in the DM,
      // exactly as listMessages would have cached it.
      final store = await LocalStore.getInstance();
      final cached = DmMessage(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'user-2',
        createdAt: DateTime.utc(2026, 11, 19, 12, 0),
        expiresAt: DateTime.utc(2026, 11, 20, 0, 0),
        type: 'text',
        text: 'Test message from demo',
        decryptedText: 'Test message from demo',
      );
      await store.saveCachedChatMessages('user-1', 'c1', [
        cached.toCacheJson(),
      ]);

      // The live DM: a pending message request, like the one the
      // user tests in.
      final conversation = Conversation(
        id: 'c1',
        type: 'dm',
        createdBy: 'user-1',
        createdAt: DateTime.utc(2026, 11, 19, 11, 0),
        status: 'requested',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            conversation: conversation,
            service: _HangingMessagingService(),
          ),
        ),
      );
      // Let the cache read land (SharedPreferences is async). The
      // network calls never complete — on the old open order the
      // spinner would stay up forever and this text would never
      // appear.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      // The bubble renders via RichText, so findRichText is needed.
      expect(
        find.text('Test message from demo', findRichText: true),
        findsOneWidget,
      );
      expect(find.byType(LoadingIcon), findsNothing);
    });
  });

  group('FAIL B: typing publish writes without a read gate', () {
    test('publish writes even when the lookup fails (create-first)',
        () async {
      final db = _FakeDB()..failListRows = true;
      final typing = TypingService(db: db);
      asUser('user-1');
      await typing.publishTyping('c1');
      // The write happened despite the failing read — and it used
      // the real table/attribute names.
      expect(db.rowCount('typing_status'), 1);
      expect(db.creates, hasLength(1));
      final create = db.creates.single;
      expect(create['tableId'], 'typing_status');
      final data = create['data'] as Map<String, dynamic>;
      expect(data['conversationId'], 'c1');
      expect(data['userId'], 'user-1');
      expect(data['updatedAt'], isA<String>());
      expect(typing.lastPublishError, isNull);
    });

    test('publish works in a pending-request DM (no status gate)',
        () async {
      final db = _FakeDB();
      final typing = TypingService(db: db);
      asUser('user-1');
      // The service never looks at the conversation status — the
      // pending-request DM the user tests in publishes exactly like
      // any other chat.
      await typing.publishTyping('pending-dm-1');
      expect(db.rowCount('typing_status'), 1);
      final rows = await typing.fetchTyping('pending-dm-1');
      expect(rows.map((r) => r.userId), ['user-1']);
    });

    test('publish/fetch/clear round-trip still works (restructure)',
        () async {
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
      // Clearing only clears MY rows.
      await typing.clearTyping('c1');
      rows = await typing.fetchTyping('c1');
      expect(rows.map((r) => r.userId), ['user-1']);
      asUser('user-1');
      await typing.clearTyping('c1');
      expect(db.rowCount('typing_status'), 0);
    });

    test('clearTyping deletes ALL my rows, not just the known one',
        () async {
      final db = _FakeDB();
      final typing = TypingService(db: db);
      // Two rows for user-1 (e.g. typed, restarted mid-typing,
      // typed again) and one for user-2 — none known to this
      // service instance.
      for (final id in ['r1', 'r2']) {
        await db.createRow(
          databaseId: 'lifegame',
          tableId: 'typing_status',
          rowId: id,
          data: {
            'conversationId': 'c1',
            'userId': 'user-1',
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
          },
        );
      }
      await db.createRow(
        databaseId: 'lifegame',
        tableId: 'typing_status',
        rowId: 'r3',
        data: {
          'conversationId': 'c1',
          'userId': 'user-2',
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        },
      );
      asUser('user-1');
      await typing.clearTyping('c1');
      expect(
        db
            .rowsOf('typing_status')
            .map((r) => r.data['userId'])
            .toList(),
        ['user-2'],
      );
    });

    test('lastPublishError: null after success, set after failure',
        () async {
      final failingDb = _FakeDB()
        ..failCreate = true
        ..failListRows = true;
      final failing = TypingService(db: failingDb);
      asUser('user-1');
      await failing.publishTyping('c1');
      expect(failing.lastPublishError, isNotNull);
      expect(failingDb.rowCount('typing_status'), 0);

      final working = TypingService(db: _FakeDB());
      await working.publishTyping('c1');
      expect(working.lastPublishError, isNull);
    });
  });
}
