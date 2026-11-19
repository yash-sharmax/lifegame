/// On-device chat preferences (v2.11.0).
///
/// Things that belong to THIS device, not the server:
///
/// * chat lock PINs (point 12) — only the SHA-256 hash is stored,
///   never the PIN. Forgetting a PIN clears that chat's history
///   (handled by MessagingService) — there is no recovery.
/// * the secret keyword that reveals hidden chats (point 13).
/// * "delete for me" message ids (point 3).
///
/// Server-side per-chat settings (hidden / private / secure /
/// safe-mode) live in the `chat_settings` table instead — see
/// [ChatSettings] in messaging_models.dart.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'messaging_models.dart';

class ChatPrefs {
  ChatPrefs._(this._prefs);

  static ChatPrefs? _instance;

  static Future<ChatPrefs> instance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final prefs = await SharedPreferences.getInstance();
    return _instance = ChatPrefs._(prefs);
  }

  /// Test seam: build from an in-memory store instead.
  ChatPrefs.forTest(this._prefs);

  final SharedPreferences _prefs;

  String _lockKey(String conversationId) => 'chat_lock_$conversationId';
  String _deletedKey(String conversationId) =>
      'chat_deleted_for_me_$conversationId';

  // --- Chat lock (point 12) -------------------------------------------

  bool hasLock(String conversationId) =>
      _prefs.getString(_lockKey(conversationId)) != null;

  /// Sets (or changes) the PIN for one chat. Each chat has its own
  /// separate lock (point 12).
  Future<void> setLock(String conversationId, String pin) async {
    await _prefs.setString(
      _lockKey(conversationId),
      hashChatPin(pin, conversationId),
    );
  }

  Future<void> removeLock(String conversationId) async {
    await _prefs.remove(_lockKey(conversationId));
  }

  /// True when [pin] unlocks this chat.
  bool verifyLock(String conversationId, String pin) {
    final hash = _prefs.getString(_lockKey(conversationId));
    if (hash == null) return false;
    return verifyChatPin(pin, conversationId, hash);
  }

  // --- Hidden chats keyword (point 13) --------------------------------

  /// The user's own secret keyword. Empty = not set yet.
  String get hiddenKeyword => _prefs.getString('hidden_chats_keyword') ?? '';

  Future<void> setHiddenKeyword(String keyword) async {
    await _prefs.setString('hidden_chats_keyword', keyword.trim());
  }

  // --- Delete for me (point 3) ----------------------------------------

  /// Message ids I deleted for myself in [conversationId].
  Set<String> deletedForMeIds(String conversationId) =>
      _prefs.getStringList(_deletedKey(conversationId))?.toSet() ?? {};

  Future<void> markDeletedForMe(
    String conversationId,
    String messageId,
  ) async {
    final ids = deletedForMeIds(conversationId)..add(messageId);
    await _prefs.setStringList(_deletedKey(conversationId), ids.toList());
  }

  /// Clears the local "deleted for me" list (used when a chat's
  /// history is cleared after a forgotten lock).
  Future<void> clearDeletedForMe(String conversationId) async {
    await _prefs.remove(_deletedKey(conversationId));
  }
}
