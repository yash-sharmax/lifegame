/// Chats tab (v2.11.0): the list of my conversations.
///
/// The messaging tables may not exist on the live Appwrite project
/// yet — every service call is wrapped in try/catch and a failure
/// shows a friendly inline state ("Chats are being set up — check
/// back soon") instead of crashing or showing a raw exception.
///
/// Hidden chats (point 13) are revealed only by the exact secret
/// keyword in search, or by typing a hidden chat's lock PIN in
/// search. Pending DM requests (point 1) get their own section with
/// Accept / Decline.
library;

import 'package:flutter/material.dart';

import '../data/chat_prefs.dart';
import '../data/messaging_models.dart';
import '../data/messaging_service.dart';
import '../data/models.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'saved_messages_screen.dart';

/// Short relative time for chat rows ("10:24 AM", "Yesterday",
/// "Mon", "12 Nov"). Shared by the chat screens.
///
/// v2.11.2 FIX 4: times are rendered DEVICE-LOCAL. Stored chat
/// instants arrive as UTC (server $createdAt, and UTC strings
/// since v2.11.2); the old code read `.hour` straight off the
/// stored value, so the same message showed "3:02 PM" from a
/// local-time-no-offset field and "9:32 AM" from the server's
/// true-UTC field. `toLocal()` first makes every source agree.
String formatChatTime(DateTime time) {
  final local = time.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final amPm = local.hour < 12 ? 'AM' : 'PM';
  final clock =
      '$hour:${local.minute.toString().padLeft(2, '0')} $amPm';
  if (diff == 0) return clock;
  if (diff == 1) return 'Yesterday';
  if (diff < 7) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return weekdays[local.weekday - 1];
  }
  const months = [
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
  return '${local.day} ${months[local.month - 1]}';
}

/// The rows to show for a search query (v2.11.2 FIX 2, pure and
/// unit-tested). A plain name search filters by name; a hidden-chat
/// REVEAL (secret keyword or lock PIN — [revealActive]) shows the
/// revealed rows as-is. The keyword/PIN is not a name, so running
/// the name filter on it would hide everything the reveal just
/// loaded ("No chats yet" for the exact keyword "pineapple").
List<ConversationItem> visibleChatItems({
  required List<ConversationItem> items,
  required String query,
  required bool revealActive,
  required String Function(ConversationItem) nameFor,
}) {
  final q = query.trim();
  if (q.isEmpty) return items;
  if (revealActive) return items;
  final lower = q.toLowerCase();
  return items
      .where((item) => nameFor(item).toLowerCase().contains(lower))
      .toList();
}

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final MessagingService _service = MessagingService();
  final ProfileRepository _profiles = ProfileRepository();
  final _searchController = TextEditingController();

  List<ConversationItem> _items = [];
  List<ConversationItem> _requests = [];
  // Display names for DM rows, keyed by the other user's id.
  final Map<String, String> _names = {};
  final Map<String, Profile> _profilesById = {};
  // Decrypted previews, keyed by conversation id (v2.11.2 FIX 5):
  // the stored lastMessagePreview goes stale, so after loading we
  // resolve the real latest message per chat and show its text.
  final Map<String, String> _previewOverrides = {};
  // v2.11.3 FIX 4: the lastMessageAt each override was resolved
  // for. An override stays valid across reloads while the last
  // message has not changed — clearing it on every load made rows
  // flip back to the stored "Encrypted message" until the slow
  // re-resolution finished.
  final Map<String, DateTime?> _previewResolvedAt = {};
  bool _loading = true;
  bool _notSetUp = false;
  bool _showingHidden = false;
  // True while the search box holds a hidden-chat reveal (secret
  // keyword or lock PIN) — the revealed rows show as-is, not
  // name-filtered (v2.11.2 FIX 2).
  bool _revealActive = false;
  // v2.11.3 FIX 3: the search generation. Every keystroke bumps
  // it; a handler superseded by a newer keystroke aborts instead
  // of clobbering the reveal (fast typing used to let a stale
  // "pineappl" handler reset _revealActive after the "pineapple"
  // handler had already revealed the hidden chats).
  int _searchGen = 0;
  // v2.11.3 FIX 3: the secret keyword, cached once at startup so
  // the reveal decision on a keystroke is synchronous — no await
  // between the keystroke and the decision.
  String _hiddenKeyword = '';
  // Hidden chats, loaded only when the search looks like a keyword
  // or a PIN — the verifyLock check runs over this small list.
  List<ConversationItem>? _hiddenItems;

  @override
  void initState() {
    super.initState();
    _load();
    _loadHiddenKeyword();
  }

  /// Caches the secret keyword once (v2.11.3 FIX 3) so the reveal
  /// decision on a keystroke is synchronous.
  Future<void> _loadHiddenKeyword() async {
    try {
      final keyword = (await ChatPrefs.instance()).hiddenKeyword;
      if (mounted) setState(() => _hiddenKeyword = keyword);
    } catch (_) {}
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool includeHidden = false, int? forSearchGen}) async {
    if (mounted) setState(() => _loading = true);
    try {
      final items = await _service.listMyConversations(
        includeHidden: includeHidden,
      );
      final requests = await _service.pendingMessageRequests();
      if (!mounted) return;
      // v2.11.3 FIX 3: a search handler superseded by a newer
      // keystroke must not apply its results.
      if (forSearchGen != null && forSearchGen != _searchGen) return;
      setState(() {
        _items = items;
        _requests = requests;
        // v2.11.3 FIX 4: keep resolved previews across reloads.
        // Drop an override only when its conversation is gone or
        // its last message changed — clearing them all on every
        // load made rows flip back to "Encrypted message" until
        // the slow re-resolution finished.
        final liveIds = items.map((i) => i.conversation.id).toSet();
        _previewOverrides.removeWhere((id, _) => !liveIds.contains(id));
        _previewResolvedAt.removeWhere((id, _) => !liveIds.contains(id));
        for (final item in items) {
          final id = item.conversation.id;
          if (_previewResolvedAt[id] != item.conversation.lastMessageAt) {
            _previewOverrides.remove(id);
            _previewResolvedAt.remove(id);
          }
        }
        _loading = false;
        _notSetUp = false;
        _showingHidden = includeHidden;
      });
      await _resolveNames(items);
      await _resolvePreviews(items);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _notSetUp = true;
      });
    }
  }

  /// Resolves the real preview per chat (v2.11.2 FIX 5): the stored
  /// `lastMessagePreview` goes stale — a group row read "No
  /// messages yet" after a message was sent, and "Encrypted
  /// message" instead of the actual text. The decrypted latest
  /// message is the truth; when a chat has no visible message the
  /// stored preview stays.
  ///
  /// v2.11.3 FIX 4: a resolved preview for the current last
  /// message is NOT re-resolved on every reload — that is what
  /// made group rows flip back to "Encrypted message". Only
  /// conversations with a new last message (or no override yet)
  /// are resolved.
  Future<void> _resolvePreviews(List<ConversationItem> items) async {
    var changed = false;
    for (final item in items) {
      final c = item.conversation;
      if (c.isRequest) continue;
      if (_previewOverrides.containsKey(c.id) &&
          _previewResolvedAt[c.id] == c.lastMessageAt) {
        continue;
      }
      final stored = c.lastMessagePreview;
      if (stored != null && stored != 'Encrypted message') continue;
      try {
        final latest = await _service.latestVisibleMessage(c.id);
        if (latest == null) continue;
        final preview = chatPreviewForMessage(latest);
        if (preview.isEmpty || preview == 'Encrypted message') continue;
        if (_previewOverrides[c.id] != preview) {
          _previewOverrides[c.id] = preview;
          _previewResolvedAt[c.id] = c.lastMessageAt;
          changed = true;
        }
      } catch (_) {}
    }
    if (changed && mounted) setState(() {});
  }

  /// Resolves the display name for each DM row (the other person's
  /// name) — group rows use their title. Best-effort, cached.
  Future<void> _resolveNames(List<ConversationItem> items) async {
    var changed = false;
    for (final item in items) {
      final otherId = item.otherUserId;
      if (otherId == null || _names.containsKey(otherId)) continue;
      try {
        final profile = await _profiles.fetchProfile(otherId);
        if (profile != null) {
          _names[otherId] = profile.displayName;
          _profilesById[otherId] = profile;
          changed = true;
        }
      } catch (_) {}
    }
    if (changed && mounted) setState(() {});
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

  /// The rows to show for the current search text.
  List<ConversationItem> get _visibleItems => visibleChatItems(
    items: _items,
    query: _searchController.text,
    revealActive: _revealActive,
    nameFor: _nameFor,
  );

  Future<void> _onSearchChanged(String query) async {
    // v2.11.3 FIX 3: every keystroke bumps the generation. A
    // handler superseded by a newer keystroke aborts after each
    // await instead of clobbering the reveal — fast typing used
    // to let a stale "pineappl" handler reset _revealActive (and
    // reload the visible-only list) after the "pineapple" handler
    // had already revealed the hidden chats, so the reveal only
    // appeared after pressing Enter.
    final gen = ++_searchGen;
    final trimmed = query.trim();
    // Exact secret keyword → reveal hidden chats (point 13). The
    // check runs against the cached keyword, so the reveal
    // decision is synchronous on the keystroke. When the cache is
    // not loaded yet (first seconds after launch), read it once.
    var keyword = _hiddenKeyword;
    if (keyword.isEmpty && trimmed.isNotEmpty) {
      try {
        keyword = (await ChatPrefs.instance()).hiddenKeyword;
        if (keyword.isNotEmpty && mounted) _hiddenKeyword = keyword;
      } catch (_) {}
    }
    if (!mounted || gen != _searchGen) return;
    if (matchesHiddenKeyword(trimmed, keyword)) {
      _revealActive = true;
      await _load(includeHidden: true, forSearchGen: gen);
      return;
    }
    // A hidden chat's lock PIN typed in search reveals that chat.
    if (trimmed.length >= 4) {
      try {
        final prefs = await ChatPrefs.instance();
        if (!mounted || gen != _searchGen) return;
        _hiddenItems ??= await _service.listMyConversations(
          includeHidden: true,
        );
        if (!mounted || gen != _searchGen) return;
        final unlocked = _hiddenItems!
            .where((item) => prefs.verifyLock(item.conversation.id, trimmed))
            .toList();
        if (unlocked.isNotEmpty && mounted) {
          setState(() {
            _items = unlocked;
            _showingHidden = true;
            _revealActive = true;
          });
          await _resolveNames(unlocked);
          return;
        }
      } catch (_) {}
    }
    // Plain name search — back to the normal list if we were showing
    // hidden chats for a previous query.
    if (!mounted || gen != _searchGen) return;
    _revealActive = false;
    if (_showingHidden && !matchesHiddenKeyword(trimmed, keyword)) {
      await _load(forSearchGen: gen);
      return;
    }
    setState(() {});
  }

  Future<void> _openChat(ConversationItem item) async {
    final conversation = item.conversation;
    ChatPrefs? prefs;
    try {
      prefs = await ChatPrefs.instance();
    } catch (_) {}
    if (prefs != null && prefs.hasLock(conversation.id)) {
      final unlocked = await _askForPin(conversation);
      if (unlocked == null) return; // Cancelled or forgot → handled inside.
      if (!unlocked) return; // Wrong PIN — stay on the list.
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      WarriorPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
    );
    // Back from the chat — refresh (a request may have been accepted,
    // history may have been cleared, read states changed).
    if (mounted) _load();
  }

  /// PIN dialog for a locked chat. Returns true when unlocked, false
  /// on a wrong PIN, null when cancelled. "Forgot PIN?" clears the
  /// chat's history (point 12) and then opens it fresh.
  Future<bool?> _askForPin(Conversation conversation) async {
    final pinController = TextEditingController();
    String? error;
    bool? result;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Locked chat'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Enter the PIN for this chat.'),
              const SizedBox(height: 12),
              TextField(
                controller: pinController,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'PIN',
                  errorText: error,
                  counterText: '',
                ),
                onSubmitted: (_) async {
                  await _checkPin(
                    dialogContext,
                    conversation,
                    pinController.text,
                    (ok) => result = ok,
                    (e) => setDialogState(() => error = e),
                  );
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final forgot = await showDialog<bool>(
                  context: dialogContext,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Forgot PIN?'),
                    content: const Text(
                      'There is no way to recover a forgotten PIN. '
                      'This chat\'s history will be cleared and the '
                      'lock removed, so you can start fresh.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Keep locked'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Clear history'),
                      ),
                    ],
                  ),
                );
                if (forgot != true) return;
                try {
                  await _service.clearConversationHistory(conversation.id);
                  final prefs = await ChatPrefs.instance();
                  await prefs.removeLock(conversation.id);
                } catch (_) {}
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                result = true;
                if (!mounted) return;
                await navigator.push(
                  WarriorPageRoute(
                    builder: (_) => ChatScreen(conversation: conversation),
                  ),
                );
                if (mounted) _load();
              },
              child: const Text('Forgot PIN?'),
            ),
            FilledButton(
              onPressed: () async {
                await _checkPin(
                  dialogContext,
                  conversation,
                  pinController.text,
                  (ok) => result = ok,
                  (e) => setDialogState(() => error = e),
                );
              },
              child: const Text('Unlock'),
            ),
          ],
        ),
      ),
    );
    pinController.dispose();
    return result;
  }

  Future<void> _checkPin(
    BuildContext dialogContext,
    Conversation conversation,
    String pin,
    void Function(bool) onResult,
    void Function(String) onError,
  ) async {
    bool ok = false;
    try {
      ok = (await ChatPrefs.instance()).verifyLock(conversation.id, pin);
    } catch (_) {}
    if (ok) {
      onResult(true);
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
    } else {
      onError('Wrong PIN. Try again.');
      onResult(false);
    }
  }

  Future<void> _setHiddenKeyword() async {
    String current = '';
    try {
      current = (await ChatPrefs.instance()).hiddenKeyword;
    } catch (_) {}
    if (!mounted) return;
    final controller = TextEditingController(text: current);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hidden-chats keyword'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Type this exact word in the search bar to reveal chats '
              'you have hidden. Keep it secret.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Secret keyword'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      try {
        await (await ChatPrefs.instance()).setHiddenKeyword(controller.text);
        // v2.11.3 FIX 3: keep the cached keyword in sync so the
        // reveal works on live typing right after saving.
        if (mounted) {
          setState(() => _hiddenKeyword = controller.text.trim());
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Hidden-chats keyword saved.')),
          );
        }
      } catch (_) {}
    }
    controller.dispose();
  }

  Future<void> _respondToRequest(
    ConversationItem item,
    bool accept,
  ) async {
    try {
      if (accept) {
        await _service.acceptRequest(item.conversation.id);
      } else {
        await _service.declineRequest(item.conversation.id);
      }
      if (mounted) _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update the request. $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.message_outlined),
            tooltip: 'New chat',
            onPressed: () async {
              await Navigator.of(context).push(
                WarriorPageRoute(builder: (_) => const NewChatScreen()),
              );
              if (mounted) _load();
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) async {
              if (value == 'keyword') {
                await _setHiddenKeyword();
              } else if (value == 'saved') {
                await Navigator.of(context).push(
                  WarriorPageRoute(
                    builder: (_) => const SavedMessagesScreen(),
                  ),
                );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'keyword',
                child: Text('Set hidden-chats keyword'),
              ),
              PopupMenuItem(
                value: 'saved',
                child: Text('Saved messages'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: LoadingIcon())
          : _notSetUp
          ? RefreshIndicator(
              onRefresh: () => _load(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: const [
                  SizedBox(height: 40),
                  EmptyState(
                    icon: Icons.chat_bubble_outline,
                    title: 'Chats are being set up',
                    subtitle:
                        'Messaging is not ready yet — check back soon. '
                        'Your habits and reminders are unaffected.',
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: () => _load(),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                children: [
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search chats',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchController.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchController.clear();
                                _onSearchChanged('');
                              },
                            ),
                    ),
                    onChanged: _onSearchChanged,
                  ),
                  const SizedBox(height: 12),
                  if (_requests.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 6,
                      ),
                      child: Text(
                        'Requests',
                        style: TextStyle(
                          color: AppTheme.inkSoft,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    for (final request in _requests)
                      _RequestRow(
                        item: request,
                        name: _nameFor(request),
                        onAccept: () => _respondToRequest(request, true),
                        onDecline: () => _respondToRequest(request, false),
                      ),
                    const SizedBox(height: 8),
                  ],
                  if (_visibleItems.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 48),
                      child: EmptyState(
                        icon: Icons.chat_bubble_outline,
                        title: 'No chats yet',
                        subtitle:
                            'Message someone you follow to start a chat. '
                            'Mutual friends chat directly; others get a '
                            'request they can accept.',
                      ),
                    )
                  else
                    for (final item in _visibleItems)
                      _ChatRow(
                        item: item,
                        name: _nameFor(item),
                        previewOverride:
                            _previewOverrides[item.conversation.id],
                        profile: item.otherUserId == null
                            ? null
                            : _profilesById[item.otherUserId],
                        onTap: () => _openChat(item),
                      ),
                ],
              ),
            ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  const _RequestRow({
    required this.item,
    required this.name,
    required this.onAccept,
    required this.onDecline,
  });

  final ConversationItem item;
  final String name;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            AvatarCircle(initials: _initialsFor(name), size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'wants to message you',
                    style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onDecline, child: const Text('Decline')),
            FilledButton(onPressed: onAccept, child: const Text('Accept')),
          ],
        ),
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

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.item,
    required this.name,
    required this.profile,
    required this.onTap,
    this.previewOverride,
  });

  final ConversationItem item;
  final String name;
  final Profile? profile;
  final VoidCallback onTap;

  /// Decrypted latest-message text (v2.11.2 FIX 5) — wins over the
  /// stored preview, which goes stale.
  final String? previewOverride;

  @override
  Widget build(BuildContext context) {
    final c = item.conversation;
    final preview = c.isRequest
        ? 'Message request — tap to view'
        : (previewOverride ??
              (c.lastMessagePreview ?? 'No messages yet'));
    return Card(
      child: ListTile(
        leading: Stack(
          children: [
            AvatarCircle(
              initials: c.isGroup
                  ? _initialsFor(name)
                  : (profile?.initials ?? _initialsFor(name)),
              size: 48,
            ),
            if (c.isGroup)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.group, size: 14),
                ),
              ),
          ],
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (c.lastMessageAt != null)
              Text(
                formatChatTime(c.lastMessageAt!),
                style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
              ),
          ],
        ),
        subtitle: Row(
          children: [
            Expanded(
              child: Text(
                preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: item.unread ? AppTheme.ink : AppTheme.inkSoft,
                  fontWeight: item.unread
                      ? FontWeight.w700
                      : FontWeight.normal,
                ),
              ),
            ),
            if (item.unread)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(left: 6),
                decoration: const BoxDecoration(
                  color: AppTheme.ember,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
