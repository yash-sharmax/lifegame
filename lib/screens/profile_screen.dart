import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';

/// The user's own profile: stats, all habits, weekly + monthly tasks,
/// settings and logout.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.profileRepo,
    this.habitRepo,
    this.taskRepo,
    this.socialRepo,
    this.authRepo,
  });

  final ProfileRepository? profileRepo;
  final HabitRepository? habitRepo;
  final TaskRepository? taskRepo;
  final SocialRepository? socialRepo;
  final AuthRepository? authRepo;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ProfileRepository get _profiles =>
      widget.profileRepo ?? ProfileRepository();
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();
  TaskRepository get _tasks => widget.taskRepo ?? TaskRepository();
  SocialRepository get _social => widget.socialRepo ?? SocialRepository();
  AuthRepository get _auth => widget.authRepo ?? AuthRepository();

  Profile? _profile;
  List<Habit> _habitsList = [];
  List<WeeklyTask> _weekly = [];
  List<MonthlyTask> _monthly = [];
  int _rank = 0;
  int _followers = 0;
  int _following = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final profile = await _profiles.fetchMyProfile();
      final habits = await _habits.listMyHabits();
      final weekly = await _tasks.listWeeklyTasks(weekStartKey());
      final monthly = await _tasks.listMonthlyTasks(monthKey());
      var rank = 0;
      var followers = 0;
      var following = 0;
      if (profile != null) {
        rank = await _profiles.fetchGlobalRank();
        followers = await _social.followersCount(profile.id);
        following = await _social.followingCount(profile.id);
      }
      if (!mounted) return;
      setState(() {
        _profile = profile;
        _habitsList = habits;
        _weekly = weekly;
        _monthly = monthly;
        _rank = rank;
        _followers = followers;
        _following = following;
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

  Future<void> _editProfile() async {
    final profile = _profile;
    if (profile == null) return;
    final nameController = TextEditingController(text: profile.displayName);
    final bioController = TextEditingController(text: profile.bio);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: const Text('Edit profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: bioController,
              decoration: const InputDecoration(
                labelText: 'Bio',
                hintText: 'One line about you…',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      try {
        await _profiles.updateProfile(
          displayName: nameController.text.trim(),
          bio: bioController.text.trim(),
        );
        await _load();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  Future<void> _addTask({required bool weekly}) async {
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: Text(weekly ? 'Add weekly task' : 'Add monthly task'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Task'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (saved == true && controller.text.trim().isNotEmpty) {
      try {
        if (weekly) {
          await _tasks.addWeeklyTask(
            controller.text.trim(),
            weekStartKey(),
          );
        } else {
          await _tasks.addMonthlyTask(controller.text.trim(), monthKey());
        }
        await _load();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  Future<void> _editHabit(Habit habit) async {
    final controller = TextEditingController(text: habit.title);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        title: const Text('Edit habit'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Habit name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('delete'),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == 'save' && controller.text.trim().isNotEmpty) {
      try {
        await _habits.updateHabit(habit, title: controller.text.trim());
        await _load();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    } else if (result == 'delete') {
      try {
        await _habits.archiveHabit(habit.id);
        await _load();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  Future<void> _signOut() async {
    try {
      await _auth.signOut();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
        children: [
          Row(
            children: [
              const Text(
                'Profile',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
              ),
              const Spacer(),
              IconButton(
                onPressed: _editProfile,
                tooltip: 'Edit profile',
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ).animate().fadeIn().slideY(begin: -0.1),
          const SizedBox(height: 8),
          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: CircularProgressIndicator(),
              ),
            )
          else if (profile == null)
            const EmptyState(
              icon: Icons.person_off_outlined,
              title: 'No profile yet',
              subtitle: 'Sign in again to set up your profile.',
            )
          else ...[
            _ProfileHeader(
              profile: profile,
              rank: _rank,
              followers: _followers,
              following: _following,
            ).animate().fadeIn(delay: 60.ms).slideY(begin: 0.1),
            const SizedBox(height: 16),
            XpBar(xp: profile.xp)
                .animate()
                .fadeIn(delay: 120.ms)
                .slideY(begin: 0.1),
            const SizedBox(height: 24),
            _SectionTitle(
              title: 'My habits',
              count: _habitsList.length,
              onAdd: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const _AddHabitHint(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (_habitsList.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                    'No habits yet — add your first one from the Home tab.',
                    style: TextStyle(color: AppTheme.inkSoft),
                  ),
                ),
              )
            else
              ..._habitsList.map(
                (habit) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _HabitRow(
                    habit: habit,
                    onTap: () => _editHabit(habit),
                  ),
                ),
              ),
            const SizedBox(height: 24),
            _TaskSection(
              title: 'Weekly tasks',
              subtitle: 'This week',
              items: _weekly
                  .map((t) => _TaskItem(id: t.id, title: t.title, done: t.done))
                  .toList(),
              onToggle: (id, done) async {
                await _tasks.toggleWeeklyTask(id, done);
                await _load();
              },
              onDelete: (id) async {
                await _tasks.deleteWeeklyTask(id);
                await _load();
              },
              onAdd: () => _addTask(weekly: true),
            ),
            const SizedBox(height: 24),
            _TaskSection(
              title: 'Monthly tasks',
              subtitle: 'This month',
              items: _monthly
                  .map((t) => _TaskItem(id: t.id, title: t.title, done: t.done))
                  .toList(),
              onToggle: (id, done) async {
                await _tasks.toggleMonthlyTask(id, done);
                await _load();
              },
              onDelete: (id) async {
                await _tasks.deleteMonthlyTask(id);
                await _load();
              },
              onAdd: () => _addTask(weekly: false),
            ),
            const SizedBox(height: 24),
            const Text(
              'Settings',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('About Life Game'),
                    subtitle: const Text('Version 2.0 • Flutter • Supabase'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.logout, color: Colors.red),
                    title: const Text(
                      'Log out',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: _signOut,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({
    required this.profile,
    required this.rank,
    required this.followers,
    required this.following,
  });

  final Profile profile;
  final int rank;
  final int followers;
  final int following;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            AvatarCircle(initials: profile.initials, size: 84),
            const SizedBox(height: 12),
            Text(
              profile.displayName,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            Text(
              '@${profile.username}',
              style: const TextStyle(
                color: AppTheme.violet,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (profile.bio.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                profile.bio,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.inkSoft),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _MiniStat(value: '#$rank', label: 'Global rank'),
                _MiniStat(value: '$followers', label: 'Followers'),
                _MiniStat(value: '$following', label: 'Following'),
                _MiniStat(
                  value: '${profile.longestStreak}d',
                  label: 'Best streak',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(
          label,
          style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.count,
    this.onAdd,
  });

  final String title;
  final int count;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: AppTheme.violet.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$count',
            style: const TextStyle(
              color: AppTheme.violet,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
        const Spacer(),
        if (onAdd != null)
          IconButton(
            onPressed: onAdd,
            icon: const Icon(Icons.add_circle_outline),
            tooltip: 'Add habit (from Home)',
          ),
      ],
    );
  }
}

class _HabitRow extends StatelessWidget {
  const _HabitRow({required this.habit, required this.onTap});

  final Habit habit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final gradient =
        AppTheme.habitGradients[habit.color % AppTheme.habitGradients.length];
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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.check_circle_outline,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  habit.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const Icon(Icons.chevron_right, color: AppTheme.inkSoft),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskItem {
  const _TaskItem({required this.id, required this.title, required this.done});

  final String id;
  final String title;
  final bool done;
}

class _TaskSection extends StatelessWidget {
  const _TaskSection({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.onToggle,
    required this.onDelete,
    required this.onAdd,
  });

  final String title;
  final String subtitle;
  final List<_TaskItem> items;
  final Future<void> Function(String id, bool done) onToggle;
  final Future<void> Function(String id) onDelete;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(width: 8),
            Text(
              subtitle,
              style: const TextStyle(color: AppTheme.inkSoft, fontSize: 13),
            ),
            const Spacer(),
            IconButton(
              onPressed: onAdd,
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Add task',
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (items.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'Nothing here yet — add a task to plan your week or month.',
                style: TextStyle(color: AppTheme.inkSoft),
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  CheckboxListTile(
                    value: items[i].done,
                    onChanged: (v) => onToggle(items[i].id, v ?? false),
                    title: Text(
                      items[i].title,
                      style: TextStyle(
                        decoration: items[i].done
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    secondary: IconButton(
                      onPressed: () => onDelete(items[i].id),
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  if (i < items.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Tiny helper screen used by the "add habit" affordance on Profile:
/// habits are added from Home, so this guides the user there.
class _AddHabitHint extends StatelessWidget {
  const _AddHabitHint();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add habit')),
      body: const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Add habits from the Home tab — tap the "Add habit" button under '
          "today's list.",
          style: TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}

/// Public profile view — what anyone sees when they tap a user on the
/// leaderboard or in search. Habits are private (owner-only), so this
/// shows the public profile: identity, bio and stats.
class UserProfileScreen extends StatelessWidget {
  const UserProfileScreen({
    super.key,
    required this.profile,
    this.socialRepo,
    this.myId,
  });

  final Profile profile;
  final SocialRepository? socialRepo;
  final String? myId;

  @override
  Widget build(BuildContext context) {
    final isMe = myId != null && myId == profile.id;
    return Scaffold(
      appBar: AppBar(title: Text('@${profile.username}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const SizedBox(height: 8),
          Center(
            child: AvatarCircle(initials: profile.initials, size: 96),
          ),
          const SizedBox(height: 14),
          Text(
            profile.displayName,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          Text(
            '@${profile.username}',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.violet,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (profile.bio.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              profile.bio,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.inkSoft),
            ),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  label: 'XP',
                  value: '${profile.xp}',
                  gradient: AppTheme.violetGradient,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatBox(
                  label: 'Streak',
                  value: '${profile.currentStreak} days',
                  gradient: AppTheme.amberGradient,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatBox(
                  label: 'Best streak',
                  value: '${profile.longestStreak} days',
                  gradient: AppTheme.pinkGradient,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Level ${profile.xp ~/ 100 + 1}',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  XpBar(xp: profile.xp),
                ],
              ),
            ),
          ),
          if (!isMe) ...[
            const SizedBox(height: 16),
            _FollowButton(
              profile: profile,
              socialRepo: socialRepo ?? SocialRepository(),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({
    required this.label,
    required this.value,
    required this.gradient,
  });

  final String label;
  final String value;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 17,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _FollowButton extends StatefulWidget {
  const _FollowButton({required this.profile, required this.socialRepo});

  final Profile profile;
  final SocialRepository socialRepo;

  @override
  State<_FollowButton> createState() => _FollowButtonState();
}

class _FollowButtonState extends State<_FollowButton> {
  bool? _following;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final following = await widget.socialRepo.isFollowing(widget.profile.id);
      if (mounted) setState(() => _following = following);
    } catch (_) {
      if (mounted) setState(() => _following = false);
    }
  }

  Future<void> _toggle() async {
    final following = _following ?? false;
    try {
      if (following) {
        await widget.socialRepo.unfollow(widget.profile.id);
      } else {
        await widget.socialRepo.follow(widget.profile.id);
      }
      if (mounted) setState(() => _following = !following);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final following = _following ?? false;
    return GradientButton(
      label: following ? 'Following' : 'Follow @${widget.profile.username}',
      icon: following ? Icons.check : Icons.person_add_outlined,
      onPressed: _toggle,
      gradient: following
          ? const LinearGradient(
              colors: [Color(0xFF9CA3AF), Color(0xFF6B7280)],
            )
          : AppTheme.heroGradient,
    );
  }
}
