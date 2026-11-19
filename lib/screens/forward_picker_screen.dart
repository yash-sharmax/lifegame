/// Forward picker (v2.11.0): pick one of my conversations to forward
/// a message into. Pops with the chosen [Conversation] (or null when
/// cancelled).
library;

import 'package:flutter/material.dart';

import '../data/messaging_models.dart';
import '../data/messaging_service.dart';
import '../data/repositories.dart';
import '../widgets/common.dart';

class ForwardPickerScreen extends StatefulWidget {
  const ForwardPickerScreen({super.key});

  @override
  State<ForwardPickerScreen> createState() => _ForwardPickerScreenState();
}

class _ForwardPickerScreenState extends State<ForwardPickerScreen> {
  final MessagingService _service = MessagingService();
  final ProfileRepository _profiles = ProfileRepository();
  final _searchController = TextEditingController();

  List<ConversationItem> _items = [];
  final Map<String, String> _names = {};
  bool _loading = true;
  bool _notSetUp = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await _service.listMyConversations();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
      for (final item in items) {
        final otherId = item.otherUserId;
        if (otherId == null || _names.containsKey(otherId)) continue;
        try {
          final profile = await _profiles.fetchProfile(otherId);
          if (profile != null && mounted) {
            setState(() => _names[otherId] = profile.displayName);
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

  String _nameFor(ConversationItem item) {
    final c = item.conversation;
    if (c.isGroup) return c.title ?? 'Group chat';
    final otherId = item.otherUserId;
    if (otherId != null && _names.containsKey(otherId)) {
      return _names[otherId]!;
    }
    return 'Chat';
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final visible = query.isEmpty
        ? _items
        : _items
              .where((item) => _nameFor(item).toLowerCase().contains(query))
              .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Forward to…')),
      body: _loading
          ? const Center(child: LoadingIcon())
          : _notSetUp
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'Chats are being set up',
                  subtitle: 'Messaging is not ready yet — check back soon.',
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    hintText: 'Search chats',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                if (visible.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: EmptyState(
                      icon: Icons.chat_bubble_outline,
                      title: 'No chats found',
                      subtitle: 'Try a different search.',
                    ),
                  )
                else
                  for (final item in visible)
                    Card(
                      child: ListTile(
                        leading: AvatarCircle(
                          initials: _initialsFor(_nameFor(item)),
                          size: 44,
                        ),
                        title: Text(
                          _nameFor(item),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: item.conversation.isGroup
                            ? const Text('Group chat')
                            : null,
                        onTap: () => Navigator.of(
                          context,
                        ).pop(item.conversation),
                      ),
                    ),
              ],
            ),
    );
  }
}

String _initialsFor(String name) {
  final parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final p = parts.first;
    return p.length >= 2 ? p.substring(0, 2).toUpperCase() : p.toUpperCase();
  }
  return (parts.first[0] + parts.last[0]).toUpperCase();
}
