import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';
import 'profile_screen.dart';

/// Search users by username / display name, follow & unfollow.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.profileRepo, this.socialRepo});

  final ProfileRepository? profileRepo;
  final SocialRepository? socialRepo;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  ProfileRepository get _profiles => widget.profileRepo ?? ProfileRepository();
  SocialRepository get _social => widget.socialRepo ?? SocialRepository();

  final _query = TextEditingController();
  List<Profile> _results = [];
  // v2.9.0: the follow status per result — 'none', 'pending'
  // (request sent to a private account) or 'accepted'.
  Map<String, String> _followStatus = {};
  bool _searching = false;
  bool _searched = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searching = true;
      _searched = true;
    });
    try {
      final me = await _profiles.fetchMyProfile();
      final results = await _profiles.searchProfiles(q);
      final statuses = <String, String>{};
      for (final p in results) {
        if (p.id != me?.id) {
          statuses[p.id] = await _social.followStatus(p.id);
        }
      }
      if (!mounted) return;
      setState(() {
        _results = results.where((p) => p.id != me?.id).toList();
        _followStatus = statuses;
        _searching = false;
      });
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _searching = false);
        showError(context, e);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _searching = false);
        showError(context, e);
      }
    }
  }

  Future<void> _toggleFollow(Profile profile) async {
    final status = _followStatus[profile.id] ?? 'none';
    try {
      if (status == 'none') {
        await _social.follow(profile.id);
        // Public accounts land on 'accepted', private ones stay
        // 'pending' — ask the server which it is.
        final fresh = await _social.followStatus(profile.id);
        if (!mounted) return;
        setState(() => _followStatus[profile.id] = fresh);
      } else {
        // 'accepted' = unfollow, 'pending' = cancel the request.
        await _social.unfollow(profile.id);
        if (!mounted) return;
        setState(() => _followStatus[profile.id] = 'none');
      }
    } on AuthException catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Push-only now (18 Nov 2026): Search opens from the search icon
    // in a screen header, so it needs its own Scaffold + AppBar with
    // a back button instead of the in-body title it had as a tab.
    return Scaffold(
      appBar: AppBar(title: const Text('Find people')),
      body: ResponsiveCenter(
        maxWidth: 980,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
          children: [
            Text(
              'Search by username or name, follow friends and compare ranks on the Friends board.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 14),
            ),
            const SizedBox(height: 16),
          TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              hintText: 'Search username or name…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.text.isEmpty
                  ? null
                  : IconButton(
                      onPressed: () {
                        _query.clear();
                        setState(() {
                          _results = [];
                          _searched = false;
                        });
                      },
                      icon: const Icon(Icons.clear),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          GradientButton(
            label: 'Search',
            icon: Icons.search,
            onPressed: _search,
            loading: _searching,
          ),
          const SizedBox(height: 20),
          if (!_searched)
            EmptyState(
              icon: Icons.person_search_outlined,
              title: 'Find your circle',
              subtitle: 'Search for friends, follow them, and race them on the Friends leaderboard.',
            )
          else if (_results.isEmpty && !_searching)
            EmptyState(
              icon: Icons.search_off_outlined,
              title: 'No people found',
              subtitle: 'Try a different username or name.',
            )
          else
            ..._results.asMap().entries.map((entry) {
              final profile = entry.value;
              final status = _followStatus[profile.id] ?? 'none';
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child:
                    _SearchRow(
                          profile: profile,
                          followStatus: status,
                          onToggleFollow: () => _toggleFollow(profile),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) =>
                                  UserProfileScreen(profile: profile),
                            ),
                          ),
                        )
                        .animate()
                        .fadeIn(delay: (40 * entry.key).ms)
                        .slideX(begin: 0.06),
              );
            }),
        ],
      ),
    ),
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.profile,
    required this.followStatus,
    required this.onToggleFollow,
    required this.onTap,
  });

  final Profile profile;

  /// 'none' | 'pending' | 'accepted'.
  final String followStatus;
  final VoidCallback onToggleFollow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(
            children: [
              AvatarCircle(initials: profile.initials, size: 48),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      profile.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '@${profile.username} • '
                      'Level ${levelForXp(profile.xp)} '
                      '${rankNameForLevel(levelForXp(profile.xp))} • '
                      '${profile.xp} XP • '
                      '${profile.currentStreak} day streak',
                      style: TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              FilledButton(
                onPressed: onToggleFollow,
                style: FilledButton.styleFrom(
                  backgroundColor: followStatus == 'none'
                      ? AppTheme.ember
                      : AppTheme.cardBorder,
                  // White text on the violet button, normal text on
                  // the grey one.
                  foregroundColor: followStatus == 'none'
                      ? AppTheme.onAccent
                      : AppTheme.ink,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(switch (followStatus) {
                  'accepted' => 'Following',
                  'pending' => 'Requested',
                  _ => 'Follow',
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
