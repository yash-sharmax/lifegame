/// One chat thread (v2.11.0): a normal WhatsApp-style chat.
///
/// Messages reload every 15 seconds while open (cheap polling —
///
/// there is no realtime subscription) and after every action.
/// Every service call is try/catch: when the messaging tables are
/// not on the live project yet the screen shows a friendly inline
/// state instead of crashing.
///
/// Private Chat OFF (point 14): leaving the chat deletes this
/// session's history, and starring is blocked while it is off.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/imgbb.dart';
import '../data/link_preview.dart';
import '../data/messaging_models.dart';
import '../data/messaging_service.dart';
import '../data/models.dart';
import '../data/repositories.dart';
import '../data/secure_chat.dart';
import '../data/typing_service.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/typing_indicator.dart';
import 'chat_info_screen.dart';
import 'chats_screen.dart';
import 'forward_picker_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.conversation});

  final Conversation conversation;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final MessagingService _service = MessagingService();
  final ProfileRepository _profiles = ProfileRepository();
  final TypingService _typingService = TypingService();
  final _composerController = TextEditingController();
  final _scrollController = ScrollController();

  List<DmMessage> _messages = [];
  bool _loading = true;
  bool _notSetUp = false;
  bool _sending = false;
  Timer? _refreshTimer;
  // v2.11.5: typing indicator — polled every 3s while the chat is
  // open; the idle timer clears my row ~5s after my last keystroke.
  Timer? _typingTimer;
  Timer? _typingIdleTimer;
  List<String> _typingNames = [];

  ChatSettings? _settings;
  String _myId = '';
  String _title = '';
  String _subtitle = '';
  Profile? _otherProfile;

  // v2.11.2 FIX 6: true once this request was accepted in this
  // screen — the banner goes away without leaving the chat.
  bool _requestResolved = false;

  // Sender display names (groups), keyed by user id.
  final Map<String, String> _senderNames = {};
  // Reply targets, keyed by the replied-to message id.
  final Map<String, DmMessage?> _replyCache = {};
  // Link previews, keyed by URL.
  final Map<String, LinkPreviewData?> _previewCache = {};
  // Read receipts for MY messages: true = read by all other members.
  final Map<String, bool> _readByAll = {};
  // Ids of the other members (for the read-by-all check).
  List<String> _otherMemberIds = [];
  // Starred message ids in this chat.
  Set<String> _starredIds = {};

  // Selection mode (long-press).
  final Set<String> _selectedIds = {};
  // The message being replied to, or null.
  DmMessage? _replyTo;
  // The message being edited, or null.
  DmMessage? _editing;

  bool get _selectionMode => _selectedIds.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _myId = AuthRepository.cachedUser?.uid ?? '';
    _title = widget.conversation.isGroup
        ? (widget.conversation.title ?? 'Group chat')
        : 'Chat';
    _subtitle = widget.conversation.isGroup ? '' : 'tap for info';
    _open();
  }

  Future<void> _open() async {
    try {
      await _service.markRead(widget.conversation.id);
    } catch (_) {}
    await _loadSettings();
    await _loadTitle();
    await _loadMessages();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _loadMessages(silent: true),
    );
    // v2.11.5: typing indicator — fetch who is typing every 3s
    // while this chat is open.
    _typingTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshTyping(),
    );
    unawaited(_refreshTyping());
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _service.settingsFor(widget.conversation.id);
      if (!mounted) return;
      setState(() => _settings = settings);
      if (settings.secureChat) await SecureChat.setSecure(true);
    } catch (_) {
      // No settings row yet (tables not set up) — defaults apply.
      if (mounted) {
        setState(
          () => _settings = ChatSettings.defaults(
            userId: _myId,
            conversationId: widget.conversation.id,
          ),
        );
      }
    }
  }

  Future<void> _loadTitle() async {
    final c = widget.conversation;
    if (c.isGroup) {
      try {
        final members = await _service.conversationMembers(c.id);
        if (mounted) {
          setState(
            () => _subtitle = '${members.length} member${members.length == 1 ? '' : 's'}',
          );
        }
      } catch (_) {}
      return;
    }
    try {
      final members = await _service.memberRows(c.id);
      String? otherId;
      for (final m in members) {
        if (m.userId != _myId) otherId = m.userId;
      }
      _otherMemberIds = members
          .map((m) => m.userId)
          .where((id) => id != _myId)
          .toList();
      if (otherId != null) {
        final profile = await _profiles.fetchProfile(otherId);
        if (mounted && profile != null) {
          setState(() {
            _otherProfile = profile;
            _title = profile.displayName;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _loadMessages({bool silent = false}) async {
    // v2.11.5 FIX 1: render from the cache instantly on first
    // open, then refresh from the server in the background. The
    // old code awaited the server (with decryption) behind a
    // full-screen spinner on every navigation.
    if (!silent && _messages.isEmpty) {
      try {
        final cached = await _service.listMessagesCached(
          widget.conversation.id,
        );
        if (mounted && cached.isNotEmpty) {
          setState(() {
            _messages = cached;
            _loading = false;
          });
          _scrollToBottom();
          unawaited(_resolveSenders(cached));
        }
      } catch (_) {}
    }
    if (!silent && mounted && _messages.isEmpty) {
      setState(() => _loading = true);
    }
    try {
      final messages = await _service.listMessages(widget.conversation.id);
      if (!mounted) return;
      setState(() {
        // Keep unmatched pending (offline-queued) messages visible
        // — the server list does not have them yet.
        _messages = mergeCachedMessages(server: messages, cached: _messages);
        _loading = false;
        _notSetUp = false;
      });
      _scrollToBottom();
      await _resolveSenders(messages);
      await _resolveReplies(messages);
      await _loadReadReceipts(messages);
      await _loadStarred();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // With cached messages on screen, a failed refresh just
        // means offline — keep reading the cache.
        if (_messages.isEmpty) _notSetUp = true;
      });
    }
  }

  // --- Typing indicator (v2.11.5) ------------------------------------

  /// Who is typing in this chat right now (names, fresh rows
  /// only, never me). Names resolve from the sender cache first,
  /// then a profile fetch — a DM typer with no messages yet still
  /// gets a name.
  Future<void> _refreshTyping() async {
    try {
      final rows = await _typingService.fetchTyping(widget.conversation.id);
      if (!mounted) return;
      final ids = freshTypingUserIds(
        rows: rows,
        myId: _myId,
        now: DateTime.now().toUtc(),
      );
      final names = <String>[];
      for (final id in ids) {
        var name = _senderNames[id];
        if (name == null) {
          try {
            final profile = await _profiles.fetchProfile(id);
            if (profile != null) {
              name = profile.displayName;
              _senderNames[id] = name;
            }
          } catch (_) {}
        }
        if (name != null) names.add(name);
      }
      if (!mounted) return;
      if (names.join('|') != _typingNames.join('|')) {
        setState(() => _typingNames = names);
      }
    } catch (_) {}
  }

  /// A keystroke: publish "I am typing" (throttled inside the
  /// service) and restart the idle timer that clears my row ~5s
  /// after I stop typing. Empty composer = stop typing now.
  void _onComposerChanged(String value) {
    if (value.isEmpty) {
      _typingIdleTimer?.cancel();
      unawaited(_typingService.clearTyping(widget.conversation.id));
      return;
    }
    unawaited(_typingService.publishTyping(widget.conversation.id));
    _typingIdleTimer?.cancel();
    _typingIdleTimer = Timer(kTypingIdleClearAfter, () {
      unawaited(_typingService.clearTyping(widget.conversation.id));
    });
  }

  Future<void> _resolveSenders(List<DmMessage> messages) async {
    var changed = false;
    for (final m in messages) {
      if (m.senderId == _myId || _senderNames.containsKey(m.senderId)) {
        continue;
      }
      try {
        final profile = await _profiles.fetchProfile(m.senderId);
        if (profile != null) {
          _senderNames[m.senderId] = profile.displayName;
          changed = true;
        }
      } catch (_) {}
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _resolveReplies(List<DmMessage> messages) async {
    var changed = false;
    for (final m in messages) {
      final replyId = m.replyToId;
      if (replyId == null || _replyCache.containsKey(replyId)) continue;
      try {
        _replyCache[replyId] = await _service.getMessage(replyId);
        changed = true;
      } catch (_) {}
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _loadReadReceipts(List<DmMessage> messages) async {
    if (_otherMemberIds.isEmpty) {
      try {
        final members = await _service.memberRows(widget.conversation.id);
        _otherMemberIds = members
            .map((m) => m.userId)
            .where((id) => id != _myId)
            .toList();
      } catch (_) {}
    }
    if (_otherMemberIds.isEmpty) return;
    var changed = false;
    for (final m in messages) {
      if (m.senderId != _myId || _readByAll.containsKey(m.id)) continue;
      try {
        final readers = await _service.readByUserIds(
          widget.conversation.id,
          m.createdAt,
        );
        final allRead = _otherMemberIds.every(readers.contains);
        if (_readByAll[m.id] != allRead) {
          _readByAll[m.id] = allRead;
          changed = true;
        }
      } catch (_) {}
    }
    if (changed && mounted) setState(() {});
  }

  Future<void> _loadStarred() async {
    try {
      final ids = await _service.starredIdsForConversation(
        widget.conversation.id,
      );
      if (mounted) setState(() => _starredIds = ids);
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _typingTimer?.cancel();
    _typingIdleTimer?.cancel();
    // v2.11.5: I am not typing once I leave the chat.
    unawaited(_typingService.clearTyping(widget.conversation.id));
    _composerController.dispose();
    _scrollController.dispose();
    // Secure Chat off again, and Private Chat OFF = this session's
    // history is deleted on leaving (point 14). Best-effort, silent.
    unawaited(SecureChat.setSecure(false));
    unawaited(_purgeIfPrivateOff());
    super.dispose();
  }

  Future<void> _purgeIfPrivateOff() async {
    try {
      final settings = await _service.settingsFor(widget.conversation.id);
      if (shouldPurgeHistoryOnLeave(privateChatOn: settings.privateChat)) {
        await _service.clearConversationHistory(widget.conversation.id);
      }
    } catch (_) {}
  }

  // --- Request banner (v2.11.2 FIX 6) ----------------------------------

  /// The request state inside this chat: null when it is not a
  /// pending request (or it was just resolved here).
  RequestBanner? get _requestBanner {
    if (_requestResolved) return null;
    return requestBannerFor(
      conversation: widget.conversation,
      myId: _myId,
    );
  }

  Future<void> _respondToRequest(bool accept) async {
    try {
      if (accept) {
        await _service.acceptRequest(widget.conversation.id);
        if (!mounted) return;
        setState(() => _requestResolved = true);
        await _loadMessages(silent: true);
      } else {
        await _service.declineRequest(widget.conversation.id);
        if (!mounted) return;
        Navigator.of(context).pop();
      }
    } catch (e) {
      _snack('Could not update the request. $e');
    }
  }

  Widget _buildRequestBanner(RequestBanner banner) {
    final waiting = banner == RequestBanner.waiting;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: AppTheme.card,
        border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.mark_email_unread_outlined,
            size: 20,
            color: AppTheme.ember,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              waiting
                  ? 'Requested — waiting for accept'
                  : '${_title.isEmpty ? 'This person' : _title} wants to message you',
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          if (waiting)
            Text(
              'Pending',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            )
          else ...[
            TextButton(
              onPressed: () => _respondToRequest(false),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () => _respondToRequest(true),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Accept'),
            ),
          ],
        ],
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  // --- Sending ------------------------------------------------------------

  Future<void> _sendText() async {
    final text = _composerController.text.trim();
    if (text.isEmpty || _sending) return;
    final editing = _editing;
    setState(() => _sending = true);
    try {
      if (editing != null) {
        await _service.editMessage(editing, text);
        setState(() => _editing = null);
      } else {
        try {
          await _service.sendText(
            widget.conversation.id,
            text,
            replyToId: _replyTo?.id,
          );
        } on Object catch (e) {
          if (!isNetworkError(e)) rethrow;
          // v2.11.5: offline — queue it, show it as "sending",
          // and let the outbox replay it when the network returns.
          final pending = await _service.queueOfflineText(
            widget.conversation.id,
            text,
            replyToId: _replyTo?.id,
          );
          if (mounted) {
            setState(() {
              _messages = [..._messages, pending];
              _replyTo = null;
            });
          }
          _composerController.clear();
          unawaited(_typingService.clearTyping(widget.conversation.id));
          _scrollToBottom();
          return;
        }
        setState(() => _replyTo = null);
      }
      _composerController.clear();
      unawaited(_typingService.clearTyping(widget.conversation.id));
      await _loadMessages(silent: true);
      try {
        await _service.markRead(widget.conversation.id);
      } catch (_) {}
    } catch (e) {
      _snack('Could not send. $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendPhoto({required bool viewOnce}) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      setState(() => _sending = true);
      try {
        await _service.sendImage(
          widget.conversation.id,
          bytes,
          filename: picked.name,
          replyToId: _replyTo?.id,
          isViewOnce: viewOnce,
        );
        setState(() => _replyTo = null);
        await _loadMessages(silent: true);
      } on ImgbbNotConfigured {
        _snack('Image attachments need setup — text still works');
      } catch (e) {
        _snack('Could not send the photo. $e');
      } finally {
        if (mounted) setState(() => _sending = false);
      }
    } catch (_) {
      // Image picker cancelled or unavailable — nothing to do.
    }
  }

  void _showAttachMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('Send photo'),
              onTap: () {
                Navigator.of(ctx).pop();
                _sendPhoto(viewOnce: false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility_off_outlined),
              title: const Text('Send view-once photo'),
              subtitle: const Text('Disappears after it is seen once'),
              onTap: () {
                Navigator.of(ctx).pop();
                _sendPhoto(viewOnce: true);
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- Selection actions --------------------------------------------------

  List<DmMessage> get _selectedMessages =>
      _messages.where((m) => _selectedIds.contains(m.id)).toList();

  void _toggleSelect(DmMessage message) {
    setState(() {
      if (_selectedIds.contains(message.id)) {
        _selectedIds.remove(message.id);
      } else {
        _selectedIds.add(message.id);
      }
    });
  }

  void _clearSelection() => setState(() => _selectedIds.clear());

  Future<void> _replyToSelected() async {
    if (_selectedMessages.length != 1) return;
    setState(() {
      _replyTo = _selectedMessages.first;
      _selectedIds.clear();
    });
  }

  Future<void> _forwardSelected() async {
    final selected = _selectedMessages;
    if (selected.isEmpty) return;
    final target = await Navigator.of(context).push<Conversation>(
      WarriorPageRoute(builder: (_) => const ForwardPickerScreen()),
    );
    if (target == null) return;
    try {
      for (final m in selected) {
        await _service.forwardMessage(m, target.id);
      }
      _snack(
        'Forwarded ${selected.length} message${selected.length == 1 ? '' : 's'}',
      );
    } catch (e) {
      _snack('Could not forward. $e');
    }
    _clearSelection();
    await _loadMessages(silent: true);
  }

  Future<void> _starSelected() async {
    final selected = _selectedMessages;
    if (selected.isEmpty) return;
    if (!canStarInChat(privateChatOn: _settings?.privateChat ?? true)) {
      _snack('Starring is off in Private Chat');
      _clearSelection();
      return;
    }
    try {
      for (final m in selected) {
        if (_starredIds.contains(m.id)) {
          await _service.unstarMessage(m.id);
        } else {
          await _service.starMessage(m);
        }
      }
    } on SaveCapReachedException catch (e) {
      _snack(e.toString());
    } catch (e) {
      _snack('Could not save. $e');
    }
    _clearSelection();
    await _loadStarred();
  }

  Future<void> _deleteSelected() async {
    final selected = _selectedMessages;
    if (selected.isEmpty) return;
    final mineOnly = selected.every((m) => m.senderId == _myId);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Delete for me'),
              onTap: () => Navigator.of(ctx).pop('me'),
            ),
            if (mineOnly)
              ListTile(
                leading: const Icon(Icons.delete_forever_outlined),
                title: const Text('Delete for everyone'),
                onTap: () => Navigator.of(ctx).pop('all'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    try {
      for (final m in selected) {
        if (choice == 'all') {
          await _service.deleteForEveryone(m);
        } else {
          await _service.deleteForMe(widget.conversation.id, m);
        }
      }
    } catch (e) {
      _snack('Could not delete. $e');
    }
    _clearSelection();
    await _loadMessages(silent: true);
  }

  Future<void> _copySelected() async {
    final selected = _selectedMessages;
    if (selected.length != 1) return;
    final m = selected.first;
    if (m.isImage) return;
    await Clipboard.setData(ClipboardData(text: m.displayText));
    _snack('Copied');
    _clearSelection();
  }

  Future<void> _showInfo(DmMessage message) async {
    final isMine = message.senderId == _myId;
    final senderName = isMine
        ? 'You'
        : (_senderNames[message.senderId] ?? 'Someone');
    List<String> readBy = [];
    try {
      final ids = await _service.readByUserIds(
        widget.conversation.id,
        message.createdAt,
      );
      for (final id in ids) {
        if (id == _myId) continue;
        String name = _senderNames[id] ?? '';
        if (name.isEmpty) {
          try {
            final profile = await _profiles.fetchProfile(id);
            name = profile?.displayName ?? 'Someone';
          } catch (_) {
            name = 'Someone';
          }
        }
        readBy.add(name);
      }
    } catch (_) {}
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Message info'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _InfoRow(label: 'From', value: senderName),
            _InfoRow(
              label: 'Sent',
              // v2.11.2 FIX 4: the date parts are device-local too
              // (formatChatTime already converts; the raw fields
              // would show the UTC day after a late-night message).
              value:
                  '${formatChatTime(message.createdAt)} • '
                  '${message.createdAt.toLocal().day}/${message.createdAt.toLocal().month}/${message.createdAt.toLocal().year}',
            ),
            if (message.editedAt != null)
              const _InfoRow(label: 'Edited', value: 'Yes'),
            _InfoRow(
              label: 'Encryption',
              value: message.encrypted
                  ? 'End-to-end encrypted'
                  : 'Not end-to-end encrypted',
            ),
            if (readBy.isNotEmpty)
              _InfoRow(label: 'Read by', value: readBy.join(', ')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _startEdit(DmMessage message) async {
    if (message.senderId != _myId || message.isImage) return;
    setState(() {
      _editing = message;
      _composerController.text = message.displayText;
      _selectedIds.clear();
    });
  }

  // --- Images -------------------------------------------------------------

  /// The photo widget for a message (v2.11.1, FIX 2): decrypted
  /// bytes for an encrypted photo, the network image for a plain
  /// one, and an honest lock placeholder when this device cannot
  /// decrypt it. Never renders the PNG carrier directly — it would
  /// just show noise.
  Widget _photoImage(
    DmMessage message, {
    double? width,
    double? height,
    required BoxFit fit,
  }) {
    final bytes = message.decryptedImageBytes;
    if (bytes != null) {
      return Image.memory(
        Uint8List.fromList(bytes),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (context, _, _) => _brokenPhoto(width, height),
      );
    }
    if (message.encrypted) {
      return Container(
        width: width,
        height: height ?? 120,
        color: AppTheme.cardBorder,
        alignment: Alignment.center,
        child: const Icon(Icons.lock_outline, size: 36),
      );
    }
    return Image.network(
      message.imageUrl ?? '',
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (context, _, _) => _brokenPhoto(width, height),
    );
  }

  Widget _brokenPhoto(double? width, double? height) => Container(
    width: width,
    height: height ?? 120,
    color: AppTheme.cardBorder,
    alignment: Alignment.center,
    child: const Icon(Icons.broken_image_outlined, size: 36),
  );

  Future<void> _openImage(DmMessage message) async {
    if (message.imageUrl == null) return;
    if (message.isViewOnce && message.viewOnceViewed) {
      _snack('Photo viewed once');
      return;
    }
    final isViewOnce = message.isViewOnce && !message.viewOnceViewed;
    await showDialog<void>(
      context: context,
      barrierColor: AppTheme.background.withValues(alpha: 0.92),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Center(
              child: _photoImage(message, fit: BoxFit.contain),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                icon: const Icon(Icons.close),
                color: AppTheme.onAccent,
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
            if (isViewOnce)
              const Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Text(
                  'View once — this photo disappears when you close it',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.onAccent),
                ),
              ),
          ],
        ),
      ),
    );
    if (isViewOnce) {
      try {
        await _service.markViewOnceViewed(message);
      } catch (_) {}
      await _loadMessages(silent: true);
    }
  }

  // --- Links ---------------------------------------------------------------

  Future<void> _openUrl(String url) async {
    final normalized = url.startsWith('www.') ? 'https://$url' : url;
    final uri = Uri.tryParse(normalized);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  List<TextSpan> _linkSpans(String text) {
    final urls = extractUrls(text);
    if (urls.isEmpty) {
      return [TextSpan(text: text)];
    }
    final spans = <TextSpan>[];
    var rest = text;
    for (final url in urls) {
      final index = rest.indexOf(url);
      if (index < 0) continue;
      if (index > 0) {
        spans.add(TextSpan(text: rest.substring(0, index)));
      }
      spans.add(
        TextSpan(
          text: url,
          style: const TextStyle(decoration: TextDecoration.underline),
          recognizer: TapGestureRecognizer()..onTap = () => _openUrl(url),
        ),
      );
      rest = rest.substring(index + url.length);
    }
    if (rest.isNotEmpty) spans.add(TextSpan(text: rest));
    return spans;
  }

  Future<void> _maybeFetchPreview(DmMessage message) async {
    if (message.isImage) return;
    final urls = extractUrls(message.displayText);
    if (urls.isEmpty || _previewCache.containsKey(urls.first)) return;
    final preview = await fetchLinkPreview(urls.first);
    if (!mounted) return;
    setState(() => _previewCache[urls.first] = preview);
  }

  // --- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final conversation = widget.conversation;
    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSelection,
              ),
              title: Text('${_selectedIds.length} selected'),
              actions: _selectionActions(),
            )
          : AppBar(
              title: InkWell(
                onTap: () async {
                  await Navigator.of(context).push(
                    WarriorPageRoute(
                      builder: (_) => ChatInfoScreen(
                        conversation: conversation,
                        otherProfile: _otherProfile,
                      ),
                    ),
                  );
                  // Settings may have changed (e.g. Secure Chat) —
                  // re-apply them when coming back.
                  if (mounted) {
                    await _loadSettings();
                    await _loadMessages(silent: true);
                  }
                },
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_title),
                    if (_subtitle.isNotEmpty)
                      Text(
                        _subtitle,
                        style: TextStyle(
                          color: AppTheme.inkSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
            ),
      body: _loading
          ? const Center(child: LoadingIcon())
          : _notSetUp
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: EmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'Chats are being set up',
                  subtitle:
                      'Messaging is not ready yet — check back soon.',
                ),
              ),
            )
          : Column(
              children: [
                // v2.11.2 FIX 6: the request state, inside the chat —
                // the list used to be the only place that showed it.
                if (_requestBanner != null)
                  _buildRequestBanner(_requestBanner!),
                Expanded(
                  child: _messages.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: EmptyState(
                              icon: Icons.chat_bubble_outline,
                              title: 'No messages yet',
                              subtitle:
                                  'Say hello — messages disappear after '
                                  '12 hours unless saved.',
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) =>
                              _buildMessageRow(_messages[index]),
                        ),
                ),
                if (_replyTo != null) _buildReplyBar(),
                if (_editing != null) _buildEditingBar(),
                // v2.11.5: animated "X is typing…" row above the
                // composer (group chats name the typer).
                if (_typingNames.isNotEmpty) _buildTypingRow(),
                _buildComposer(),
              ],
            ),
    );
  }

  List<Widget> _selectionActions() {
    final selected = _selectedMessages;
    final single = selected.length == 1;
    final first = single ? selected.first : null;
    final allStarred = selected.isNotEmpty &&
        selected.every((m) => _starredIds.contains(m.id));
    return [
      if (single)
        IconButton(
          icon: const Icon(Icons.reply),
          tooltip: 'Reply',
          onPressed: _replyToSelected,
        ),
      if (single &&
          first != null &&
          first.senderId == _myId &&
          !first.isImage &&
          !first.deletedForAll)
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'Edit',
          onPressed: () => _startEdit(first),
        ),
      IconButton(
        icon: const Icon(Icons.forward),
        tooltip: 'Forward',
        onPressed: _forwardSelected,
      ),
      IconButton(
        icon: Icon(allStarred ? Icons.star : Icons.star_border),
        tooltip: allStarred ? 'Unstar' : 'Star',
        onPressed: _starSelected,
      ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete',
        onPressed: _deleteSelected,
      ),
      if (single)
        IconButton(
          icon: const Icon(Icons.info_outline),
          tooltip: 'Info',
          onPressed: () async {
            final message = first!;
            _clearSelection();
            await _showInfo(message);
          },
        ),
      if (single && first != null && !first.isImage)
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy',
          onPressed: _copySelected,
        ),
    ];
  }

  Widget _buildReplyBar() {
    final replyTo = _replyTo!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.card,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        children: [
          const Icon(Icons.reply, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              replyTo.displayText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.inkSoft),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => setState(() => _replyTo = null),
          ),
        ],
      ),
    );
  }

  Widget _buildEditingBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.card,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_outlined, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('Editing message')),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => setState(() {
              _editing = null;
              _composerController.clear();
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildTypingRow() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
      decoration: BoxDecoration(
        color: AppTheme.card,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        children: [
          const TypingDots(),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              typingLabel(_typingNames),
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: AppTheme.inkSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        decoration: BoxDecoration(
          color: AppTheme.card,
          border: Border(top: BorderSide(color: AppTheme.cardBorder)),
        ),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file),
              tooltip: 'Attach photo',
              onPressed: _sending ? null : _showAttachMenu,
            ),
            Expanded(
              child: TextField(
                controller: _composerController,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: _editing != null
                      ? 'Edit message'
                      : 'Type a message',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                // v2.11.5: typing indicator — publish while typing.
                onChanged: _onComposerChanged,
                onSubmitted: (_) => _sendText(),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              decoration: const BoxDecoration(
                gradient: AppTheme.emberGradient,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: _sending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.onAccent,
                        ),
                      )
                    : Icon(
                        _editing != null ? Icons.check : Icons.send,
                        color: AppTheme.onAccent,
                      ),
                onPressed: _sending ? null : _sendText,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageRow(DmMessage message) {
    final isMine = message.senderId == _myId;
    final selected = _selectedIds.contains(message.id);
    var dragDx = 0.0;
    return GestureDetector(
      onLongPress: () => _toggleSelect(message),
      onTap: () {
        if (_selectionMode) _toggleSelect(message);
      },
      onHorizontalDragUpdate: (details) {
        dragDx += details.delta.dx;
      },
      onHorizontalDragEnd: (_) {
        if (dragDx > 60 && !message.deletedForAll) {
          setState(() => _replyTo = message);
        }
      },
      child: Container(
        color: selected
            ? AppTheme.ember.withValues(alpha: 0.12)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: isMine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isMine && widget.conversation.isGroup) ...[
              AvatarCircle(
                initials: _initialsFor(
                  _senderNames[message.senderId] ?? 'Someone',
                ),
                size: 30,
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.75,
                ),
                child: _buildBubble(message, isMine),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBubble(DmMessage message, bool isMine) {
    final reply = message.replyToId == null
        ? null
        : _replyCache[message.replyToId];
    final urls = message.isImage ? <String>[] : extractUrls(message.displayText);
    if (urls.isNotEmpty) {
      // Fetch the preview once per URL, lazily.
      unawaited(_maybeFetchPreview(message));
    }
    final preview = urls.isEmpty ? null : _previewCache[urls.first];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isMine ? AppTheme.ember : AppTheme.card,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMine ? 16 : 4),
          bottomRight: Radius.circular(isMine ? 4 : 16),
        ),
        border: isMine
            ? null
            : Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine && widget.conversation.isGroup)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                _senderNames[message.senderId] ?? 'Someone',
                style: const TextStyle(
                  color: AppTheme.ember,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ),
          if (message.forwarded)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.forward,
                    size: 13,
                    color: isMine
                        ? AppTheme.onAccent.withValues(alpha: 0.8)
                        : AppTheme.inkSoft,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    'Forwarded',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: isMine
                          ? AppTheme.onAccent.withValues(alpha: 0.8)
                          : AppTheme.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
          if (reply != null)
            Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: (isMine ? AppTheme.onAccent : AppTheme.ink)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(
                    color: isMine ? AppTheme.onAccent : AppTheme.ember,
                    width: 3,
                  ),
                ),
              ),
              child: Text(
                reply.displayText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: isMine
                      ? AppTheme.onAccent.withValues(alpha: 0.9)
                      : AppTheme.inkSoft,
                ),
              ),
            ),
          if (message.deletedForAll)
            Text(
              'This message was deleted',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: isMine
                    ? AppTheme.onAccent.withValues(alpha: 0.8)
                    : AppTheme.inkSoft,
              ),
            )
          else if (message.isImage)
            _buildImageContent(message, isMine)
          else
            RichText(
              text: TextSpan(
                style: TextStyle(
                  color: isMine ? AppTheme.onAccent : AppTheme.ink,
                  fontSize: 15,
                ),
                children: _linkSpans(message.displayText),
              ),
            ),
          if (preview != null) _buildLinkPreview(preview, urls.first, isMine),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_starredIds.contains(message.id))
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.star,
                    size: 13,
                    color: isMine
                        ? AppTheme.onAccent.withValues(alpha: 0.9)
                        : AppTheme.gold,
                  ),
                ),
              // v2.11.2 FIX B: no lock icon on message bubbles — the
              // user asked for it off. E2EE itself is unchanged;
              // the "End-to-end encrypted" line still shows in
              // Message info, and the Secure Chat indicator stays
              // on the chat info screen.
              Text(
                formatChatTime(message.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  color: isMine
                      ? AppTheme.onAccent.withValues(alpha: 0.75)
                      : AppTheme.inkSoft,
                ),
              ),
              if (message.editedAt != null)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    'Edited',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: isMine
                          ? AppTheme.onAccent.withValues(alpha: 0.75)
                          : AppTheme.inkSoft,
                    ),
                  ),
                ),
              if (isMine && !message.deletedForAll) ...[
                const SizedBox(width: 5),
                // v2.11.5: an offline-queued message shows a
                // "sending" clock instead of a tick until its
                // outbox op is replayed and the server row arrives.
                if (message.pending)
                  Icon(
                    Icons.access_time,
                    size: 15,
                    color: AppTheme.onAccent.withValues(alpha: 0.75),
                  )
                else
                  Icon(
                    _readByAll[message.id] == true
                        ? Icons.done_all
                        : Icons.done,
                    size: 15,
                    color: _readByAll[message.id] == true
                        ? const Color(0xFF7DD3FC)
                        : AppTheme.onAccent.withValues(alpha: 0.75),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImageContent(DmMessage message, bool isMine) {
    if (message.isViewOnce && message.viewOnceViewed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.visibility_off_outlined,
            size: 18,
            color: isMine
                ? AppTheme.onAccent.withValues(alpha: 0.8)
                : AppTheme.inkSoft,
          ),
          const SizedBox(width: 6),
          Text(
            'Photo viewed once',
            style: TextStyle(
              fontStyle: FontStyle.italic,
              color: isMine
                  ? AppTheme.onAccent.withValues(alpha: 0.8)
                  : AppTheme.inkSoft,
            ),
          ),
        ],
      );
    }
    return GestureDetector(
      onTap: () => _openImage(message),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            _photoImage(
              message,
              width: 220,
              height: 180,
              fit: BoxFit.cover,
            ),
            if (message.isViewOnce)
              Positioned(
                left: 6,
                top: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.background.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility_off_outlined,
                        size: 13,
                        color: AppTheme.onAccent,
                      ),
                      SizedBox(width: 4),
                      Text(
                        'View once',
                        style: TextStyle(
                          color: AppTheme.onAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinkPreview(
    LinkPreviewData preview,
    String url,
    bool isMine,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openUrl(url),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: (isMine ? AppTheme.onAccent : AppTheme.ink)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: (isMine ? AppTheme.onAccent : AppTheme.cardBorder)
                    .withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (preview.imageUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      preview.imageUrl!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (context, _, _) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                if (preview.imageUrl != null) const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (preview.title != null)
                        Text(
                          preview.title!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                            color: isMine ? AppTheme.onAccent : AppTheme.ink,
                          ),
                        ),
                      if (preview.description != null)
                        Text(
                          preview.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: isMine
                                ? AppTheme.onAccent.withValues(alpha: 0.8)
                                : AppTheme.inkSoft,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                color: AppTheme.inkSoft,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(child: Text(value)),
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
