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

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/models.dart' as models;

import '../config.dart';
import 'appwrite_service.dart';
import 'chat_crypto.dart';
import 'chat_prefs.dart';
import 'imgbb.dart';
import 'messaging_models.dart';
import 'models.dart';
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

  /// Decrypts one message for me, in place (fills decryptedText).
  Future<DmMessage> _decryptForMe(DmMessage message) async {
    if (!message.encrypted ||
        message.ciphertext == null ||
        message.encryptedKeys == null) {
      return message;
    }
    try {
      final store = await ChatCryptoStore.instance();
      final privateKey = store.privateKeyJson;
      if (privateKey == null) return message;
      final plain = decryptEnvelope(
        message.ciphertext!,
        message.encryptedKeys!,
        _myId(),
        privateKey,
      );
      if (plain == null) return message;
      return message.copyWith(decryptedText: plain);
    } catch (_) {
      return message;
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
    for (final m in myMemberships) {
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
  Future<Conversation> startDm(String otherUserId) async {
    final myId = _myId();
    if (otherUserId == myId) {
      throw const CannotMessageException('You cannot message yourself.');
    }
    final existing = await findDm(otherUserId);
    if (existing != null) return existing;
    final social = SocialRepository(db: _db);
    if (!await social.isFollowing(otherUserId)) {
      throw const CannotMessageException(
        'Follow this person first — you can only message people you follow.',
      );
    }
    final mutual = await social.isMutual(otherUserId);
    final now = DateTime.now();
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
    final now = DateTime.now();
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
        data: {'lastReadAt': DateTime.now().toIso8601String()},
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
    final prefs = await ChatPrefs.instance();
    final hidden = prefs.deletedForMeIds(conversationId);
    final out = <DmMessage>[];
    for (final m in rows) {
      if (hidden.contains(m.id)) continue;
      out.add(await _decryptForMe(m));
    }
    return out;
  }

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
          'lastMessageAt': DateTime.now().toIso8601String(),
          'lastMessagePreview': preview.length > 120
              ? '${preview.substring(0, 120)}…'
              : preview,
        },
      );
    } catch (_) {}
  }

  /// Encrypts [text] for the conversation's members when keys are
  /// available; returns the (text, ciphertext, encryptedKeys,
  /// encrypted) tuple to store. Falls back to plaintext when nobody
  /// in the chat has a public key yet (point 16).
  Future<({String? text, String? ciphertext, String? encryptedKeys, bool encrypted})>
  _encryptForConversation(String conversationId, String text) async {
    final members = await memberRows(conversationId);
    final ids = members.map((m) => m.userId).toSet().toList();
    final keys = await _publicKeysFor(ids);
    if (keys.isEmpty) {
      return (text: text, ciphertext: null, encryptedKeys: null, encrypted: false);
    }
    try {
      final envelope = encryptForRecipients(text, keys);
      return (
        text: null,
        ciphertext: envelope.ciphertext,
        encryptedKeys: envelope.encryptedKeysJson,
        encrypted: true,
      );
    } catch (_) {
      return (text: text, ciphertext: null, encryptedKeys: null, encrypted: false);
    }
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
  }) async {
    final myId = _myId();
    final now = DateTime.now();
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
        'encrypted': false,
        'ciphertext': null,
        'encryptedKeys': null,
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
    final encrypted = await _encryptForConversation(conversationId, clean);
    final myId = _myId();
    final now = DateTime.now();
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
  Future<DmMessage> sendImage(
    String conversationId,
    List<int> bytes, {
    String filename = 'photo.jpg',
    String? replyToId,
    bool isViewOnce = false,
  }) async {
    final upload = await uploadImageToImgbb(bytes, filename: filename);
    // Image bodies are not E2EE-encrypted (the file lives on imgbb);
    // the URL itself is only reachable from inside this chat.
    final message = await _insertMessage(
      conversationId: conversationId,
      type: 'image',
      imageUrl: upload.url,
      imageDeleteUrl: upload.deleteUrl,
      replyToId: replyToId,
      isViewOnce: isViewOnce,
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
      'editedAt': DateTime.now().toIso8601String(),
    };
    if (message.encrypted) {
      final encrypted = await _encryptForConversation(
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
        'createdAt': DateTime.now().toIso8601String(),
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
