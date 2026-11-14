import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';
import 'profile_screen.dart';

/// Leaderboard with two tabs: Global (everyone by XP) and Friends
/// (people you follow + you, by XP).
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key, this.profileRepo});

  final ProfileRepository? profileRepo;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  ProfileRepository get _profiles =>
      widget.profileRepo ?? ProfileRepository();

  late final TabController _tabs;
  List<LeaderboardEntry> _global = [];
  List<LeaderboardEntry> _friends = [];
  bool _loading = true;
  String _myId = '';

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final me = await _profiles.fetchMyProfile();
      final global = await _profiles.fetchGlobalLeaderboard();
      final friends = await _profiles.fetchFriendsLeaderboard();
      if (!mounted) return;
      setState(() {
        _global = global;
        _friends = friends;
        _myId = me?.id ?? '';
        _loading = false;
      });
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Row(
            children: [
              const Text(
                'Leaderboard',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              IconButton(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh',
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: TabBar(
              controller: _tabs,
              dividerColor: Colors.transparent,
              indicator: BoxDecoration(
                gradient: AppTheme.violetGradient,
                borderRadius: BorderRadius.circular(12),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              labelColor: Colors.white,
              unselectedLabelColor: AppTheme.inkSoft,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700),
              tabs: const [
                Tab(text: 'Global'),
                Tab(text: 'Friends'),
              ],
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _BoardList(entries: _global, myId: _myId),
                    _BoardList(
                      entries: _friends,
                      myId: _myId,
                      emptyTitle: 'No friends on the board yet',
                      emptySubtitle:
                          'Follow people from Search and they will show up here.',
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _BoardList extends StatelessWidget {
  const _BoardList({
    required this.entries,
    required this.myId,
    this.emptyTitle = 'Nobody here yet',
    this.emptySubtitle = 'Be the first to earn XP and top this board.',
  });

  final List<LeaderboardEntry> entries;
  final String myId;
  final String emptyTitle;
  final String emptySubtitle;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return EmptyState(
        icon: Icons.leaderboard_outlined,
        title: emptyTitle,
        subtitle: emptySubtitle,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final profile = entry.profile;
        final isMe = profile.id == myId;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _LeaderboardRow(
            entry: entry,
            isMe: isMe,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserProfileScreen(profile: profile),
              ),
            ),
          ).animate().fadeIn(delay: (40 * index).ms).slideX(begin: 0.06),
        );
      },
    );
  }
}

class _LeaderboardRow extends StatelessWidget {
  const _LeaderboardRow({
    required this.entry,
    required this.isMe,
    required this.onTap,
  });

  final LeaderboardEntry entry;
  final bool isMe;
  final VoidCallback onTap;

  Color get _rankColor => switch (entry.rank) {
    1 => const Color(0xFFF59E0B),
    2 => const Color(0xFF9CA3AF),
    3 => const Color(0xFFB45309),
    _ => AppTheme.inkSoft,
  };

  @override
  Widget build(BuildContext context) {
    final profile = entry.profile;
    return Material(
      color: isMe
          ? AppTheme.violet.withValues(alpha: 0.08)
          : Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isMe
                  ? AppTheme.violet.withValues(alpha: 0.4)
                  : const Color(0xFFEDEAF5),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: entry.rank <= 3
                    ? Icon(
                        Icons.emoji_events,
                        color: _rankColor,
                        size: 26,
                      )
                    : Text(
                        '#${entry.rank}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: AppTheme.inkSoft,
                        ),
                      ),
              ),
              AvatarCircle(initials: profile.initials, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isMe
                          ? '${profile.displayName} (you)'
                          : profile.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '@${profile.username}',
                      style: const TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${profile.xp} XP',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.local_fire_department,
                        color: Colors.deepOrange,
                        size: 15,
                      ),
                      Text(
                        ' ${profile.currentStreak}',
                        style: const TextStyle(
                          color: AppTheme.inkSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
