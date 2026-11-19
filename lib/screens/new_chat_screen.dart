/// New chat (v2.11.0): start a DM with someone I follow, or create
/// a group chat.
///
/// A one-sided follow starts as a REQUEST the other side must accept
/// (point 1); mutual friends chat directly. Starting a DM requires
/// that I follow the other person — the service throws
/// [CannotMessageException] otherwise, and its message is shown.
library;

import 'package:flutter/material.dart';

import '../data/messaging_service.dart';
import '../data/models.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final MessagingService _service = MessagingService();
  final SocialRepository _social = SocialRepository();
  final _groupNameController = TextEditingController();

  List<Profile> _following = [];
  bool _loading = true;
  bool _notSetUp = false;
  bool _creatingGroup = false;
  bool _creating = false;
  final Set<String> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profiles = await _social.followProfiles(followers: false);
      if (!mounted) return;
      setState(() {
        _following = profiles;
        _loading = false;
      });
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

  Future<void> _startDm(Profile profile) async {
    try {
      final conversation = await _service.startDm(profile.id);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        WarriorPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
      );
    } on CannotMessageException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not start the chat. $e');
    }
  }

  Future<void> _createGroup() async {
    if (_selectedIds.isEmpty) {
      _snack('Pick at least one person for the group.');
      return;
    }
    setState(() => _creating = true);
    try {
      final conversation = await _service.createGroup(
        title: _groupNameController.text,
        memberIds: _selectedIds.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        WarriorPageRoute(builder: (_) => ChatScreen(conversation: conversation)),
      );
    } on CannotMessageException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not create the group. $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_creatingGroup ? 'New group' : 'New chat'),
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
                  subtitle: 'Messaging is not ready yet — check back soon.',
                ),
              ),
            )
          : _creatingGroup
          ? _buildGroupCreator()
          : _buildPeopleList(),
    );
  }

  Widget _buildPeopleList() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        Card(
          child: ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                gradient: AppTheme.emberGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.group_add, color: AppTheme.onAccent),
            ),
            title: const Text(
              'New group',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Chat with several people at once'),
            trailing: Icon(Icons.chevron_right, color: AppTheme.inkSoft),
            onTap: () => setState(() => _creatingGroup = true),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Text(
            'PEOPLE YOU FOLLOW',
            style: TextStyle(
              color: AppTheme.inkSoft,
              fontWeight: FontWeight.w800,
              fontSize: 13,
              letterSpacing: 0.8,
            ),
          ),
        ),
        if (_following.isEmpty)
          const EmptyState(
            icon: Icons.person_add_outlined,
            title: 'No one to message yet',
            subtitle:
                'Follow people from Search or the leaderboard, then '
                'message them here.',
          )
        else
          for (final person in _following)
            _PersonRow(
              person: person,
              onTap: () => _startDm(person),
            ),
      ],
    );
  }

  Widget _buildGroupCreator() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _groupNameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              hintText: 'Group name',
              prefixIcon: Icon(Icons.group_outlined),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'ADD PEOPLE YOU FOLLOW',
              style: TextStyle(
                color: AppTheme.inkSoft,
                fontWeight: FontWeight.w800,
                fontSize: 13,
                letterSpacing: 0.8,
              ),
            ),
          ),
        ),
        Expanded(
          child: _following.isEmpty
              ? const EmptyState(
                  icon: Icons.person_add_outlined,
                  title: 'No one to add yet',
                  subtitle:
                      'Follow people from Search or the leaderboard first.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: _following.length,
                  itemBuilder: (context, index) {
                    final person = _following[index];
                    final selected = _selectedIds.contains(person.id);
                    return Card(
                      child: CheckboxListTile(
                        value: selected,
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _selectedIds.add(person.id);
                          } else {
                            _selectedIds.remove(person.id);
                          }
                        }),
                        secondary: AvatarCircle(
                          initials: person.initials,
                          size: 44,
                        ),
                        title: Text(
                          person.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        subtitle: Text('@${person.username}'),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: GradientButton(
            label: _creating
                ? 'Creating…'
                : 'Create group (${_selectedIds.length})',
            loading: _creating,
            onPressed: _creating ? null : _createGroup,
          ),
        ),
      ],
    );
  }
}

class _PersonRow extends StatefulWidget {
  const _PersonRow({required this.person, required this.onTap});

  final Profile person;
  final VoidCallback onTap;

  @override
  State<_PersonRow> createState() => _PersonRowState();
}

class _PersonRowState extends State<_PersonRow> {
  bool? _mutual;

  @override
  void initState() {
    super.initState();
    _checkMutual();
  }

  Future<void> _checkMutual() async {
    try {
      final mutual = await SocialRepository().isMutual(widget.person.id);
      if (mounted) setState(() => _mutual = mutual);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final person = widget.person;
    final mutual = _mutual;
    return Card(
      child: ListTile(
        leading: AvatarCircle(initials: person.initials, size: 48),
        title: Text(
          person.displayName,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        subtitle: Text('@${person.username}'),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppTheme.ember.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            mutual == null ? '…' : (mutual ? 'Chat' : 'Request'),
            style: const TextStyle(
              color: AppTheme.ember,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
        ),
        onTap: widget.onTap,
      ),
    );
  }
}
