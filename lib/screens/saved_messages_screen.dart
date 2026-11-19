/// Saved messages (v2.11.0, point 7): every message I starred across
/// all chats, newest first. Starred messages survive the 12-hour
/// auto-delete and the 150-message cap; the free-tier cap is 50.
///
/// Tapping a row opens that chat; the star button on a row unstarring
/// it removes it from this list.
library;

import 'package:flutter/material.dart';

import '../data/messaging_models.dart';
import '../data/messaging_service.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';
import 'chats_screen.dart';

class SavedMessagesScreen extends StatefulWidget {
  const SavedMessagesScreen({super.key});

  @override
  State<SavedMessagesScreen> createState() => _SavedMessagesScreenState();
}

class _SavedMessagesScreenState extends State<SavedMessagesScreen> {
  final MessagingService _service = MessagingService();
  final ProfileRepository _profiles = ProfileRepository();

  List<DmMessage> _messages = [];
  // Conversation names, keyed by conversation id.
  Map<String, String> _conversationNames = {};
  Map<String, Conversation> _conversations = {};
  bool _loading = true;
  bool _notSetUp = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final messages = await _service.listStarredMessages();
      final items = await _service.listMyConversations(includeHidden: true);
      if (!mounted) return;
      final names = <String, String>{};
      final conversations = <String, Conversation>{};
      for (final item in items) {
        conversations[item.conversation.id] = item.conversation;
        if (item.conversation.isGroup) {
          names[item.conversation.id] =
              item.conversation.title ?? 'Group chat';
        }
      }
      setState(() {
        _messages = messages;
        _conversationNames = names;
        _conversations = conversations;
        _loading = false;
      });
      // Resolve DM names (the other person's display name).
      for (final item in items) {
        if (item.conversation.isGroup) continue;
        final otherId = item.otherUserId;
        if (otherId == null) continue;
        try {
          final profile = await _profiles.fetchProfile(otherId);
          if (profile != null && mounted) {
            setState(
              () => _conversationNames[item.conversation.id] =
                  profile.displayName,
            );
          }
        } catch (_) {}
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notSetUp = true;
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _unstar(DmMessage message) async {
    try {
      await _service.unstarMessage(message.id);
      await _load();
    } catch (e) {
      _snack('Could not remove the saved message. $e');
    }
  }

  Future<void> _openChat(DmMessage message) async {
    final conversation = _conversations[message.conversationId];
    if (conversation == null) {
      _snack('That chat is no longer available.');
      return;
    }
    await Navigator.of(context).push(
      WarriorPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Saved messages')),
      body: _loading
          ? const Center(child: LoadingIcon())
          : _notSetUp
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(
                  icon: Icons.star_outline,
                  title: 'Chats are being set up',
                  subtitle: 'Messaging is not ready yet — check back soon.',
                ),
              ),
            )
          : _messages.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(
                  icon: Icons.star_outline,
                  title: 'No saved messages',
                  subtitle:
                      'Star a message in any chat to keep it here — '
                      'saved messages never auto-delete.',
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  final chatName =
                      _conversationNames[message.conversationId] ?? 'Chat';
                  return Card(
                    child: ListTile(
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: AppTheme.ember.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          message.isImage
                              ? Icons.photo_outlined
                              : Icons.star,
                          color: AppTheme.ember,
                        ),
                      ),
                      title: Text(
                        message.isImage
                            ? 'Photo'
                            : message.displayText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '$chatName • ${formatChatTime(message.createdAt)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.inkSoft),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.star),
                        color: AppTheme.gold,
                        tooltip: 'Remove from saved',
                        onPressed: () => _unstar(message),
                      ),
                      onTap: () => _openChat(message),
                    ),
                  );
                },
              ),
            ),
    );
  }
}
