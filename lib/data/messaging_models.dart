/// Messaging (v2.11.0): models + pure rules for chats.
///
/// The Appwrite tables live in scripts/setup_appwrite.mjs
/// (`conversations`, `conversation_members`, `messages`,
/// `starred_messages`, `chat_settings`) — this file is the app-side
/// shape of those rows plus the rules that never need the network:
///
/// * auto-delete: every message expires 12 hours after it was sent
///   (point 6); only starred/saved messages survive.
/// * rolling cap: at most 150 messages per conversation — the oldest
///   NON-starred messages go first (point 6).
/// * save cap: one user can save at most 50 messages, free tier
///   (point 7).
/// * requests: messaging someone you follow but who does not follow
///   you back starts as a REQUEST (point 1).
/// * chat lock: a PIN per chat, stored as a SHA-256 hash on-device
///   only (point 12). Forgetting it clears that chat's history —
///   there is no recovery by design.
/// * hidden chats: revealed only by the secret keyword in search,
///   or by a chat lock password (point 13).
/// * private chat: OFF means the session's history is deleted when
///   you leave the chat, and nothing can be starred in it (point 14).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A message lives 12 hours, then auto-deletes (point 6).
const int kMessageLifetimeHours = 12;

/// At most this many messages per conversation; older non-starred
/// ones roll off as new ones arrive (point 6).
const int kMaxMessagesPerConversation = 150;

/// Free tier: one user can save at most this many messages (point 7).
const int kMaxSavedMessagesPerUser = 50;

/// When a message was created, it expires 12 hours later.
DateTime messageExpiresAt(DateTime createdAt) =>
    createdAt.add(const Duration(hours: kMessageLifetimeHours));

bool isMessageExpired(DateTime expiresAt, DateTime now) =>
    now.isAfter(expiresAt);

/// The messages to delete to enforce the 150-message rolling cap.
///
/// [messages] is the conversation's messages (any order); [starredIds]
/// are the ids the user (or anyone) saved — starred messages NEVER
/// delete. Returns the oldest non-starred messages beyond the cap,
/// oldest first. Returns [] when the conversation is within the cap.
List<DmMessage> messagesToDeleteForCap(
  List<DmMessage> messages, {
  required Set<String> starredIds,
  int cap = kMaxMessagesPerConversation,
}) {
  final keepable = messages
      .where((m) => !starredIds.contains(m.id) && !m.deletedForAll)
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  if (keepable.length <= cap) return [];
  return keepable.sublist(0, keepable.length - cap);
}

/// True when the user may save one more message (point 7).
bool canSaveMore(int savedCount) => savedCount < kMaxSavedMessagesPerUser;

/// The status of a new DM: mutual follows chat directly, a one-sided
/// follow starts as a REQUEST the other side must accept (point 1).
String dmStatus({required bool mutual}) => mutual ? 'active' : 'requested';

/// You can message anyone you follow; following them from your side
/// is REQUIRED (point 1).
bool canMessage({required bool iFollowThem}) => iFollowThem;

/// SHA-256 of "$conversationId:$pin", hex. The PIN itself is never
/// stored anywhere — only this hash, on-device (point 12).
String hashChatPin(String pin, String conversationId) {
  final bytes = utf8.encode('$conversationId:$pin');
  return sha256.convert(bytes).toString();
}

bool verifyChatPin(String pin, String conversationId, String hash) =>
    hashChatPin(pin, conversationId) == hash;

/// True when the search text IS the secret keyword (case-insensitive,
/// surrounding spaces ignored). A hidden chat appears only on an
/// exact keyword match (or its lock password) — never on a partial
/// search (point 13).
bool matchesHiddenKeyword(String query, String keyword) {
  final q = query.trim().toLowerCase();
  final k = keyword.trim().toLowerCase();
  return q.isNotEmpty && k.isNotEmpty && q == k;
}

/// Nothing can be starred while Private Chat is OFF (point 14).
bool canStarInChat({required bool privateChatOn}) => privateChatOn;

/// Private Chat OFF = the session's history is deleted when you
/// leave the chat (point 14).
bool shouldPurgeHistoryOnLeave({required bool privateChatOn}) =>
    !privateChatOn;

/// URLs in a message (point 8). Matches http(s)://… and www.…,
/// and strips trailing punctuation the user did not mean as part
/// of the link.
final RegExp _urlPattern = RegExp(
  r'(https?://\S+|www\.\S+)',
  caseSensitive: false,
);

List<String> extractUrls(String text) {
  return _urlPattern.allMatches(text).map((m) {
    var url = m.group(0)!;
    // Strip trailing punctuation that ends a sentence, not a URL.
    while (url.isNotEmpty && '.,;:!?)]}\'">'.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }).toList();
}

/// A link preview card (point 8): Open Graph tags when present,
/// the <title> as fallback. Parsed from raw HTML — pure, testable.
class LinkPreviewData {
  const LinkPreviewData({this.title, this.description, this.imageUrl});

  final String? title;
  final String? description;
  final String? imageUrl;

  bool get isEmpty => title == null && description == null;
}

String? _ogTag(String html, String property) {
  final pattern = RegExp(
    '<meta[^>]*property=["\']og:$property["\'][^>]*content=["\']([^"\']+)["\']',
    caseSensitive: false,
  );
  final match = pattern.firstMatch(html);
  if (match != null) return match.group(1);
  // content-before-property order also happens in the wild.
  final alt = RegExp(
    '<meta[^>]*content=["\']([^"\']+)["\'][^>]*property=["\']og:$property["\']',
    caseSensitive: false,
  );
  return alt.firstMatch(html)?.group(1);
}

LinkPreviewData parseOpenGraph(String html) {
  var title = _ogTag(html, 'title');
  title ??= RegExp(
    r'<title[^>]*>(.*?)</title>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html)?.group(1)?.trim();
  return LinkPreviewData(
    title: title,
    description: _ogTag(html, 'description'),
    imageUrl: _ogTag(html, 'image'),
  );
}

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

// ---------------------------------------------------------------------------
// Conversation — one DM or one group chat (table `conversations`).
// ---------------------------------------------------------------------------

class Conversation {
  const Conversation({
    required this.id,
    required this.type,
    required this.createdBy,
    required this.createdAt,
    this.title,
    this.lastMessageAt,
    this.lastMessagePreview,
    this.status = 'active',
  });

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
    id: json['id'] as String? ?? '',
    type: json['type'] as String? ?? 'dm',
    createdBy: json['createdBy'] as String? ?? '',
    createdAt:
        _parseDate(json[r'$createdAt'] ?? json['createdAt']) ??
        DateTime.now(),
    title: json['title'] as String?,
    lastMessageAt: _parseDate(json['lastMessageAt']),
    lastMessagePreview: json['lastMessagePreview'] as String?,
    status: json['status'] as String? ?? 'active',
  );

  Map<String, dynamic> toMap() => {
    'type': type,
    'title': title,
    'createdBy': createdBy,
    'createdAt': createdAt.toIso8601String(),
    'lastMessageAt': lastMessageAt?.toIso8601String(),
    'lastMessagePreview': lastMessagePreview,
    'status': status,
  };

  final String id;

  /// 'dm' or 'group'.
  final String type;
  final String createdBy;
  final DateTime createdAt;

  /// Group name. Null for DMs (the other person's name is shown).
  final String? title;
  final DateTime? lastMessageAt;
  final String? lastMessagePreview;

  /// 'active' — normal chat. 'requested' — a DM request waiting for
  /// the other side to accept (point 1).
  final String status;

  bool get isGroup => type == 'group';
  bool get isRequest => status == 'requested';
}

// ---------------------------------------------------------------------------
// ConversationMember — one user in one conversation
// (table `conversation_members`).
// ---------------------------------------------------------------------------

class ConversationMember {
  const ConversationMember({
    required this.id,
    required this.conversationId,
    required this.userId,
    required this.joinedAt,
    this.role = 'member',
    this.lastReadAt,
  });

  factory ConversationMember.fromJson(Map<String, dynamic> json) =>
      ConversationMember(
        id: json['id'] as String? ?? '',
        conversationId: json['conversationId'] as String? ?? '',
        userId: json['userId'] as String? ?? '',
        joinedAt:
            _parseDate(json[r'$createdAt'] ?? json['joinedAt']) ??
            DateTime.now(),
        role: json['role'] as String? ?? 'member',
        lastReadAt: _parseDate(json['lastReadAt']),
      );

  Map<String, dynamic> toMap() => {
    'conversationId': conversationId,
    'userId': userId,
    'role': role,
    'joinedAt': joinedAt.toIso8601String(),
    'lastReadAt': lastReadAt?.toIso8601String(),
  };

  final String id;
  final String conversationId;
  final String userId;

  /// 'admin' (group creator) or 'member'.
  final String role;
  final DateTime joinedAt;

  /// When this member last opened the chat — read receipts (point 15).
  final DateTime? lastReadAt;
}

// ---------------------------------------------------------------------------
// DmMessage — one message (table `messages`).
// ---------------------------------------------------------------------------

class DmMessage {
  const DmMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.createdAt,
    required this.expiresAt,
    this.type = 'text',
    this.text,
    this.imageUrl,
    this.imageDeleteUrl,
    this.replyToId,
    this.editedAt,
    this.deletedForAll = false,
    this.isViewOnce = false,
    this.viewOnceViewed = false,
    this.encrypted = false,
    this.ciphertext,
    this.encryptedKeys,
    this.forwarded = false,
    this.decryptedText,
  });

  factory DmMessage.fromJson(Map<String, dynamic> json) {
    final createdAt =
        _parseDate(json[r'$createdAt'] ?? json['createdAt']) ??
        DateTime.now();
    return DmMessage(
      id: json['id'] as String? ?? '',
      conversationId: json['conversationId'] as String? ?? '',
      senderId: json['senderId'] as String? ?? '',
      createdAt: createdAt,
      expiresAt:
          _parseDate(json['expiresAt']) ?? messageExpiresAt(createdAt),
      type: json['type'] as String? ?? 'text',
      text: json['text'] as String?,
      imageUrl: json['imageUrl'] as String?,
      imageDeleteUrl: json['imageDeleteUrl'] as String?,
      replyToId: json['replyToId'] as String?,
      editedAt: _parseDate(json['editedAt']),
      deletedForAll: json['deletedForAll'] as bool? ?? false,
      isViewOnce: json['isViewOnce'] as bool? ?? false,
      viewOnceViewed: json['viewOnceViewed'] as bool? ?? false,
      encrypted: json['encrypted'] as bool? ?? false,
      ciphertext: json['ciphertext'] as String?,
      encryptedKeys: json['encryptedKeys'] as String?,
      forwarded: json['forwarded'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
    'conversationId': conversationId,
    'senderId': senderId,
    'type': type,
    'text': text,
    'imageUrl': imageUrl,
    'imageDeleteUrl': imageDeleteUrl,
    'replyToId': replyToId,
    'createdAt': createdAt.toIso8601String(),
    'editedAt': editedAt?.toIso8601String(),
    'deletedForAll': deletedForAll,
    'isViewOnce': isViewOnce,
    'viewOnceViewed': viewOnceViewed,
    'expiresAt': expiresAt.toIso8601String(),
    'encrypted': encrypted,
    'ciphertext': ciphertext,
    'encryptedKeys': encryptedKeys,
    'forwarded': forwarded,
  };

  final String id;
  final String conversationId;
  final String senderId;
  final DateTime createdAt;

  /// createdAt + 12h (point 6). Starred messages ignore it.
  final DateTime expiresAt;

  /// 'text' or 'image'.
  final String type;
  final String? text;

  /// imgbb URL for image messages (point 5).
  final String? imageUrl;

  /// imgbb delete URL — lets View Once actually remove the file
  /// from imgbb after it is seen (point 10).
  final String? imageDeleteUrl;

  /// The message this one replies to (point 3 / 9).
  final String? replyToId;
  final DateTime? editedAt;

  /// Deleted for everyone (point 3): the body is wiped server-side.
  final bool deletedForAll;

  /// View Once photo (point 10): gone after one view.
  final bool isViewOnce;
  final bool viewOnceViewed;

  /// End-to-end encrypted (point 16). When true, [text] is empty
  /// and the body lives in [ciphertext]; [decryptedText] is filled
  /// in locally after decryption and never sent anywhere.
  final bool encrypted;
  final String? ciphertext;

  /// JSON map: userId → base64 RSA-wrapped AES key (point 16).
  final String? encryptedKeys;

  /// Forwarded from another chat (point 3).
  final bool forwarded;

  /// Local only: the decrypted body (or null when this device
  /// cannot decrypt it).
  final String? decryptedText;

  bool get isImage => type == 'image';
  bool get isExpiredAtNow => DateTime.now().isAfter(expiresAt);

  /// What the bubble shows. Encrypted messages the device cannot
  /// decrypt say so honestly instead of showing garbage.
  String get displayText {
    if (deletedForAll) return 'This message was deleted';
    if (isImage) return text ?? '';
    if (encrypted) {
      return decryptedText ??
          'Encrypted message — this device cannot decrypt it';
    }
    return text ?? '';
  }

  DmMessage copyWith({
    String? text,
    String? decryptedText,
    DateTime? editedAt,
    bool? deletedForAll,
    bool? viewOnceViewed,
  }) => DmMessage(
    id: id,
    conversationId: conversationId,
    senderId: senderId,
    createdAt: createdAt,
    expiresAt: expiresAt,
    type: type,
    text: text ?? this.text,
    imageUrl: imageUrl,
    imageDeleteUrl: imageDeleteUrl,
    replyToId: replyToId,
    editedAt: editedAt ?? this.editedAt,
    deletedForAll: deletedForAll ?? this.deletedForAll,
    isViewOnce: isViewOnce,
    viewOnceViewed: viewOnceViewed ?? this.viewOnceViewed,
    encrypted: encrypted,
    ciphertext: ciphertext,
    encryptedKeys: encryptedKeys,
    forwarded: forwarded,
    decryptedText: decryptedText ?? this.decryptedText,
  );
}

// ---------------------------------------------------------------------------
// StarredMessage — one saved message (table `starred_messages`).
// ---------------------------------------------------------------------------

class StarredMessage {
  const StarredMessage({
    required this.id,
    required this.userId,
    required this.messageId,
    required this.conversationId,
    required this.createdAt,
  });

  factory StarredMessage.fromJson(Map<String, dynamic> json) =>
      StarredMessage(
        id: json['id'] as String? ?? '',
        userId: json['userId'] as String? ?? '',
        messageId: json['messageId'] as String? ?? '',
        conversationId: json['conversationId'] as String? ?? '',
        createdAt:
            _parseDate(json[r'$createdAt'] ?? json['createdAt']) ??
            DateTime.now(),
      );

  Map<String, dynamic> toMap() => {
    'userId': userId,
    'messageId': messageId,
    'conversationId': conversationId,
    'createdAt': createdAt.toIso8601String(),
  };

  final String id;
  final String userId;
  final String messageId;
  final String conversationId;
  final DateTime createdAt;
}

// ---------------------------------------------------------------------------
// ChatSettings — MY per-chat preferences (table `chat_settings`).
// One row per (user, conversation); missing row = defaults.
// ---------------------------------------------------------------------------

class ChatSettings {
  const ChatSettings({
    required this.id,
    required this.userId,
    required this.conversationId,
    this.hidden = false,
    this.privateChat = true,
    this.secureChat = false,
    this.safeMode = false,
  });

  factory ChatSettings.fromJson(Map<String, dynamic> json) => ChatSettings(
    id: json['id'] as String? ?? '',
    userId: json['userId'] as String? ?? '',
    conversationId: json['conversationId'] as String? ?? '',
    hidden: json['hidden'] as bool? ?? false,
    privateChat: json['privateChat'] as bool? ?? true,
    secureChat: json['secureChat'] as bool? ?? false,
    safeMode: json['safeMode'] as bool? ?? false,
  );

  Map<String, dynamic> toMap() => {
    'userId': userId,
    'conversationId': conversationId,
    'hidden': hidden,
    'privateChat': privateChat,
    'secureChat': secureChat,
    'safeMode': safeMode,
  };

  factory ChatSettings.defaults({
    required String userId,
    required String conversationId,
  }) => ChatSettings(id: '', userId: userId, conversationId: conversationId);

  final String id;
  final String userId;
  final String conversationId;

  /// Hidden chat (point 13): only the secret keyword (or its lock
  /// password) in search reveals it.
  final bool hidden;

  /// Private Chat (point 14). ON = everything normal. OFF = the
  /// session's history is deleted on leaving, and nothing can be
  /// starred.
  final bool privateChat;

  /// Secure Chat (point 10): screenshots restricted while this chat
  /// is open (Android FLAG_SECURE; iOS cannot block screenshots).
  final bool secureChat;

  /// Safe Mode (point 7): when ON, this chat's messages never
  /// auto-delete — the whole chat is "safe". Starred messages are
  /// safe everywhere regardless of this switch.
  final bool safeMode;

  ChatSettings copyWith({
    bool? hidden,
    bool? privateChat,
    bool? secureChat,
    bool? safeMode,
  }) => ChatSettings(
    id: id,
    userId: userId,
    conversationId: conversationId,
    hidden: hidden ?? this.hidden,
    privateChat: privateChat ?? this.privateChat,
    secureChat: secureChat ?? this.secureChat,
    safeMode: safeMode ?? this.safeMode,
  );
}
