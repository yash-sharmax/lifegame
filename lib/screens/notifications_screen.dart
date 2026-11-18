// Notifications screen (v2.9.0, 18 Nov 2026).
//
// Two sections, both derived from the existing `follows` table (no
// new notifications table):
// - Pending follow requests (a follow on a PRIVATE account): Accept /
//   Decline buttons. Accept → the follow becomes 'accepted';
//   Decline → the row is deleted.
// - Recent followers: "X started following you" (accepted follows on
//   me, newest first).
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  final _social = SocialRepository();
  List<(String, Profile)> _requests = [];
  List<Profile> _followers = [];
  bool _loading = true;
  String? _error;
  final Set<String> _acting = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final requests = await _social.pendingFollowRequests();
      final followers = await _social.recentFollowers();
      if (!mounted) return;
      setState(() {
        _requests = requests;
        _followers = followers;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // A network failure is a small line, never a big error popup.
        _error = isNetworkError(e)
            ? "You're offline — notifications will load when you're back online."
            : 'Could not load notifications. Pull to retry.';
      });
    }
  }

  Future<void> _accept(String docId) async {
    setState(() => _acting.add(docId));
    try {
      await _social.acceptFollowRequest(docId);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _acting.remove(docId));
    }
  }

  Future<void> _decline(String docId) async {
    setState(() => _acting.add(docId));
    try {
      await _social.declineFollowRequest(docId);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _acting.remove(docId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null && _requests.isEmpty && _followers.isEmpty
            ? _EmptyState(message: _error!)
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: AppTheme.inkSoft,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (_requests.isNotEmpty) ...[
                    _SectionTitle('Follow requests'),
                    const SizedBox(height: 8),
                    for (final (docId, profile) in _requests)
                      _RequestCard(
                        profile: profile,
                        busy: _acting.contains(docId),
                        onAccept: () => _accept(docId),
                        onDecline: () => _decline(docId),
                      ),
                    const SizedBox(height: 20),
                  ],
                  if (_followers.isNotEmpty) ...[
                    _SectionTitle('Recent followers'),
                    const SizedBox(height: 8),
                    for (final profile in _followers)
                      _FollowerRow(profile: profile),
                  ],
                  if (_requests.isEmpty && _followers.isEmpty)
                    const _EmptyState(
                      message: 'No notifications yet. When someone follows '
                          'you, or sends a follow request, it will show '
                          'up here.',
                    ),
                ],
              ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(
        children: [
          Icon(
            Icons.notifications_none,
            size: 48,
            color: AppTheme.inkSoft,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.inkSoft, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.profile,
    required this.busy,
    required this.onAccept,
    required this.onDecline,
  });

  final Profile profile;
  final bool busy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AvatarCircle(
                initials: profile.initials,
                size: 44,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      '@${profile.username} wants to follow you',
                      style: TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onAccept,
                  child: const Text('Accept'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : onDecline,
                  child: const Text('Decline'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FollowerRow extends StatelessWidget {
  const _FollowerRow({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          AvatarCircle(initials: profile.initials, size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${profile.displayName} started following you',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
