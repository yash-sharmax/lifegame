import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';
import 'profile_screen.dart';

/// Leaderboard with two tabs: Global (everyone by XP) and Friends
/// (people you follow + you, by XP).
///
/// Redesign (18 Nov 2026): the layout type of the reference the user
/// shared — a header, a week strip (current week + days left) with
/// the user's own rank line beside it, and clean ranked rows (rank
/// number, avatar with a level badge, name, XP on the right) —
///
/// adapted to Life Game's own clean professional navy/violet
/// identity, NOT a clone of the other app: no "Live" badge (the user
/// asked what it would even mean here), no league system, ranking
/// still by XP, and hidden accounts (discoverable == false) still
/// never appear (see ProfileRepository.fetchGlobalLeaderboard).
class LeaderboardScreen extends StatefulWidget {
  const LeaderboardScreen({super.key, this.profileRepo});

  final ProfileRepository? profileRepo;

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen>
    with SingleTickerProviderStateMixin {
  ProfileRepository get _profiles => widget.profileRepo ?? ProfileRepository();

  late final TabController _tabs;
  List<LeaderboardEntry> _global = [];
  List<LeaderboardEntry> _friends = [];
  bool _loading = true;
  Profile? _me;

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
        _me = me;
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
    // Push-only now (18 Nov 2026): the leaderboard opens from the XP
    // pill on Home, so it needs its own Scaffold + AppBar with a back
    // button instead of the in-body title it had as a bottom tab.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Leaderboard'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: ResponsiveCenter(
        maxWidth: 980,
        child: Column(
          children: [
            // Week strip + my rank line (18 Nov 2026 redesign).
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _loading
                  ? const SkeletonBox(height: 64, borderRadius: 16)
                  : _WeekStrip(me: _me),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Container(
                decoration: BoxDecoration(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: TabBar(
                  controller: _tabs,
                  dividerColor: Colors.transparent,
                  indicator: BoxDecoration(
                    gradient: AppTheme.emberGradient,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  labelColor: AppTheme.onAccent,
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
                  ? ListView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
                      children: const [
                        SkeletonBox(height: 70, borderRadius: 18),
                        SizedBox(height: 10),
                        SkeletonBox(height: 70, borderRadius: 18),
                        SizedBox(height: 10),
                        SkeletonBox(height: 70, borderRadius: 18),
                        SizedBox(height: 10),
                        SkeletonBox(height: 70, borderRadius: 18),
                      ],
                    )
                  : TabBarView(
                      controller: _tabs,
                      children: [
                        _BoardList(entries: _global, myId: _me?.id ?? ''),
                        _BoardList(
                          entries: _friends,
                          myId: _me?.id ?? '',
                          emptyTitle: 'No friends on the board yet',
                          emptySubtitle: 'Follow people from Search and they will show up here.',
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The week strip under the header: on the left the current week
/// (Monday–Sunday) with the days left in it; on the right the
/// viewer's own rank and how much XP the next rank needs — or, at
/// Legend, that it is the top rank.
class _WeekStrip extends StatelessWidget {
  const _WeekStrip({required this.me});

  final Profile? me;

  @override
  Widget build(BuildContext context) {
    final daysLeft = daysLeftInWeek();
    final endsText = daysLeft == 0
        ? 'Ends today'
        : 'Ends in $daysLeft ${daysLeft == 1 ? 'day' : 'days'}';
    final xp = me?.xp ?? 0;
    final rank = rankNameForXp(xp);
    final nextRank = nextRankNameForXp(xp);
    final toNext = xpToNextRank(xp);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  weekRangeLabel(),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  endsText,
                  style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.shield, color: AppTheme.ember, size: 15),
                  const SizedBox(width: 5),
                  Text(
                    rank,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                nextRank == null
                    ? 'Legend — top rank'
                    : '$toNext XP more for $nextRank',
                style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
              ),
            ],
          ),
        ],
      ),
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
              WarriorPageRoute(
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
    final level = levelForXp(profile.xp);
    final rank = rankNameForLevel(level);
    return Material(
      color: isMe ? AppTheme.ember.withValues(alpha: 0.08) : AppTheme.card,
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
                  ? AppTheme.ember.withValues(alpha: 0.4)
                  : AppTheme.cardBorder,
            ),
          ),
          child: Row(
            children: [
              // Rank number on the far left (top 3 tinted gold /
              // silver / bronze, the rest muted).
              SizedBox(
                width: 30,
                child: Text(
                  '${entry.rank}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _rankColor,
                  ),
                ),
              ),
              // Avatar with a small level badge, like the reference's
              // avatar badge — the level is visible right on the row.
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AvatarCircle(initials: profile.initials, size: 46),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 20,
                      height: 20,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppTheme.ember,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: AppTheme.card,
                          width: 2,
                        ),
                      ),
                      child: Text(
                        '$level',
                        style: TextStyle(
                          // White on the violet badge.
                          color: AppTheme.onAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
                    const SizedBox(height: 3),
                    Text(
                      '@${profile.username} • $rank',
                      style: TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '${profile.xp} XP',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
