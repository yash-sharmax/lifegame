/// Chat info (v2.11.0): members, per-chat settings, lock, danger zone.
///
/// Settings are MY per-chat row ([ChatSettings]) and persist through
/// [MessagingService.updateSettings]. The chat lock PIN lives
/// on-device only ([ChatPrefs]) — forgetting it clears the chat's
/// history, with no recovery (point 12).
library;

import 'package:flutter/material.dart';

import '../data/chat_prefs.dart';
import '../data/messaging_models.dart';
import '../data/messaging_service.dart';
import '../data/models.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'profile_screen.dart';
import 'saved_messages_screen.dart';

class ChatInfoScreen extends StatefulWidget {
  const ChatInfoScreen({
    super.key,
    required this.conversation,
    this.otherProfile,
  });

  final Conversation conversation;

  /// The other person in a DM, when already known (avoids a refetch).
  final Profile? otherProfile;

  @override
  State<ChatInfoScreen> createState() => _ChatInfoScreenState();
}

class _ChatInfoScreenState extends State<ChatInfoScreen> {
  final MessagingService _service = MessagingService();

  ChatSettings? _settings;
  List<Profile> _members = [];
  List<ConversationMember> _memberRows = [];
  Profile? _otherProfile;
  bool _loading = true;
  bool _saving = false;

  bool get _isGroup => widget.conversation.isGroup;

  @override
  void initState() {
    super.initState();
    _otherProfile = widget.otherProfile;
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _service.settingsFor(widget.conversation.id);
      final members = await _service.conversationMembers(
        widget.conversation.id,
      );
      final rows = await _service.memberRows(widget.conversation.id);
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _members = members;
        _memberRows = rows;
        _loading = false;
      });
      if (!_isGroup && _otherProfile == null) {
        final myId = AuthRepository.cachedUser?.uid;
        for (final m in members) {
          if (m.id != myId) {
            setState(() => _otherProfile = m);
            break;
          }
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _settings ??= ChatSettings.defaults(
          userId: AuthRepository.cachedUser?.uid ?? '',
          conversationId: widget.conversation.id,
        );
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _updateSettings(ChatSettings next) async {
    setState(() {
      _settings = next;
      _saving = true;
    });
    try {
      final saved = await _service.updateSettings(next);
      if (mounted) setState(() => _settings = saved);
    } catch (e) {
      _snack('Could not save that setting. $e');
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _hasLock() async {
    try {
      return (await ChatPrefs.instance()).hasLock(widget.conversation.id);
    } catch (_) {
      return false;
    }
  }

  Future<void> _setLock() async {
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Set lock PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter a PIN of 4 or more digits, then repeat it. '
                'If you forget it, the chat\'s history will be '
                'cleared to unlock it — there is no recovery.',
              ),
              const SizedBox(height: 12),
              TextField(
                controller: first,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: InputDecoration(
                  hintText: 'New PIN',
                  errorText: error,
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: second,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: 8,
                decoration: const InputDecoration(
                  hintText: 'Repeat PIN',
                  counterText: '',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (first.text.length < 4) {
                  setDialogState(
                    () => error = 'Use at least 4 digits.',
                  );
                  return;
                }
                if (first.text != second.text) {
                  setDialogState(() => error = 'PINs do not match.');
                  return;
                }
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Set lock'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      try {
        await (await ChatPrefs.instance()).setLock(
          widget.conversation.id,
          first.text,
        );
        _snack('Chat locked.');
        if (mounted) setState(() {});
      } catch (_) {}
    }
    first.dispose();
    second.dispose();
  }

  Future<void> _removeLock() async {
    final pin = TextEditingController();
    String? error;
    final removed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Remove lock'),
          content: TextField(
            controller: pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 8,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Current PIN',
              errorText: error,
              counterText: '',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final ok = (await ChatPrefs.instance()).verifyLock(
                  widget.conversation.id,
                  pin.text,
                );
                if (ok) {
                  if (ctx.mounted) Navigator.of(ctx).pop(true);
                } else {
                  setDialogState(() => error = 'Wrong PIN. Try again.');
                }
              },
              child: const Text('Remove lock'),
            ),
          ],
        ),
      ),
    );
    if (removed == true) {
      try {
        await (await ChatPrefs.instance()).removeLock(widget.conversation.id);
        _snack('Lock removed.');
        if (mounted) setState(() {});
      } catch (_) {}
    }
    pin.dispose();
  }

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'Every message in this chat will be deleted for you. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.clearConversationHistory(widget.conversation.id);
      _snack('History cleared.');
    } catch (e) {
      _snack('Could not clear history. $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final title = _isGroup
        ? (widget.conversation.title ?? 'Group chat')
        : (_otherProfile?.displayName ?? 'Chat');
    return Scaffold(
      appBar: AppBar(title: const Text('Chat info')),
      body: _loading
          ? const Center(child: LoadingIcon())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
              children: [
                Center(
                  child: Column(
                    children: [
                      AvatarCircle(
                        initials: _initialsFor(title),
                        size: 76,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (!_isGroup && _otherProfile != null)
                        Text(
                          '@${_otherProfile!.username}',
                          style: TextStyle(color: AppTheme.inkSoft),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                if (!_isGroup && _otherProfile != null)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('View profile'),
                      trailing: Icon(
                        Icons.chevron_right,
                        color: AppTheme.inkSoft,
                      ),
                      onTap: () => Navigator.of(context).push(
                        WarriorPageRoute(
                          builder: (_) =>
                              UserProfileScreen(profile: _otherProfile!),
                        ),
                      ),
                    ),
                  ),
                if (_isGroup) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
                    child: Text(
                      'MEMBERS (${_members.length})',
                      style: TextStyle(
                        color: AppTheme.inkSoft,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  for (final member in _members)
                    Card(
                      child: ListTile(
                        leading: AvatarCircle(
                          initials: member.initials,
                          size: 44,
                        ),
                        title: Text(
                          member.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text('@${member.username}'),
                        trailing: _isAdmin(member.id)
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.ember.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Text(
                                  'Admin',
                                  style: TextStyle(
                                    color: AppTheme.ember,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
                if (settings != null) ...[
                  _SettingsToggle(
                    icon: Icons.shield_outlined,
                    title: 'Secure Chat',
                    subtitle:
                        'Blocks screenshots while this chat is open (Android)',
                    value: settings.secureChat,
                    enabled: !_saving,
                    onChanged: (value) => _updateSettings(
                      settings.copyWith(secureChat: value),
                    ),
                  ),
                  _SettingsToggle(
                    icon: Icons.lock_outline,
                    title: 'Private Chat',
                    subtitle:
                        'Off = this session\'s history is deleted when you '
                        'leave, and nothing can be starred',
                    value: settings.privateChat,
                    enabled: !_saving,
                    onChanged: (value) => _updateSettings(
                      settings.copyWith(privateChat: value),
                    ),
                  ),
                  _SettingsToggle(
                    icon: Icons.verified_user_outlined,
                    title: 'Safe Mode',
                    subtitle:
                        'On = this chat\'s messages never auto-delete',
                    value: settings.safeMode,
                    enabled: !_saving,
                    onChanged: (value) =>
                        _updateSettings(settings.copyWith(safeMode: value)),
                  ),
                  _SettingsToggle(
                    icon: Icons.visibility_off_outlined,
                    title: 'Hide chat',
                    subtitle:
                        'Only your secret keyword in search reveals it',
                    value: settings.hidden,
                    enabled: !_saving,
                    onChanged: (value) =>
                        _updateSettings(settings.copyWith(hidden: value)),
                  ),
                ],
                const SizedBox(height: 12),
                FutureBuilder<bool>(
                  future: _hasLock(),
                  builder: (context, snapshot) {
                    final locked = snapshot.data ?? false;
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          locked ? Icons.lock : Icons.lock_open_outlined,
                        ),
                        title: Text(
                          locked ? 'Remove lock' : 'Set lock PIN',
                        ),
                        subtitle: const Text(
                          'Lock this chat with a PIN on this device',
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: AppTheme.inkSoft,
                        ),
                        onTap: locked ? _removeLock : _setLock,
                      ),
                    );
                  },
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.star_outline),
                    title: const Text('Saved messages'),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: AppTheme.inkSoft,
                    ),
                    onTap: () => Navigator.of(context).push(
                      WarriorPageRoute(
                        builder: (_) => const SavedMessagesScreen(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                  child: Text(
                    'DANGER ZONE',
                    style: TextStyle(
                      color: AppTheme.inkSoft,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.delete_forever_outlined,
                      color: AppTheme.flame,
                    ),
                    title: const Text('Clear history'),
                    subtitle: const Text(
                      'Delete every message in this chat',
                    ),
                    onTap: _clearHistory,
                  ),
                ),
              ],
            ),
    );
  }

  bool _isAdmin(String userId) {
    for (final row in _memberRows) {
      if (row.userId == userId) return row.role == 'admin';
    }
    return false;
  }
}

class _SettingsToggle extends StatelessWidget {
  const _SettingsToggle({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: SwitchListTile(
        secondary: Icon(icon),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text(subtitle),
        value: value,
        onChanged: enabled ? onChanged : null,
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
