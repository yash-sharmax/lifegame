// Reminders tab (v2.9.0, 18 Nov 2026; v2.10.0 rework): a chat
// interface, like WhatsApp Nevermiss. The user types a reminder in
// plain words and the app parses the time, confirms in a bot bubble,
// and fires a local notification at the scheduled time (even with
// the app closed, via an Android exact alarm). The chat history and
// the scheduled reminders live in LOCAL storage — the source of
// truth, never blocked on the network.
//
// v2.10.0 parsing: when ONLINE the message first goes to the
// "parse-reminder" Appwrite Function (Gemini, a silent parser —
// never a chatbot); any failure falls back to the local parser
// (logic/chat_reminders.dart). Offline, the local parser runs and a
// manual set form is offered. The AI never produces a chat reply —
// the app's own confirmation / "couldn't find a time" bubbles stay
// exactly as they are.
//
// v2.10.0 also adds: delete a single message (long-press), clear the
// whole chat (app-bar menu, confirmed), an "Active reminders"
// section with a Stop button per reminder, and a manual set form
// (date + time + message) that works offline.
import 'package:appwrite/appwrite.dart';
import 'package:flutter/material.dart';

import '../data/ai_reminder_parser.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../data/reminder_service.dart';
import '../data/repositories.dart';
import '../data/sync_service.dart';
import '../logic/chat_reminders.dart';
import '../theme.dart';

/// The Reminders empty-state + input examples (v2.10.0): fresh
/// generic examples — never the user's own example messages.
const String kReminderInputHint = 'Type a reminder… e.g. Buy milk at 6pm';
const String kReminderEmptyExample =
    'Try: "Buy milk at 6pm" or "Call mom tomorrow at 7am". I will '
    'confirm the time and remind you when it is due.';
const String kReminderNoTimeMessage =
    "I couldn't find a time in that message. Try adding a time like "
    "'at 6pm' or 'tomorrow at 7am'.";

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

  // v2.10.1: the "couldn't find a time" banner is an inline row in
  // the layout (between the message list and the composer), NOT a
  // SnackBar. A SnackBar overlays the bottom of the screen and hid
  // the composer after a failed parse — the composer could only be
  // reached by reloading. The inline banner takes a fixed row of
  // space, the message list shrinks to make room, and the composer
  // stays pinned at the bottom, always visible and usable.
  // [_noTimeText] is the message to pre-fill the manual form with.
  bool _showNoTimeBanner = false;
  String _noTimeText = '';

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

  /// The task text for an AI result: the AI's task when it has one,
  /// else the local parser's stripped text, else the raw message.
  String _taskForAi(String message, String? aiTask, DateTime now) {
    if (aiTask != null && aiTask.trim().isNotEmpty) return aiTask.trim();
    final local = parseChatReminder(message, now);
    if (local != null && local.text.trim().isNotEmpty) return local.text;
    final trimmed = message.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed[0].toUpperCase() + trimmed.substring(1);
  }

  /// Creates the reminder + confirmation bubble + alarm for a parsed
  /// (or manually set) time. Shared by [_send] and the manual form.
  Future<void> _createReminder({
    required String text,
    required DateTime when,
  }) async {
    final ownerId = _ownerId;
    if (ownerId.isEmpty) return;
    final now = DateTime.now();
    final reminder = ChatReminder(
      id: ID.unique(),
      ownerId: ownerId,
      text: text,
      scheduledAt: when,
      createdAt: now,
    );
    final confirmation = ChatMessage(
      id: ID.unique(),
      ownerId: ownerId,
      role: 'assistant',
      text: '${formatReminderConfirmation(when, text)}\n\n'
          "Tip: include a date, day, 'today' or 'tomorrow' with the "
          "time. Example: Call mom tomorrow at 7 am.",
      createdAt: DateTime.now(),
    );
    setState(() {
      _reminders.add(reminder);
      _messages.add(confirmation);
    });
    await _save();
    _scrollToBottom();
    // The one-shot Android alarm (fires even with the app closed) +
    // the in-app timer re-check.
    await ReminderService.instance.scheduleAndroidChatReminder(reminder);
    await ReminderService.instance.refresh();
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    final ownerId = _ownerId;
    if (ownerId.isEmpty) return;
    setState(() {
      _sending = true;
      // A new message dismisses the previous no-time banner.
      _showNoTimeBanner = false;
    });
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

    // v2.10.0: try the AI parser first when online — it understands
    // natural phrasing the local parser misses ("remind me at
    // 12.26am 19nov"). Any failure falls back to the local parser.
    ParsedReminder? parsed;
    if (SyncService.instance.isOnline) {
      final ai = await parseReminderWithAi(text, now);
      if (ai != null && ai.due != null) {
        parsed = ParsedReminder(
          text: _taskForAi(text, ai.task, now),
          when: ai.due!,
        );
      }
    }
    parsed ??= parseChatReminder(text, now);
    if (parsed == null) {
      // No time found — say so, set nothing, and show the inline
      // banner offering the manual form (pre-filled with what was
      // typed). The banner is part of the layout, so the composer
      // stays visible (v2.10.1).
      final reply = ChatMessage(
        id: ID.unique(),
        ownerId: ownerId,
        role: 'assistant',
        text: kReminderNoTimeMessage,
        createdAt: DateTime.now(),
      );
      setState(() {
        _messages.add(reply);
        _sending = false;
        _showNoTimeBanner = true;
        _noTimeText = text;
      });
      await _save();
      _scrollToBottom();
      return;
    }

    await _createReminder(text: parsed.text, when: parsed.when);
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _cancelReminder(ChatReminder reminder) async {
    await ReminderService.instance.cancelAndroidChatReminder(reminder);
    setState(() {
      _reminders.removeWhere((r) => r.id == reminder.id);
    });
    await _save();
  }

  /// Long-press a bubble: delete that one message (the reminder
  /// itself, if any, is NOT cancelled — use Stop in Active
  /// reminders for that).
  Future<void> _showMessageActions(ChatMessage message) async {
    final delete = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete message'),
              onTap: () => Navigator.of(context).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (delete != true) return;
    setState(() {
      _messages.removeWhere((m) => m.id == message.id);
    });
    await _save();
  }

  /// Clears the whole chat (confirmed). Active reminders are NOT
  /// cancelled — those live in the Active reminders section.
  Future<void> _clearChat() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text(
          'This deletes all messages in this chat. Active reminders '
          'will not be cancelled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _messages.clear());
    await _save();
  }

  /// Manual set form (works offline): date picker, time picker and
  /// a message field. [initialText] pre-fills the message (used when
  /// the parser could not find a time).
  Future<void> _openManualForm({String? initialText}) async {
    final now = DateTime.now();
    var date = DateTime(now.year, now.month, now.day);
    var time = TimeOfDay.now();
    final textController = TextEditingController(text: initialText ?? '');
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Set reminder manually',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: textController,
                decoration: const InputDecoration(
                  labelText: 'What should I remind you about?',
                  hintText: 'e.g. Buy milk',
                  border: OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.calendar_today_outlined),
                title: const Text('Date'),
                subtitle: Text(_longDate(date)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: date,
                    firstDate: DateTime(now.year, now.month, now.day),
                    lastDate: now.add(const Duration(days: 365)),
                  );
                  if (picked != null) {
                    setSheetState(() => date = picked);
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.access_time),
                title: const Text('Time'),
                subtitle: Text(time.format(context)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: time,
                  );
                  if (picked != null) {
                    setSheetState(() => time = picked);
                  }
                },
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final message = textController.text.trim();
                    if (message.isEmpty) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        const SnackBar(
                          content: Text('Type what to remind you about.'),
                        ),
                      );
                      return;
                    }
                    final when = DateTime(
                      date.year,
                      date.month,
                      date.day,
                      time.hour,
                      time.minute,
                    );
                    if (!when.isAfter(DateTime.now())) {
                      ScaffoldMessenger.of(sheetContext).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Choose a future date and time.',
                          ),
                        ),
                      );
                      return;
                    }
                    await _createReminder(text: message, when: when);
                    if (sheetContext.mounted) {
                      Navigator.of(sheetContext).pop(true);
                    }
                  },
                  child: const Text('Set reminder'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    textController.dispose();
    if (created == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reminder set.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final upcoming = _upcoming;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Reminders'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'More options',
            onSelected: (value) {
              if (value == 'clear') _clearChat();
              if (value == 'manual') _openManualForm();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'manual',
                child: Text('Set manually'),
              ),
              PopupMenuItem(
                value: 'clear',
                child: Text('Clear chat'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Active reminders (v2.10.0): always visible — the list of
          // upcoming reminders with a Stop button each, or a subtle
          // line when there are none.
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
                  'Active reminders',
                  style: TextStyle(
                    color: AppTheme.inkSoft,
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                if (upcoming.isEmpty)
                  Text(
                    'No active reminders',
                    style: TextStyle(
                      color: AppTheme.inkSoft,
                      fontSize: 13,
                    ),
                  ),
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
                        TextButton(
                          onPressed: () => _cancelReminder(reminder),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 0,
                            ),
                            minimumSize: const Size(0, 30),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Stop'),
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
                    itemBuilder: (context, i) {
                      final message = _messages[i];
                      return GestureDetector(
                        onLongPress: () => _showMessageActions(message),
                        child: _Bubble(message: message),
                      );
                    },
                  ),
          ),
          // v2.10.1: the no-time banner is an inline row here, above
          // the composer. It reserves its own space, so the message
          // list above shrinks and the composer below never moves.
          // Same text and the same "Set manually" action the old
          // SnackBar had.
          if (_showNoTimeBanner)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
              decoration: BoxDecoration(
                color: AppTheme.card,
                border: Border(top: BorderSide(color: AppTheme.cardBorder)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      "Couldn't find a time — set it manually?",
                      style: TextStyle(color: AppTheme.ink, fontSize: 13),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _showNoTimeBanner = false);
                      _openManualForm(initialText: _noTimeText);
                    },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 36),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Set manually'),
                  ),
                  IconButton(
                    onPressed: () =>
                        setState(() => _showNoTimeBanner = false),
                    tooltip: 'Dismiss',
                    icon: const Icon(Icons.close, size: 18),
                    color: AppTheme.inkSoft,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                ],
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
                IconButton(
                  onPressed: _openManualForm,
                  tooltip: 'Set manually',
                  icon: const Icon(Icons.edit_calendar_outlined),
                  color: AppTheme.inkSoft,
                ),
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    decoration: const InputDecoration(
                      hintText: kReminderInputHint,
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

  String _longDate(DateTime date) {
    const weekdays = [
      '',
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${weekdays[date.weekday]}, ${months[date.month]} ${date.day}, ${date.year}';
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
              kReminderEmptyExample,
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
