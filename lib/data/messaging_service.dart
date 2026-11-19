/// Messaging service (v2.11.0): conversations, messages, requests,
/// stars, settings — all Appwrite-backed.
///
/// Tables (see scripts/setup_appwrite.mjs): `conversations`,
/// `conversation_members`, `messages`, `starred_messages`,
/// `chat_settings`. Row security is ON and rows inherit the tables'
/// "any authenticated user" permissions — exactly like habits and
/// logs. The app enforces the rules (who may message whom, the
/// 12-hour expiry, the 150 cap, the 50-save cap); the E2EE layer
/// (chat_crypto.dart) is what keeps message BODIES private even
/// from someone reading the rows directly.
///
/// Graceful degradation (same pattern as v2.9.0 follows): when a
/// new table/attribute is not on the live project yet, the call
/// that needs it fails soft where possible instead of crashing the
/// whole screen — the UI then shows a plain "messaging isn't set
/// up yet" state. Text chat needs the tables; E2EE needs the
/// `users.publicKey` attribute as well.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;
import 'package:http/http.dart' as http;

import '../config.dart';
import 'appwrite_service.dart';
import 'chat_crypto.dart';
import 'chat_prefs.dart';
import 'imgbb.dart';
import 'messaging_models.dart';
import 'models.dart';
import 'png_carrier.dart';
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

/// Thrown when a message cannot be started (point 1): you must
/// follow the other person first.
class CannotMessageException implements Exception {
  const CannotMessageException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when starring would pass the 50-save free-tier cap
/// (point 7).
class SaveCapReachedException implements Exception {
  @override
  String toString() =>
      'You can save at most $kMaxSavedMessagesPerUser messages '
      '(free tier). Unstar an old one first.';
}

/// One row in the Chats list, with what the list needs to render.
class ConversationItem {
  const ConversationItem({
    required this.conversation,
    required this.unread,
    this.otherUserId,
  });

  final Conversation conversation;

  /// True when the last message arrived after I last opened it.
  final bool unread;

  /// The other person in a DM (null for groups).
  final String? otherUserId;
}

class MessagingService {
  MessagingService({this._db});

  final TablesDB? _db;

  /// In-memory cache of decrypted photo bytes (v2.11.1, image
  /// E2EE): downloading + decrypting every photo on every 15-second
  /// poll would be wasteful. Keyed by message id, capped at 20
  /// entries — the device already holds the RSA private key, so
  /// this cache does not widen the trust boundary.
  final Map<String, List<int>> _decryptedImageCache = {};
  TablesDB get _d => _requireDb(_db);

  String _myId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  // --- Encryption readiness (point 16) -------------------------------

  /// Makes sure I have an RSA keypair and my public key is on my
  /// profile row. Returns false when anything fails — messaging
  /// still works, just unencrypted (with an honest UI note).
  Future<bool> ensureEncryptionReady() async {
    try {
      final store = await ChatCryptoStore.instance();
      final pair = await store.ensureKeypair();
      if (pair == null) return false;
      final profiles = ProfileRepository(db: _db);
      final me = await profiles.fetchMyProfile();
      if (me == null) return false;
      if (me.publicKey == pair.publicKeyJson) return true;
      await profiles.updateProfile(
        displayName: me.displayName,
        bio: me.bio,
        publicKey: pair.publicKeyJson,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Public keys for [userIds] (userId → public-key JSON). Users
  /// without a key are simply absent — their messages stay
  /// unencrypted (point 16).
  Future<Map<String, String>> _publicKeysFor(List<String> userIds) async {
    final profiles = ProfileRepository(db: _db);
    final keys = <String, String>{};
    for (final id in userIds) {
      try {
        final profile = await profiles.fetchProfile(id);
        final key = profile?.publicKey;
        if (key != null && key.isNotEmpty) keys[id] = key;
      } catch (_) {}
    }
    return keys;
  }

  /// Decrypts one message for me, in place (fills decryptedText
  /// for text, decryptedImageBytes for photos). Handles both the
  /// legacy v2.11.0 per-message envelope and the v2.11.1 epoch
  /// format. A message this device cannot decrypt is returned
  /// unchanged — the UI says so honestly instead of showing
  /// garbage.
  Future<DmMessage> _decryptForMe(DmMessage message) async {
    if (!message.encrypted) return message;
    try {
      final store = await ChatCryptoStore.instance();
      final privateKey = store.privateKeyJson;
      if (privateKey == null) return message;
      final myId = _myId();
      if (message.isImage) {
        final bytes = await decryptedImageBytesFor(message);
        if (bytes == null) return message;
        return message.copyWith(decryptedImageBytes: bytes);
      }
      if (message.ciphertext == null) return message;
      final parsed = parseEpochCiphertext(message.ciphertext);
      if (parsed != null) {
        final plain = await _decryptEpochText(message, parsed, privateKey, myId);
        if (plain == null) return message;
        return message.copyWith(decryptedText: plain);
      }
      // Legacy v2.11.0 envelope: one RSA-wrapped AES key per
      // message, carried in encryptedKeys.
      if (message.encryptedKeys == null) return message;
      final plain = decryptEnvelope(
        message.ciphertext!,
        message.encryptedKeys!,
        myId,
        privateKey,
      );
      if (plain == null) return message;
      return message.copyWith(decryptedText: plain);
    } catch (_) {
      return message;
    }
  }

  /// Decrypts one epoch-format text message (v2.11.1, FIX 3). The
  /// epoch key comes from this device's store; when it is missing
  /// and this message carries the wrapped epoch key (it is the
  /// establishment message), the key is unwrapped and stored first.
  Future<String?> _decryptEpochText(
    DmMessage message,
    ({int epoch, List<int> nonce, String ivCipher}) parsed,
    String privateKey,
    String myId,
  ) async {
    final epochs = await ChatEpochStore.instance();
    var record = epochs.epoch(message.conversationId, parsed.epoch);
    if (record == null && message.encryptedKeys != null) {
      final keyBytes = epochs.unwrapEpochKey(
        message.encryptedKeys!,
        myId,
        privateKey,
      );
      if (keyBytes == null) return null;
      record = ChatEpoch(
        epoch: parsed.epoch,
        keyBase64: base64Encode(keyBytes),
        createdAt: message.createdAt,
        sentCount: 0,
        lastMessageAt: message.createdAt,
      );
      final current = epochs.currentEpoch(message.conversationId);
      if (current == null || parsed.epoch >= current.epoch) {
        await epochs.saveEpoch(message.conversationId, record);
      } else {
        await epochs.saveEpochRecord(message.conversationId, record);
      }
    }
    if (record == null) return null;
    return decryptWithEpochKey(message.ciphertext!, record.keyBytes);
  }

  /// Pre-pass for a freshly fetched message list (v2.11.1, FIX 3):
  /// unwrap + store every epoch key carried by establishment
  /// messages BEFORE decrypting anything. A starred message
  /// re-encrypted under a new epoch sits EARLIER in the list than
  /// that epoch's establishment message, so without this pass it
  /// would look undecryptable until the next refresh.
  Future<void> _establishEpochs(List<DmMessage> rows) async {
    try {
      final crypto = await ChatCryptoStore.instance();
      final privateKey = crypto.privateKeyJson;
      if (privateKey == null) return;
      final myId = _myId();
      final epochs = await ChatEpochStore.instance();
      for (final m in rows) {
        if (m.ciphertext == null || m.encryptedKeys == null) continue;
        final parsed = parseEpochCiphertext(m.ciphertext);
        if (parsed == null) continue;
        if (epochs.epoch(m.conversationId, parsed.epoch) != null) continue;
        final keyBytes = epochs.unwrapEpochKey(
          m.encryptedKeys!,
          myId,
          privateKey,
        );
        if (keyBytes == null) continue;
        final record = ChatEpoch(
          epoch: parsed.epoch,
          keyBase64: base64Encode(keyBytes),
          createdAt: m.createdAt,
          sentCount: 0,
          lastMessageAt: m.createdAt,
        );
        final current = epochs.currentEpoch(m.conversationId);
        if (current == null || parsed.epoch >= current.epoch) {
          await epochs.saveEpoch(m.conversationId, record);
        } else {
          await epochs.saveEpochRecord(m.conversationId, record);
        }
      }
    } catch (_) {}
  }

  /// Downloads + decrypts one encrypted photo for me (v2.11.1,
  /// FIX 2). Returns the original image bytes, or null when this
  /// device cannot decrypt them. Results are cached in memory so
  /// the 15-second poll does not re-download every photo.
  Future<List<int>?> decryptedImageBytesFor(DmMessage message) async {
    if (!message.isImage ||
        !message.encrypted ||
        message.imageUrl == null ||
        message.encryptedKeys == null) {
      return null;
    }
    final cached = _decryptedImageCache[message.id];
    if (cached != null) return cached;
    try {
      final store = await ChatCryptoStore.instance();
      final privateKey = store.privateKeyJson;
      if (privateKey == null) return null;
      final res = await http
          .get(Uri.parse(message.imageUrl!))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return null;
      final packed = unpackBytesFromPng(res.bodyBytes);
      if (packed == null) return null;
      final plain = decryptBytesEnvelope(
        packed,
        message.encryptedKeys!,
        _myId(),
        privateKey,
      );
      if (plain == null) return null;
      if (_decryptedImageCache.length > 20) {
        _decryptedImageCache.remove(_decryptedImageCache.keys.first);
      }
      _decryptedImageCache[message.id] = plain;
      return plain;
    } catch (_) {
      return null;
    }
  }

  // --- Conversations ---------------------------------------------------

  /// My member rows (paginated).
  Future<List<ConversationMember>> _myMemberRows() async {
    final myId = _myId();
    final rows = <ConversationMember>[];
    const page = 100;
    var offset = 0;
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'conversation_members',
        queries: [
          Query.equal('userId', myId),
          Query.limit(page),
          Query.offset(offset),
        ],
      );
      for (final doc in list.rows) {
        rows.add(ConversationMember.fromJson(_docJson(doc)));
      }
      if (list.rows.length < page) break;
      offset += page;
    }
    return rows;
  }

  /// Members of one conversation.
  Future<List<ConversationMember>> memberRows(String conversationId) async {
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'conversation_members',
      queries: [
        Query.equal('conversationId', conversationId),
        Query.limit(100),
      ],
    );
    return list.rows
        .map((doc) => ConversationMember.fromJson(_docJson(doc)))
        .toList();
  }

  /// Profiles of a conversation's members, sorted by display name.
  Future<List<Profile>> conversationMembers(String conversationId) async {
    final members = await memberRows(conversationId);
    final profiles = ProfileRepository(db: _db);
    final out = <Profile>[];
    for (final m in members) {
      final profile = await profiles.fetchProfile(m.userId);
      if (profile != null) out.add(profile);
    }
    out.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return out;
  }

  Future<Conversation?> _getConversation(String conversationId) async {
    try {
      final doc = await _d.getRow(
        databaseId: _dbId,
        tableId: 'conversations',
        rowId: conversationId,
      );
      return Conversation.fromJson(_docJson(doc));
    } catch (_) {
      return null;
    }
  }

  /// My chats, newest first — including pending requests (the UI
  /// splits those into their own section). Hidden chats are
  /// excluded unless [includeHidden] (the secret keyword was typed).
  Future<List<ConversationItem>> listMyConversations({
    bool includeHidden = false,
  }) async {
    final myId = _myId();
    final myMemberships = await _myMemberRows();
    final settings = <String, ChatSettings>{};
    if (!includeHidden) {
      for (final m in myMemberships) {
        try {
          settings[m.conversationId] = await settingsFor(m.conversationId);
        } catch (_) {}
      }
    }
    final items = <ConversationItem>[];
    // v2.11.2 FIX 1: one row per conversation, even if member rows
    // ever duplicate — a duplicated DM row in the list is what the
    // user saw live.
    final seenConversationIds = <String>{};
    for (final m in myMemberships) {
      if (!seenConversationIds.add(m.conversationId)) continue;
      if (!includeHidden && (settings[m.conversationId]?.hidden ?? false)) {
        continue;
      }
      final conversation = await _getConversation(m.conversationId);
      if (conversation == null) continue;
      final unread =
          conversation.lastMessageAt != null &&
          (m.lastReadAt == null ||
              conversation.lastMessageAt!.isAfter(m.lastReadAt!));
      String? otherUserId;
      if (!conversation.isGroup) {
        final others = await memberRows(conversation.id);
        for (final o in others) {
          if (o.userId != myId) otherUserId = o.userId;
        }
      }
      items.add(
        ConversationItem(
          conversation: conversation,
          unread: unread,
          otherUserId: otherUserId,
        ),
      );
    }
    items.sort((a, b) {
      final at = a.conversation.lastMessageAt;
      final bt = b.conversation.lastMessageAt;
      if (at == null && bt == null) return 0;
      if (at == null) return 1;
      if (bt == null) return -1;
      return bt.compareTo(at);
    });
    return items;
  }

  /// DM requests waiting for ME to accept (point 1).
  Future<List<ConversationItem>> pendingMessageRequests() async {
    final myId = _myId();
    final items = await listMyConversations();
    final requests = <ConversationItem>[];
    for (final item in items) {
      final c = item.conversation;
      if (c.isRequest && c.createdBy != myId) requests.add(item);
    }
    return requests;
  }

  /// The existing 1:1 conversation with [otherUserId], if any.
  Future<Conversation?> findDm(String otherUserId) async {
    final myId = _myId();
    final mine = await _myMemberRows();
    for (final m in mine) {
      final conversation = await _getConversation(m.conversationId);
      if (conversation == null || conversation.isGroup) continue;
      final others = await memberRows(conversation.id);
      final ids = others.map((o) => o.userId).toSet();
      if (ids.contains(myId) &&
          ids.contains(otherUserId) &&
          ids.length == 2) {
        return conversation;
      }
    }
    return null;
  }

  /// Starts (or reopens) a DM. Requires that I follow the other
  /// person (point 1). Mutual follows chat directly; a one-sided
  /// follow creates a REQUEST the other side must accept.
  ///
  /// Race-safe (v2.11.2 FIX 1): two rapid concurrent calls for the
  /// same person share one creation — the live duplicate DM was two
  /// `startDm` calls 2 seconds apart, both seeing "no DM yet" and
  /// both creating one. The in-flight map is static, so it holds
  /// across service instances in this isolate.
  static final Map<String, Future<Conversation>> _dmCreationInFlight = {};

  Future<Conversation> startDm(String otherUserId) async {
    final myId = _myId();
    if (otherUserId == myId) {
      throw const CannotMessageException('You cannot message yourself.');
    }
    final key = '$myId|$otherUserId';
    final inFlight = _dmCreationInFlight[key];
    if (inFlight != null) return inFlight;
    final future = _startDmInner(myId, otherUserId);
    _dmCreationInFlight[key] = future;
    try {
      return await future;
    } finally {
      if (_dmCreationInFlight[key] == future) {
        _dmCreationInFlight.remove(key);
      }
    }
  }

  Future<Conversation> _startDmInner(String myId, String otherUserId) async {
    final existing = await findDm(otherUserId);
    if (existing != null) return existing;
    final social = SocialRepository(db: _db);
    if (!await social.isFollowing(otherUserId)) {
      throw const CannotMessageException(
        'Follow this person first — you can only message people you follow.',
      );
    }
    final mutual = await social.isMutual(otherUserId);
    // Re-check immediately before creating: a concurrent call may
    // have created the DM while the follow checks were running.
    final rechecked = await findDm(otherUserId);
    if (rechecked != null) return rechecked;
    final now = DateTime.now().toUtc();
    final doc = await _d.createRow(
      databaseId: _dbId,
      tableId: 'conversations',
      rowId: ID.unique(),
      data: {
        'type': 'dm',
        'title': null,
        'createdBy': myId,
        'createdAt': now.toIso8601String(),
        'lastMessageAt': null,
        'lastMessagePreview': null,
        'status': dmStatus(mutual: mutual),
      },
    );
    final conversation = Conversation.fromJson(_docJson(doc));
    for (final uid in [myId, otherUserId]) {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'conversation_members',
        rowId: ID.unique(),
        data: {
          'conversationId': conversation.id,
          'userId': uid,
          'role': 'member',
          'joinedAt': now.toIso8601String(),
          'lastReadAt': null,
        },
      );
    }
    return conversation;
  }

  /// Creates a group chat (point 2). Every member must be someone
  /// I follow; the title cannot be empty.
  Future<Conversation> createGroup({
    required String title,
    required List<String> memberIds,
  }) async {
    final myId = _myId();
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) {
      throw const CannotMessageException('Give the group a name.');
    }
    final unique = memberIds.toSet().toList()..remove(myId);
    if (unique.isEmpty) {
      throw const CannotMessageException(
        'Add at least one person you follow.',
      );
    }
    final social = SocialRepository(db: _db);
    for (final id in unique) {
      if (!await social.isFollowing(id)) {
        throw const CannotMessageException(
          'You can only add people you follow to a group.',
        );
      }
    }
    final now = DateTime.now().toUtc();
    final doc = await _d.createRow(
      databaseId: _dbId,
      tableId: 'conversations',
      rowId: ID.unique(),
      data: {
        'type': 'group',
        'title': cleanTitle,
        'createdBy': myId,
        'createdAt': now.toIso8601String(),
        'lastMessageAt': null,
        'lastMessagePreview': null,
        'status': 'active',
      },
    );
    final conversation = Conversation.fromJson(_docJson(doc));
    await _d.createRow(
      databaseId: _dbId,
      tableId: 'conversation_members',
      rowId: ID.unique(),
      data: {
        'conversationId': conversation.id,
        'userId': myId,
        'role': 'admin',
        'joinedAt': now.toIso8601String(),
        'lastReadAt': null,
      },
    );
    for (final uid in unique) {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'conversation_members',
        rowId: ID.unique(),
        data: {
          'conversationId': conversation.id,
          'userId': uid,
          'role': 'member',
          'joinedAt': now.toIso8601String(),
          'lastReadAt': null,
        },
      );
    }
    return conversation;
  }

  /// Accepts a DM request (point 1): the chat becomes active.
  Future<void> acceptRequest(String conversationId) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'conversations',
      rowId: conversationId,
      data: {'status': 'active'},
    );
  }

  /// Declines a DM request: the conversation, its members and its
  /// messages are deleted.
  Future<void> declineRequest(String conversationId) async {
    final messages = await _listMessageRows(conversationId, limit: 200);
    for (final m in messages) {
      try {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'messages',
          rowId: m.id,
        );
      } catch (_) {}
    }
    final members = await memberRows(conversationId);
    for (final m in members) {
      try {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'conversation_members',
          rowId: m.id,
        );
      } catch (_) {}
    }
    try {
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'conversations',
        rowId: conversationId,
      );
    } catch (_) {}
  }

  /// Marks the chat read (for read receipts, point 15).
  Future<void> markRead(String conversationId) async {
    final myId = _myId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'conversation_members',
      queries: [
        Query.equal('conversationId', conversationId),
        Query.equal('userId', myId),
        Query.limit(1),
      ],
    );
    if (list.rows.isEmpty) return;
    final rowId = _docJson(list.rows.first)['id'] as String;
    try {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'conversation_members',
        rowId: rowId,
        // v2.11.2 FIX 4: store UTC instants (see _touchConversation)
        // so every device renders the same local time.
        data: {'lastReadAt': DateTime.now().toUtc().toIso8601String()},
      );
    } catch (_) {}
  }

  /// User ids that have read the message (their lastReadAt is at or
  /// after the message was sent) — shown in message Info (point 15).
  Future<List<String>> readByUserIds(
    String conversationId,
    DateTime messageCreatedAt,
  ) async {
    final members = await memberRows(conversationId);
    return members
        .where(
          (m) =>
              m.lastReadAt != null &&
              !m.lastReadAt!.isBefore(messageCreatedAt),
        )
        .map((m) => m.userId)
        .toList();
  }

  // --- Messages ----------------------------------------------------------

  Future<List<DmMessage>> _listMessageRows(
    String conversationId, {
    int limit = 200,
  }) async {
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'messages',
      queries: [
        Query.equal('conversationId', conversationId),
        Query.orderAsc('createdAt'),
        Query.limit(limit),
      ],
    );
    return list.rows
        .map((doc) => DmMessage.fromJson(_docJson(doc)))
        .toList();
  }

  /// The chat's messages, oldest first. Expired messages are purged
  /// first (unless the chat is in Safe Mode), encrypted ones are
  /// decrypted for this device, and my "deleted for me" messages
  /// are filtered out.
  Future<List<DmMessage>> listMessages(
    String conversationId, {
    int limit = 200,
  }) async {
    try {
      final settings = await settingsFor(conversationId);
      if (!settings.safeMode) {
        await purgeConversation(conversationId);
      }
    } catch (_) {}
    final rows = await _listMessageRows(conversationId, limit: limit);
    // Epoch pre-pass (v2.11.1, FIX 3): establish every epoch key
    // carried by this list before decrypting anything, so a
    // re-encrypted starred message decrypts even though it sits
    // before its epoch's establishment message.
    await _establishEpochs(rows);
    final prefs = await ChatPrefs.instance();
    final hidden = prefs.deletedForMeIds(conversationId);
    final out = <DmMessage>[];
    for (final m in rows) {
      if (hidden.contains(m.id)) continue;
      final decrypted = await _decryptForMe(m);
      // v2.11.2 FIX 3: an epoch establishment carrier this device
      // cannot read is key transport, not a user message — it must
      // not render as a phantom "Encrypted message" bubble in a
      // fresh DM. It stays stored (and _establishEpochs above
      // already unwrapped its key), and a carrier this device CAN
      // read renders normally as the user's message.
      if (decrypted.isEstablishment && decrypted.decryptedText == null) {
        continue;
      }
      out.add(decrypted);
    }
    return out;
  }

  /// The newest message that would render in the chat (v2.11.2
  /// FIX 5; v2.11.3: targeted fetch) — for the list preview. Null
  /// when the chat has no visible message yet (e.g. its only
  /// message is an unreadable establishment carrier); the caller
  /// then keeps the stored preview instead of inventing one.
  ///
  /// v2.11.3: the old implementation listed up to 200 messages
  /// and decrypted ALL of them on every list load, so a row showed
  /// the stored "Encrypted message" until that slow resolution
  /// finished — and every reload cleared the resolved preview and
  /// started over, which is why group rows kept flipping back to
  /// the stale label. This fetches only the newest few rows and
  /// decrypts those.
  Future<DmMessage?> latestVisibleMessage(String conversationId) async {
    try {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'messages',
        queries: [
          Query.equal('conversationId', conversationId),
          Query.orderDesc('createdAt'),
          Query.limit(5),
        ],
      );
      final rows = list.rows
          .map((doc) => DmMessage.fromJson(_docJson(doc)))
          .toList();
      if (rows.isEmpty) return null;
      // Newest first — the query asks for it, and sorting here
      // too keeps the result right even if the order is ignored.
      rows.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      // Epoch pre-pass (v2.11.1): establish every epoch key
      // carried by these rows before decrypting.
      await _establishEpochs(rows);
      final prefs = await ChatPrefs.instance();
      final hidden = prefs.deletedForMeIds(conversationId);
      for (final m in rows) {
        // Expired, or deleted for me: not really there any more —
        // look at the next newest.
        if (m.isExpiredAtNow) continue;
        if (hidden.contains(m.id)) continue;
        final decrypted = await _decryptForMe(m);
        // An establishment carrier this device cannot read is key
        // transport, not a user message — the chat skips it too,
        // so the preview falls through to the previous message.
        if (decrypted.isEstablishment && decrypted.decryptedText == null) {
          continue;
        }
        // Any other message renders — even an undecryptable legacy
        // one (as the honest "Encrypted message" bubble). The
        // caller keeps the stored preview for that case.
        return decrypted;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// One conversation by id (v2.11.2 FIX 6: the chat screen
  /// re-reads the conversation after accepting a request, so the
  /// banner goes away without leaving and reopening the chat).
  Future<Conversation?> getConversation(String conversationId) =>
      _getConversation(conversationId);

  Future<DmMessage?> getMessage(String messageId) async {
    try {
      final doc = await _d.getRow(
        databaseId: _dbId,
        tableId: 'messages',
        rowId: messageId,
      );
      return await _decryptForMe(DmMessage.fromJson(_docJson(doc)));
    } catch (_) {
      return null;
    }
  }

  Future<void> _touchConversation(
    String conversationId,
    String preview,
  ) async {
    try {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'conversations',
        rowId: conversationId,
        data: {
          // v2.11.2 FIX 4: write a UTC instant. The old code wrote
          // local time with no offset ("15:02"), which Appwrite
          // reads back as 15:02 UTC — 5:30 ahead of IST — so the
          // same message showed "3:02 PM" from this field and
          // "9:32 AM" from the server's true-UTC $createdAt.
          'lastMessageAt': DateTime.now().toUtc().toIso8601String(),
          'lastMessagePreview': preview.length > 120
              ? '${preview.substring(0, 120)}…'
              : preview,
        },
      );
    } catch (_) {}
  }

  /// Encrypts [text] for the conversation's members (v2.11.1,
  /// epoch keys — FIX 3). Returns the (text, ciphertext,
  /// encryptedKeys, encrypted) tuple to store. Falls back to
  /// plaintext when nobody in the chat has a public key yet
  /// (point 16). The epoch key is RSA-wrapped only on the
  /// establishment message (the first message of a new epoch);
  /// later messages in the epoch derive their keys from it and
  /// carry no wrapped key.
  ///
  /// Size-cap failure is NOT swallowed: when the wrapped epoch
  /// key would not fit in `messages.encryptedKeys`
  /// ([EncryptedKeysTooLarge] — very large groups only), the error
  /// propagates so the UI can tell the user the message was not
  /// sent, instead of silently downgrading to plaintext. The wrap
  /// happens BEFORE any epoch state is saved, so a failed
  /// establishment leaves no half-rotated epoch behind.
  Future<({String? text, String? ciphertext, String? encryptedKeys, bool encrypted})>
  _encryptTextForConversation(String conversationId, String text) async {
    final members = await memberRows(conversationId);
    final ids = members.map((m) => m.userId).toSet().toList();
    final keys = await _publicKeysFor(ids);
    if (keys.isEmpty) {
      return (text: text, ciphertext: null, encryptedKeys: null, encrypted: false);
    }
    final epochs = await ChatEpochStore.instance();
    final now = DateTime.now();
    final current = epochs.currentEpoch(conversationId);
    final rotating = current == null ||
        epochNeedsRotation(
          createdAt: current.createdAt,
          sentCount: current.sentCount,
          now: now,
        );
    final epoch = rotating
        ? ChatEpoch(
            epoch: (current?.epoch ?? 0) + 1,
            keyBase64: base64Encode(
              List<int>.generate(32, (_) => Random.secure().nextInt(256)),
            ),
            createdAt: now,
            sentCount: 0,
            lastMessageAt: now,
          )
        : current;
    // Wrap the epoch key BEFORE changing any stored state. A
    // too-large group throws EncryptedKeysTooLarge here and the
    // message is not sent (no silent plaintext downgrade, no
    // half-rotated epoch). Unparsable keys fall back to plaintext,
    // as in v2.11.0.
    String? wrappedKeys;
    if (rotating) {
      try {
        wrappedKeys = epochs.wrapEpochKey(epoch.keyBytes, keys);
      } on EncryptedKeysTooLarge {
        rethrow;
      } on StateError {
        return (text: text, ciphertext: null, encryptedKeys: null, encrypted: false);
      }
    }
    try {
      if (rotating) {
        // Rotate: re-encrypt starred messages under the new epoch
        // first (so they stay readable), then start the new epoch.
        if (current != null) {
          await _reencryptStarredForRotation(conversationId, epoch);
          await epochs.deleteExpiredEpochs(conversationId, now);
        }
        await epochs.saveEpoch(conversationId, epoch);
      }
      final ciphertext = encryptWithEpochKey(text, epoch.keyBytes, epoch.epoch);
      await epochs.saveEpoch(
        conversationId,
        epoch.copyWith(
          sentCount: epoch.sentCount + 1,
          lastMessageAt: now,
        ),
      );
      return (
        text: null,
        ciphertext: ciphertext,
        encryptedKeys: wrappedKeys,
        encrypted: true,
      );
    } catch (_) {
      return (text: text, ciphertext: null, encryptedKeys: null, encrypted: false);
    }
  }

  /// Re-encrypts my starred messages in a conversation under a
  /// fresh epoch key, at rotation time (v2.11.1, FIX 3). Without
  /// this, starred messages — the only ones that survive the
  /// 12-hour auto-delete — would become unreadable once the old
  /// epoch key is deleted. Best effort: a message that cannot be
  /// re-encrypted is left as it is, and rotation still proceeds.
  Future<void> _reencryptStarredForRotation(
    String conversationId,
    ChatEpoch newEpoch,
  ) async {
    try {
      final starredIds = await starredIdsForConversation(conversationId);
      if (starredIds.isEmpty) return;
      final members = await memberRows(conversationId);
      final memberIds = members.map((m) => m.userId).toSet();
      for (final id in starredIds) {
        try {
          final msg = await getMessage(id);
          if (msg == null ||
              msg.conversationId != conversationId ||
              msg.deletedForAll) {
            continue;
          }
          if (msg.isImage) {
            // The image bytes stay on imgbb; only the wrapped key
            // changes — drop wrapped keys of users no longer in
            // the chat, so a removed member keeps no way in.
            if (msg.encrypted && msg.encryptedKeys != null) {
              final wrapped =
                  jsonDecode(msg.encryptedKeys!) as Map<String, dynamic>;
              wrapped.removeWhere((uid, _) => !memberIds.contains(uid));
              if (wrapped.isNotEmpty) {
                await _d.updateRow(
                  databaseId: _dbId,
                  tableId: 'messages',
                  rowId: msg.id,
                  data: {'encryptedKeys': jsonEncode(wrapped)},
                );
              }
            }
            continue;
          }
          final plain = msg.displayText;
          if (plain.isEmpty || plain.startsWith('Encrypted message')) {
            continue;
          }
          final cipher = encryptWithEpochKey(
            plain,
            newEpoch.keyBytes,
            newEpoch.epoch,
          );
          await _d.updateRow(
            databaseId: _dbId,
            tableId: 'messages',
            rowId: msg.id,
            data: {
              'ciphertext': cipher,
              'encryptedKeys': null,
              'encrypted': true,
            },
          );
        } catch (_) {
          // One bad starred message must not block rotation.
        }
      }
    } catch (_) {}
  }

  Future<DmMessage> _insertMessage({
    required String conversationId,
    required String type,
    String? text,
    String? imageUrl,
    String? imageDeleteUrl,
    String? replyToId,
    bool isViewOnce = false,
    bool forwarded = false,
    bool encrypted = false,
    String? encryptedKeys,
  }) async {
    final myId = _myId();
    final now = DateTime.now().toUtc();
    final doc = await _d.createRow(
      databaseId: _dbId,
      tableId: 'messages',
      rowId: ID.unique(),
      data: {
        'conversationId': conversationId,
        'senderId': myId,
        'type': type,
        'text': text,
        'imageUrl': imageUrl,
        'imageDeleteUrl': imageDeleteUrl,
        'replyToId': replyToId,
        'createdAt': now.toIso8601String(),
        'editedAt': null,
        'deletedForAll': false,
        'isViewOnce': isViewOnce,
        'viewOnceViewed': false,
        'expiresAt': messageExpiresAt(now).toIso8601String(),
        'encrypted': encrypted,
        'ciphertext': null,
        'encryptedKeys': encryptedKeys,
        'forwarded': forwarded,
      },
    );
    return DmMessage.fromJson(_docJson(doc));
  }

  /// Sends a text message (point 3/15). Returns the stored row.
  Future<DmMessage> sendText(
    String conversationId,
    String text, {
    String? replyToId,
    bool forwarded = false,
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) {
      throw const CannotMessageException('Write something first.');
    }
    final encrypted = await _encryptTextForConversation(conversationId, clean);
    final myId = _myId();
    final now = DateTime.now().toUtc();
    final doc = await _d.createRow(
      databaseId: _dbId,
      tableId: 'messages',
      rowId: ID.unique(),
      data: {
        'conversationId': conversationId,
        'senderId': myId,
        'type': 'text',
        'text': encrypted.text,
        'imageUrl': null,
        'imageDeleteUrl': null,
        'replyToId': replyToId,
        'createdAt': now.toIso8601String(),
        'editedAt': null,
        'deletedForAll': false,
        'isViewOnce': false,
        'viewOnceViewed': false,
        'expiresAt': messageExpiresAt(now).toIso8601String(),
        'encrypted': encrypted.encrypted,
        'ciphertext': encrypted.ciphertext,
        'encryptedKeys': encrypted.encryptedKeys,
        'forwarded': forwarded,
      },
    );
    final message = DmMessage.fromJson(_docJson(doc));
    await _touchConversation(
      conversationId,
      encrypted.encrypted ? 'Encrypted message' : clean,
    );
    unawaited(_purgeQuietly(conversationId));
    return message.copyWith(decryptedText: encrypted.encrypted ? clean : null);
  }

  /// Sends an image message via imgbb (point 5). Set [isViewOnce]
  /// for a View Once photo (point 10).
  ///
  /// v2.11.1 (FIX 2): the photo is end-to-end encrypted BEFORE it
  /// leaves the device — one fresh AES-256 key, wrapped per
  /// recipient with RSA (the same scheme text messages use), and
  /// the ciphertext rides to imgbb inside a valid PNG carrier
  /// (imgbb only accepts real image files). When nobody in the
  /// chat has a public key yet, the plain upload is used instead —
  /// the same honest fallback as text messages. When keys exist
  /// but encryption itself fails, the send fails loudly rather
  /// than silently downgrading a photo the user expected to be
  /// encrypted.
  Future<DmMessage> sendImage(
    String conversationId,
    List<int> bytes, {
    String filename = 'photo.jpg',
    String? replyToId,
    bool isViewOnce = false,
    bool forwarded = false,
  }) async {
    final members = await memberRows(conversationId);
    final ids = members.map((m) => m.userId).toSet().toList();
    final keys = await _publicKeysFor(ids);
    if (keys.isNotEmpty) {
      final envelope = encryptBytesForRecipients(bytes, keys);
      final carrier = packBytesAsPng(envelope.ciphertextBytes);
      final upload = await uploadImageToImgbb(
        carrier,
        filename: 'photo.png',
        contentType: 'image/png',
      );
      final message = await _insertMessage(
        conversationId: conversationId,
        type: 'image',
        imageUrl: upload.url,
        imageDeleteUrl: upload.deleteUrl,
        replyToId: replyToId,
        isViewOnce: isViewOnce,
        forwarded: forwarded,
        encrypted: true,
        encryptedKeys: envelope.encryptedKeysJson,
      );
      await _touchConversation(conversationId, 'Photo');
      unawaited(_purgeQuietly(conversationId));
      return message;
    }
    final upload = await uploadImageToImgbb(bytes, filename: filename);
    final message = await _insertMessage(
      conversationId: conversationId,
      type: 'image',
      imageUrl: upload.url,
      imageDeleteUrl: upload.deleteUrl,
      replyToId: replyToId,
      isViewOnce: isViewOnce,
      forwarded: forwarded,
    );
    await _touchConversation(conversationId, 'Photo');
    unawaited(_purgeQuietly(conversationId));
    return message;
  }

  /// Edits my own text message (point 3). Re-encrypts when the
  /// original was encrypted.
  Future<void> editMessage(DmMessage message, String newText) async {
    final myId = _myId();
    if (message.senderId != myId) {
      throw const CannotMessageException('You can only edit your own messages.');
    }
    if (message.isImage) {
      throw const CannotMessageException('Photos cannot be edited.');
    }
    final clean = newText.trim();
    if (clean.isEmpty) {
      throw const CannotMessageException('Write something first.');
    }
    final data = <String, dynamic>{
      'editedAt': DateTime.now().toUtc().toIso8601String(),
    };
    if (message.encrypted) {
      final encrypted = await _encryptTextForConversation(
        message.conversationId,
        clean,
      );
      data['text'] = encrypted.text;
      data['ciphertext'] = encrypted.ciphertext;
      data['encryptedKeys'] = encrypted.encryptedKeys;
      data['encrypted'] = encrypted.encrypted;
    } else {
      data['text'] = clean;
    }
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'messages',
      rowId: message.id,
      data: data,
    );
  }

  /// Deletes my message for everyone (point 3): the body is wiped
  /// server-side; the row stays as a "deleted" tombstone.
  Future<void> deleteForEveryone(DmMessage message) async {
    final myId = _myId();
    if (message.senderId != myId) {
      throw const CannotMessageException(
        'You can only delete your own messages for everyone.',
      );
    }
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'messages',
      rowId: message.id,
      data: {
        'text': null,
        'ciphertext': null,
        'encryptedKeys': null,
        'imageUrl': null,
        'imageDeleteUrl': null,
        'deletedForAll': true,
      },
    );
  }

  /// Deletes a message just for me (point 3) — stored on-device.
  Future<void> deleteForMe(String conversationId, DmMessage message) async {
    final prefs = await ChatPrefs.instance();
    await prefs.markDeletedForMe(conversationId, message.id);
  }

  /// Forwards a message into another conversation (point 3): the
  /// body is decrypted (when I can read it) and re-encrypted for
  /// the new chat's members, marked as forwarded.
  Future<DmMessage> forwardMessage(
    DmMessage message,
    String targetConversationId,
  ) async {
    if (message.deletedForAll) {
      throw const CannotMessageException('This message was deleted.');
    }
    if (message.isImage) {
      if (message.imageUrl == null) {
        throw const CannotMessageException('This photo is no longer available.');
      }
      if (message.isViewOnce) {
        // Forwarding a View Once photo would turn it into a normal
        // photo in the target chat — that defeats View Once, so it
        // is blocked outright (v2.11.1: the old code copied the URL
        // and silently dropped the View Once flag).
        throw const CannotMessageException(
          'View once photos cannot be forwarded.',
        );
      }
      if (message.encrypted) {
        // Re-encrypt for the target chat (v2.11.1, FIX 2): download
        // the carrier, decrypt it, and send it fresh. Forwarding
        // the carrier URL as-is would show noise to people who
        // cannot decrypt it — and would leak the ciphertext into a
        // chat whose members never received the key.
        final bytes = await decryptedImageBytesFor(message);
        if (bytes == null) {
          throw const CannotMessageException(
            'I cannot read this photo, so I cannot forward it.',
          );
        }
        return sendImage(
          targetConversationId,
          bytes,
          forwarded: true,
        );
      }
      final forwarded = await _insertMessage(
        conversationId: targetConversationId,
        type: 'image',
        imageUrl: message.imageUrl,
        imageDeleteUrl: message.imageDeleteUrl,
        forwarded: true,
      );
      await _touchConversation(targetConversationId, 'Photo');
      return forwarded;
    }
    final body = message.displayText;
    if (body.isEmpty) {
      throw const CannotMessageException('Nothing to forward.');
    }
    final sent = await sendText(
      targetConversationId,
      body,
      forwarded: true,
    );
    return sent;
  }

  /// A View Once photo was seen (point 10): the message row is
  /// deleted and the imgbb file is removed, so it is gone for good.
  Future<void> markViewOnceViewed(DmMessage message) async {
    if (!message.isViewOnce || message.viewOnceViewed) return;
    try {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'messages',
        rowId: message.id,
        data: {'viewOnceViewed': true},
      );
    } catch (_) {}
    try {
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'messages',
        rowId: message.id,
      );
    } catch (_) {}
    final deleteUrl = message.imageDeleteUrl;
    if (deleteUrl != null && deleteUrl.isNotEmpty) {
      await deleteImageFromImgbb(deleteUrl);
    }
  }

  // --- Stars / saves (point 7) ------------------------------------------

  /// My starred message ids in one conversation.
  Future<Set<String>> starredIdsForConversation(String conversationId) async {
    final myId = _myId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'starred_messages',
      queries: [
        Query.equal('userId', myId),
        Query.equal('conversationId', conversationId),
        Query.limit(100),
      ],
    );
    return list.rows
        .map((doc) => _docJson(doc)['messageId'] as String?)
        .whereType<String>()
        .toSet();
  }

  /// How many messages I have saved in total (cap: 50).
  Future<int> savedCount() async {
    final myId = _myId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'starred_messages',
      queries: [Query.equal('userId', myId), Query.limit(1)],
    );
    return list.total;
  }

  /// Stars (saves) a message: it survives the 12-hour auto-delete
  /// and the 150 cap. Throws [SaveCapReachedException] at 50.
  Future<void> starMessage(DmMessage message) async {
    if (!canSaveMore(await savedCount())) {
      throw SaveCapReachedException();
    }
    final myId = _myId();
    await _d.createRow(
      databaseId: _dbId,
      tableId: 'starred_messages',
      rowId: ID.unique(),
      data: {
        'userId': myId,
        'messageId': message.id,
        'conversationId': message.conversationId,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      },
    );
  }

  /// My saved messages across all chats, newest first (point 7).
  Future<List<DmMessage>> listStarredMessages({int limit = 100}) async {
    final myId = _myId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'starred_messages',
      queries: [
        Query.equal('userId', myId),
        Query.orderDesc('createdAt'),
        Query.limit(limit),
      ],
    );
    final out = <DmMessage>[];
    for (final doc in list.rows) {
      final messageId = _docJson(doc)['messageId'] as String?;
      if (messageId == null) continue;
      final message = await getMessage(messageId);
      if (message != null) out.add(message);
    }
    return out;
  }

  Future<void> unstarMessage(String messageId) async {
    final myId = _myId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'starred_messages',
      queries: [
        Query.equal('userId', myId),
        Query.equal('messageId', messageId),
        Query.limit(1),
      ],
    );
    for (final doc in list.rows) {
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'starred_messages',
        rowId: _docJson(doc)['id'] as String,
      );
    }
  }

  // --- Auto-delete + cap (point 6) ---------------------------------------

  Future<void> _purgeQuietly(String conversationId) async {
    try {
      await purgeConversation(conversationId);
    } catch (_) {}
  }

  /// Deletes expired messages (older than 12h) and enforces the
  /// 150-message rolling cap. Starred messages are never deleted.
  /// A no-op for Safe Mode chats (point 7).
  Future<void> purgeConversation(String conversationId) async {
    final settings = await settingsFor(conversationId);
    if (settings.safeMode) return;
    final rows = await _listMessageRows(conversationId);
    if (rows.isEmpty) return;
    final starred = await starredIdsForConversation(conversationId);
    final now = DateTime.now();
    final toDelete = <String>{};
    for (final m in rows) {
      if (m.deletedForAll) continue;
      if (starred.contains(m.id)) continue;
      if (isMessageExpired(m.expiresAt, now)) toDelete.add(m.id);
    }
    final survivors = rows.where((m) => !toDelete.contains(m.id)).toList();
    for (final m in messagesToDeleteForCap(survivors, starredIds: starred)) {
      toDelete.add(m.id);
    }
    for (final id in toDelete) {
      try {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'messages',
          rowId: id,
        );
      } catch (_) {}
    }
  }

  /// Clears a chat's whole history (point 12 — the forgotten-lock
  /// path): every message row + my stars in it are deleted, and the
  /// settings go back to defaults. Members and the conversation
  /// itself stay, so the chat starts fresh.
  Future<void> clearConversationHistory(String conversationId) async {
    final rows = await _listMessageRows(conversationId);
    for (final m in rows) {
      try {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'messages',
          rowId: m.id,
        );
      } catch (_) {}
    }
    final myId = _myId();
    final stars = await _d.listRows(
      databaseId: _dbId,
      tableId: 'starred_messages',
      queries: [
        Query.equal('userId', myId),
        Query.equal('conversationId', conversationId),
        Query.limit(100),
      ],
    );
    for (final doc in stars.rows) {
      try {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'starred_messages',
          rowId: _docJson(doc)['id'] as String,
        );
      } catch (_) {}
    }
    final prefs = await ChatPrefs.instance();
    await prefs.clearDeletedForMe(conversationId);
    try {
      final settings = await settingsFor(conversationId);
      if (settings.id.isNotEmpty) {
        await _d.updateRow(
          databaseId: _dbId,
          tableId: 'chat_settings',
          rowId: settings.id,
          data: {
            'hidden': false,
            'privateChat': true,
            'secureChat': false,
            'safeMode': false,
          },
        );
      }
    } catch (_) {}
  }

  // --- Per-chat settings (points 10, 12, 13, 14) -------------------------

  Future<ChatSettings> settingsFor(String conversationId) async {
    final myId = _myId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'chat_settings',
      queries: [
        Query.equal('userId', myId),
        Query.equal('conversationId', conversationId),
        Query.limit(1),
      ],
    );
    if (list.rows.isEmpty) {
      return ChatSettings.defaults(userId: myId, conversationId: conversationId);
    }
    return ChatSettings.fromJson(_docJson(list.rows.first));
  }

  Future<ChatSettings> updateSettings(ChatSettings settings) async {
    if (settings.id.isEmpty) {
      final doc = await _d.createRow(
        databaseId: _dbId,
        tableId: 'chat_settings',
        rowId: ID.unique(),
        data: settings.toMap(),
      );
      return ChatSettings.fromJson(_docJson(doc));
    }
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'chat_settings',
      rowId: settings.id,
      data: {
        'hidden': settings.hidden,
        'privateChat': settings.privateChat,
        'secureChat': settings.secureChat,
        'safeMode': settings.safeMode,
      },
    );
    return settings;
  }
}
