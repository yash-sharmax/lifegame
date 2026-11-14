import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/models.dart';
import '../data/repositories.dart';
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
  ProfileRepository get _profiles =>
      widget.profileRepo ?? ProfileRepository();
  SocialRepository get _social => widget.socialRepo ?? SocialRepository();

  final _query = TextEditingController();
  List<Profile> _results = [];
  Map<String, bool> _following = {};
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
      final following = <String, bool>{};
      for (final p in results) {
        if (p.id != me?.id) {
          following[p.id] = await _social.isFollowing(p.id);
        }
      }
      if (!mounted) return;
      setState(() {
        _results = results.where((p) => p.id != me?.id).toList();
        _following = following;
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
    final currently = _following[profile.id] ?? false;
    try {
      if (currently) {
        await _social.unfollow(profile.id);
      } else {
        await _social.follow(profile.id);
      }
      if (!mounted) return;
      setState(() => _following[profile.id] = !currently);
    } on AuthException catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
      children: [
        const Text(
          'Find players',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
        ).animate().fadeIn().slideY(begin: -0.1),
        const SizedBox(height: 6),
        const Text(
          'Search by username or name, follow friends and compare streaks on the Friends board.',
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
            subtitle:
                'Search for friends, follow them, and race them on the Friends leaderboard.',
          )
        else if (_results.isEmpty && !_searching)
          EmptyState(
            icon: Icons.search_off_outlined,
            title: 'No players found',
            subtitle: 'Try a different username or name.',
          )
        else
          ..._results.asMap().entries.map((entry) {
            final profile = entry.value;
            final following = _following[profile.id] ?? false;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _SearchRow(
                profile: profile,
                following: following,
                onToggleFollow: () => _toggleFollow(profile),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => UserProfileScreen(profile: profile),
                  ),
                ),
              ).animate().fadeIn(delay: (40 * entry.key).ms).slideX(begin: 0.06),
            );
          }),
      ],
    );
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.profile,
    required this.following,
    required this.onToggleFollow,
    required this.onTap,
  });

  final Profile profile;
  final bool following;
  final VoidCallback onToggleFollow;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFEDEAF5)),
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
                      '@${profile.username} • ${profile.xp} XP • '
                      '${profile.currentStreak} day streak',
                      style: const TextStyle(
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
                  backgroundColor: following
                      ? const Color(0xFFEDEAF5)
                      : AppTheme.violet,
                  foregroundColor: following ? AppTheme.ink : Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(following ? 'Following' : 'Follow'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
