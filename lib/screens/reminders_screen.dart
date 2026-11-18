// Reminders tab (v2.9.0, 18 Nov 2026): a chat interface, like
// WhatsApp Nevermiss. The user types a reminder in plain words and
// the app parses the time locally (see logic/chat_reminders.dart),
// confirms in a bot bubble, and fires a local notification at the
// scheduled time (even with the app closed, via an Android exact
// alarm). The chat history and the scheduled reminders live in
// LOCAL storage — the source of truth, never blocked on the network.
import 'package:appwrite/appwrite.dart';
import 'package:flutter/material.dart';

import '../data/local_store.dart';
import '../data/models.dart';
import '../data/reminder_service.dart';
import '../data/repositories.dart';
import '../logic/chat_reminders.dart';
import '../theme.dart';

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});

  @override
  State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  List<ChatMessage> _messages = [];
  List<ChatReminder> _reminders = [];
  bool _sending = false;

  String get _ownerId => AuthRepository.cachedUser?.uid ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final store = await LocalStore.getInstance();
      final ownerId = _ownerId;
      if (ownerId.isEmpty) return;
      final messages = store.loadChatMessages(ownerId);
      final reminders = store.loadChatReminders(ownerId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _reminders = reminders;
      });
      _scrollToBottom();
    } catch (_) {}
  }

  List<ChatReminder> get _upcoming {
    final now = DateTime.now();
    final list = _reminders
        .where((r) => !r.fired && r.scheduledAt.isAfter(now))
        .toList()
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
    return list;
  }

  Future<void> _save() async {
    try {
      final store = await LocalStore.getInstance();
      await store.saveChatMessages(_ownerId, _messages);
      await store.saveChatReminders(_reminders);
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    final ownerId = _ownerId;
    if (ownerId.isEmpty) return;
    setState(() => _sending = true);
    _inputController.clear();
    final now = DateTime.now();
    final userMessage = ChatMessage(
      id: ID.unique(),
      ownerId: ownerId,
      role: 'user',
      text: text,
      createdAt: now,
    );
    setState(() => _messages.add(userMessage));
    _scrollToBottom();

    final parsed = parseChatReminder(text, now);
    if (parsed == null) {
      // No time found — say so, and set nothing.
      final reply = ChatMessage(
        id: ID.unique(),
        ownerId: ownerId,
        role: 'assistant',
        text: "I couldn't find a time in that message. Try adding a "
            "time like 'at 6pm' or 'kal subah 7 baje'.",
        createdAt: DateTime.now(),
      );
      setState(() {
        _messages.add(reply);
        _sending = false;
      });
      await _save();
      _scrollToBottom();
      return;
    }

    final reminder = ChatReminder(
      id: ID.unique(),
      ownerId: ownerId,
      text: parsed.text,
      scheduledAt: parsed.when,
      createdAt: now,
    );
    final confirmation = ChatMessage(
      id: ID.unique(),
      ownerId: ownerId,
      role: 'assistant',
      text: '${formatReminderConfirmation(parsed.when, parsed.text)}\n\n'
          "Tip: include a date, day, 'today' or 'tomorrow' with the "
          "time. Example: Call mom tomorrow at 7 pm.",
      createdAt: DateTime.now(),
    );
    setState(() {
      _reminders.add(reminder);
      _messages.add(confirmation);
      _sending = false;
    });
    await _save();
    _scrollToBottom();
    // The one-shot Android alarm (fires even with the app closed) +
    // the in-app timer re-check.
    await ReminderService.instance.scheduleAndroidChatReminder(reminder);
    await ReminderService.instance.refresh();
  }

  Future<void> _cancelReminder(ChatReminder reminder) async {
    await ReminderService.instance.cancelAndroidChatReminder(reminder);
    setState(() {
      _reminders.removeWhere((r) => r.id == reminder.id);
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final upcoming = _upcoming;
    return Scaffold(
      appBar: AppBar(title: const Text('Reminders')),
      body: Column(
        children: [
          if (upcoming.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              decoration: BoxDecoration(
                color: AppTheme.card,
                border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Upcoming (${upcoming.length})',
                    style: TextStyle(
                      color: AppTheme.inkSoft,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final reminder in upcoming)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.alarm,
                            size: 16,
                            color: AppTheme.ember,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_shortWhen(reminder.scheduledAt)} — ${reminder.text}',
                              style: const TextStyle(fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            onPressed: () => _cancelReminder(reminder),
                            tooltip: 'Cancel reminder',
                            icon: const Icon(Icons.close, size: 18),
                            color: AppTheme.inkSoft,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            padding: EdgeInsets.zero,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? _EmptyChat()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) =>
                        _Bubble(message: _messages[i]),
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            decoration: BoxDecoration(
              color: AppTheme.card,
              border: Border(top: BorderSide(color: AppTheme.cardBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: const InputDecoration(
                      hintText: 'Type a reminder… e.g. Adrak aur kaali '
                          'mirch lana hai at 6pm',
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _sending ? null : _send,
                  tooltip: 'Send',
                  icon: const Icon(Icons.send),
                  color: AppTheme.ember,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _shortWhen(DateTime when) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(when.year, when.month, when.day);
    final dayLabel = day == today
        ? 'Today'
        : day == today.add(const Duration(days: 1))
        ? 'Tomorrow'
        : '${when.day}/${when.month}';
    final hour12 = when.hour % 12 == 0 ? 12 : when.hour % 12;
    final suffix = when.hour >= 12 ? 'PM' : 'AM';
    final minute = when.minute.toString().padLeft(2, '0');
    return '$dayLabel $hour12:$minute $suffix';
  }
}

class _EmptyChat extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: AppTheme.inkSoft),
            const SizedBox(height: 12),
            const Text(
              'Type a reminder in plain words',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Try: "Adrak aur kaali mirch lana hai at 6pm" or '
              '"Kal subah 7 baje mithai lane ka yaad dilao". I will '
              'confirm the time and remind you when it is due.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          gradient: isUser ? AppTheme.emberGradient : null,
          color: isUser ? null : AppTheme.card,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
          border: isUser
              ? null
              : Border.all(color: AppTheme.cardBorder),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            // User bubbles sit on the violet gradient — always white.
            color: isUser ? AppTheme.onAccent : AppTheme.ink,
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}
