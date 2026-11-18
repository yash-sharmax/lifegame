import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/habit_dialog.dart';
import 'auth_screen.dart';
import 'search_screen.dart';

/// Email shown for support — the developer's own address. It is copied
/// to the clipboard on tap (no extra dependency needed for a mail link).
const String _supportEmail = 'yashsharmaup2008@gmail.com';

/// The user's own profile, redesigned 18 Nov 2026: a horizontal
/// identity card, the level card, a stats strip, and three tabs —
/// Habits | Weekly | Monthly — switching the list below. The old
/// stacked layout (avatar on top, then stats, then every list at
/// once) is gone; the tabs are the new structure.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    this.profileRepo,
    this.habitRepo,
    this.taskRepo,
    this.socialRepo,
    this.authRepo,
    this.feedbackRepo,
  });

  final ProfileRepository? profileRepo;
  final HabitRepository? habitRepo;
  final TaskRepository? taskRepo;
  final SocialRepository? socialRepo;
  final AuthRepository? authRepo;
  final FeedbackRepository? feedbackRepo;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  ProfileRepository get _profiles => widget.profileRepo ?? ProfileRepository();
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();
  TaskRepository get _tasks => widget.taskRepo ?? TaskRepository();
  SocialRepository get _social => widget.socialRepo ?? SocialRepository();
  AuthRepository get _auth => widget.authRepo ?? AuthRepository();
  FeedbackRepository get _feedback =>
      widget.feedbackRepo ?? FeedbackRepository();

  Profile? _profile;
  List<Habit> _habitsList = [];
  List<WeeklyTask> _weekly = [];
  List<MonthlyTask> _monthly = [];
  int _rank = 0;
  int _followers = 0;
  int _following = 0;
  bool _loading = true;
  bool _deletingAccount = false;
  // Active tab: 0 = Habits, 1 = Weekly, 2 = Monthly.
  int _tab = 0;
  // Task toggles currently syncing. While one is in flight, a reload
  // (triggered by the repository's onChanged notification) must NOT
  // overwrite the locally-correct task list / XP with server data
  // that predates the in-flight toggle (same rapid double-tap flicker
  // as Home — see _pendingToggles there).
  int _pendingTaskToggles = 0;
  StreamSubscription<void>? _habitChanges;
  StreamSubscription<void>? _taskChanges;

  @override
  void initState() {
    super.initState();
    // This screen loads once (IndexedStack keeps it alive), so a habit
    // added on Home — or a task toggled here — would never appear until
    // the app restarts. Reload whenever habits or tasks change.
    _habitChanges = HabitRepository.onChanged.listen((_) {
      if (mounted) _load();
    });
    _taskChanges = TaskRepository.onChanged.listen((_) {
      if (mounted && _pendingTaskToggles == 0) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _habitChanges?.cancel();
    _taskChanges?.cancel();
    super.dispose();
  }

  Future<void> _load({bool forceApply = false}) async {
    // Only show the spinner on the first load: later refreshes update
    // silently instead of flashing a loader over the profile.
    final firstLoad = _profile == null;
    if (firstLoad) setState(() => _loading = true);
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
      // The habit list, rank and follow counts are never changed by a
      // task toggle, so they always apply. The task lists and the
      // profile (XP) are applied only when no task toggle is in
      // flight — a reload landing mid-toggle would paint server data
      // predating the local flip back over the user's tap.
      final applyTasks = forceApply || _pendingTaskToggles == 0;
      setState(() {
        if (applyTasks) {
          _profile = profile;
          _weekly = weekly;
          _monthly = monthly;
        }
        _habitsList = habits;
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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

  /// Adds a habit straight from the Habits tab (18 Nov 2026): the
  /// same creation dialog Home uses — no more "go to Home to add"
  /// hint screen.
  Future<void> _addHabit() async {
    final result = await showAddHabitDialog(context);
    if (result == null || !mounted) return;
    try {
      await _habits.addHabit(title: result.title, color: result.color);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addTask({required bool weekly}) async {
    final controller = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
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
          await _tasks.addWeeklyTask(controller.text.trim(), weekStartKey());
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
    final result = await showHabitEditDialog(context, habit);
    if (result == null || !mounted) return;
    try {
      if (result.action == HabitEditAction.save && result.title.isNotEmpty) {
        await _habits.updateHabit(
          habit,
          title: result.title,
          notes: result.notes,
        );
        await _load();
      } else if (result.action == HabitEditAction.delete) {
        // Deleting removes the habit's logs and takes back the XP its
        // completions contributed (see HabitRepository).
        await _habits.deleteHabit(habit.id);
        if (mounted) showInfo(context, 'Habit deleted.');
        await _load();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _signOut() async {
    try {
      await _auth.signOut();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// Tapping a task's checkbox flips it instantly — and the XP paints
  /// instantly too (same optimistic pattern as Home's habit toggle).
  /// The write syncs in the background; a failed write rolls the
  /// checkbox and the XP back to the server state. Rapid taps are
  /// allowed (no guard): each tap flips the local state and queues
  /// its own server write, and the queue runs them in order.
  Future<void> _toggleWeekly(String id, bool done) async {
    final prev = _weekly;
    final prevProfile = _profile;
    var wasDone = false;
    for (final t in prev) {
      if (t.id == id) {
        wasDone = t.done;
        break;
      }
    }
    final delta = xpDeltaForToggle(completing: done, wasDone: wasDone);
    setState(() {
      _weekly = _weekly
          .map(
            (t) => t.id == id
                ? WeeklyTask(
                    id: t.id,
                    userId: t.userId,
                    title: t.title,
                    weekStart: t.weekStart,
                    done: done,
                  )
                : t,
          )
          .toList();
      final profile = _profile;
      if (profile != null && delta != 0) {
        _profile = profile.copyWith(
          xp: (profile.xp + delta).clamp(0, 100000000),
        );
      }
    });
    _pendingTaskToggles++;
    try {
      await _tasks.toggleWeeklyTask(id, done);
      // No reload: the local state is already correct, and a reload
      // here would fetch server data that may predate a second tap.
    } catch (e) {
      if (mounted) {
        setState(() {
          _weekly = prev;
          _profile = prevProfile;
        });
        showError(context, e);
        try {
          await _load(forceApply: true);
        } catch (_) {}
      }
    } finally {
      _pendingTaskToggles--;
    }
  }

  Future<void> _toggleMonthly(String id, bool done) async {
    final prev = _monthly;
    final prevProfile = _profile;
    var wasDone = false;
    for (final t in prev) {
      if (t.id == id) {
        wasDone = t.done;
        break;
      }
    }
    final delta = xpDeltaForToggle(completing: done, wasDone: wasDone);
    setState(() {
      _monthly = _monthly
          .map(
            (t) => t.id == id
                ? MonthlyTask(
                    id: t.id,
                    userId: t.userId,
                    title: t.title,
                    month: t.month,
                    done: done,
                  )
                : t,
          )
          .toList();
      final profile = _profile;
      if (profile != null && delta != 0) {
        _profile = profile.copyWith(
          xp: (profile.xp + delta).clamp(0, 100000000),
        );
      }
    });
    _pendingTaskToggles++;
    try {
      await _tasks.toggleMonthlyTask(id, done);
      // No reload: the local state is already correct (see above).
    } catch (e) {
      if (mounted) {
        setState(() {
          _monthly = prev;
          _profile = prevProfile;
        });
        showError(context, e);
        try {
          await _load(forceApply: true);
        } catch (_) {}
      }
    } finally {
      _pendingTaskToggles--;
    }
  }

  void _showHowItWorks() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: const Text('How Life Game works'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('• Add habits on the Home tab and tick them off each day.'),
              SizedBox(height: 8),
              Text(
                '• Every completion is +2 XP. Unticking a habit removes its +2 XP.',
              ),
              SizedBox(height: 8),
              Text('• Level = XP ÷ 100 + 1. A level takes 50 completions.'),
              SizedBox(height: 8),
              Text(
                '• Your level also gives you a warrior rank — Recruit, Warrior, Knight, Champion, Warlord, Legend.',
              ),
              SizedBox(height: 8),
              Text('• Streak = days in a row with at least one habit done.'),
              SizedBox(height: 8),
              Text(
                '• Weekly and monthly tasks live here, on Profile — they give XP too, but no streak.',
              ),
              SizedBox(height: 8),
              Text(
                '• Follow people from Search or the leaderboard to see them on the Friends leaderboard.',
              ),
              SizedBox(height: 8),
              Text(
                '• Your data is stored in your own account. Only you can change it; other users can only see your public profile (name, XP, streak).',
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  Future<void> _copySupportEmail() async {
    await Clipboard.setData(const ClipboardData(text: _supportEmail));
    if (mounted) showInfo(context, 'Support email copied.');
  }

  /// Two-step delete: a plain-language warning dialog with an
  /// explicit "I understand" checkbox, then the real delete.
  /// While it runs the screen shows a blocking overlay; on success the
  /// auth gate signs the user out to the login screen.
  Future<void> _deleteAccount() async {
    var understood = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text('Delete your account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This permanently deletes your account and everything in it — your habits, logs, tasks, XP, streak, followers and your username. This cannot be undone.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Checkbox(
                    value: understood,
                    onChanged: (v) =>
                        setDialogState(() => understood = v ?? false),
                  ),
                  const Expanded(
                    child: Text('I understand, delete everything'),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.flame),
              onPressed: understood
                  ? () => Navigator.of(context).pop(true)
                  : null,
              child: const Text('Delete my account'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deletingAccount = true);
    try {
      await _auth.deleteAccount();
      // Success: the auth gate reacts to the signed-out event and
      // shows the login screen; this screen unmounts with it.
    } catch (e) {
      if (mounted) {
        setState(() => _deletingAccount = false);
        showError(context, e);
      }
    }
  }

  void _openSearch() {
    Navigator.of(context).push(
      WarriorPageRoute(builder: (_) => const SearchScreen()),
    );
  }

  /// Opens the Followers or Following list (18 Nov 2026): the numbers
  /// on the stats strip are tappable and show who is actually there.
  void _openFollowList({required bool followers}) {
    Navigator.of(context).push(
      WarriorPageRoute(
        builder: (_) => FollowListScreen(
          followers: followers,
          socialRepo: _social,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    return ResponsiveCenter(
      maxWidth: 980,
      child: Stack(
        children: [
          Scaffold(
            appBar: AppBar(
              title: const Text('Profile'),
              actions: [
                IconButton(
                  onPressed: _openSearch,
                  tooltip: 'Search people',
                  icon: const Icon(Icons.search),
                ),
                IconButton(
                  onPressed: _editProfile,
                  tooltip: 'Edit profile',
                  icon: const Icon(Icons.edit_outlined),
                ),
              ],
            ),
            body: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                children: [
                  if (_loading)
                    const Column(
                      children: [
                        SkeletonBox(height: 120, borderRadius: 20),
                        SizedBox(height: 16),
                        SkeletonBox(height: 110, borderRadius: 20),
                        SizedBox(height: 16),
                        SkeletonBox(height: 48, borderRadius: 999),
                        SizedBox(height: 16),
                        SkeletonBox(height: 76, borderRadius: 20),
                        SizedBox(height: 12),
                        SkeletonBox(height: 76, borderRadius: 20),
                      ],
                    )
                  else if (profile == null)
                    const EmptyState(
                      icon: Icons.person_off_outlined,
                      title: 'No profile yet',
                      subtitle: 'Sign in again to set up your profile.',
                    )
                  else ...[
                    _IdentityCard(profile: profile)
                        .animate()
                        .fadeIn()
                        .slideY(begin: 0.1),
                    const SizedBox(height: 16),
                    XpBar(xp: profile.xp)
                        .animate()
                        .fadeIn(delay: 60.ms)
                        .slideY(begin: 0.1),
                    const SizedBox(height: 16),
                    _StatsStrip(
                      rank: _rank,
                      followers: _followers,
                      following: _following,
                      bestStreak: profile.longestStreak,
                      onFollowersTap: () => _openFollowList(followers: true),
                      onFollowingTap: () => _openFollowList(followers: false),
                    ).animate().fadeIn(delay: 80.ms).slideY(begin: 0.1),
                    const SizedBox(height: 20),
                    // Tabs: Habits | Weekly | Monthly.
                    _TabBar(
                      tab: _tab,
                      habitsCount: _habitsList.length,
                      weeklyCount: _weekly.length,
                      monthlyCount: _monthly.length,
                      onTab: (i) => setState(() => _tab = i),
                    ).animate().fadeIn(delay: 100.ms),
                    const SizedBox(height: 14),
                    if (_tab == 0)
                      _HabitsTab(
                        habits: _habitsList,
                        onEdit: _editHabit,
                        onAdd: _addHabit,
                      )
                    else if (_tab == 1)
                      _TaskSection(
                        title: 'Weekly tasks',
                        subtitle: 'This week • +2 XP each',
                        items: _weekly
                            .map(
                              (t) => _TaskItem(
                                id: t.id,
                                title: t.title,
                                done: t.done,
                              ),
                            )
                            .toList(),
                        onToggle: _toggleWeekly,
                        onDelete: (id) async {
                          await _tasks.deleteWeeklyTask(id);
                          await _load();
                        },
                        onAdd: () => _addTask(weekly: true),
                      )
                    else
                      _TaskSection(
                        title: 'Monthly tasks',
                        subtitle: 'This month • +2 XP each',
                        items: _monthly
                            .map(
                              (t) => _TaskItem(
                                id: t.id,
                                title: t.title,
                                done: t.done,
                              ),
                            )
                            .toList(),
                        onToggle: _toggleMonthly,
                        onDelete: (id) async {
                          await _tasks.deleteMonthlyTask(id);
                          await _load();
                        },
                        onAdd: () => _addTask(weekly: false),
                      ),
                    const SizedBox(height: 28),
                    _FeedbackSection(feedbackRepo: _feedback)
                        .animate()
                        .fadeIn()
                        .slideY(begin: 0.1),
                    const SizedBox(height: 28),
                    const Text(
                      'Support',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Card(
                      child: Column(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.help_outline),
                            title: const Text('How Life Game works'),
                            subtitle: const Text(
                              'Habits, XP, streaks and levels, in one place',
                            ),
                            trailing: const Icon(
                              Icons.chevron_right,
                              color: AppTheme.inkSoft,
                            ),
                            onTap: _showHowItWorks,
                          ),
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(Icons.email_outlined),
                            title: const Text('Email support'),
                            subtitle: const Text(_supportEmail),
                            trailing: const Icon(
                              Icons.copy_outlined,
                              color: AppTheme.inkSoft,
                              size: 20,
                            ),
                            onTap: _copySupportEmail,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Card(
                      child: Column(
                        children: [
                          const ListTile(
                            leading: Icon(Icons.info_outline),
                            title: Text('About Life Game'),
                            subtitle: Text(
                              'Version 2.6.0+12 • Flutter • Appwrite',
                            ),
                          ),
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(
                              Icons.delete_forever,
                              color: AppTheme.flame,
                            ),
                            title: const Text(
                              'Delete account',
                              style: TextStyle(color: AppTheme.flame),
                            ),
                            subtitle: const Text(
                              'Removes your account and all your data',
                            ),
                            onTap: _deleteAccount,
                          ),
                          const Divider(height: 1),
                          ListTile(
                            leading: const Icon(
                              Icons.logout,
                              color: AppTheme.flame,
                            ),
                            title: const Text(
                              'Log out',
                              style: TextStyle(color: AppTheme.flame),
                            ),
                            onTap: _signOut,
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_deletingAccount)
            Positioned.fill(
              child: Container(
                color: Colors.black.withValues(alpha: 0.45),
                alignment: Alignment.center,
                child: const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(width: 16),
                        Text('Deleting your account…'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Feedback: a short form that saves to the `feedback` table, plus the
/// user's previously sent messages. Kept on Profile so feedback lives
/// next to Support, not on the main tabs.
class _FeedbackSection extends StatefulWidget {
  const _FeedbackSection({required this.feedbackRepo});

  final FeedbackRepository feedbackRepo;

  @override
  State<_FeedbackSection> createState() => _FeedbackSectionState();
}

class _FeedbackSectionState extends State<_FeedbackSection> {
  final _controller = TextEditingController();
  List<FeedbackEntry> _sent = [];
  bool _loading = true;
  bool _sending = false;
  bool _justSent = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await widget.feedbackRepo.listMyFeedback();
      if (mounted) setState(() => _sent = list);
    } catch (_) {
      // Feedback is optional: a missing table (setup not run yet)
      // must not break the whole Profile screen.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _justSent = false;
    });
    try {
      await widget.feedbackRepo.submitFeedback(text);
      _controller.clear();
      if (mounted) setState(() => _justSent = true);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _dateLabel(DateTime? date) {
    if (date == null) return '';
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Feedback',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        const Text(
          'Tell us what works, what does not, and what you want next.',
          style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Write your feedback here…',
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      color: AppTheme.ink,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.send, size: 18),
            label: Text(_sending ? 'Sending…' : 'Send feedback'),
          ),
        ),
        if (_justSent) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppTheme.ember.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle, color: AppTheme.ember, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Thank you — your feedback was sent.',
                    style: TextStyle(
                      color: AppTheme.ember,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_sent.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Text(
            'Your feedback',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
          const SizedBox(height: 8),
          ..._sent.map(
            (entry) => Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.text),
                    const SizedBox(height: 6),
                    Text(
                      _dateLabel(entry.createdAt),
                      style: const TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Identity card (horizontal): avatar on the left, name + username +
/// bio + level chip on the right. The old centred stack (avatar on
/// top, name below) is replaced by this side-by-side layout.
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.profile});

  final Profile profile;

  @override
  Widget build(BuildContext context) {
    final level = levelForXp(profile.xp);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AvatarCircle(initials: profile.initials, size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.displayName,
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '@${profile.username}',
                    style: const TextStyle(
                      color: AppTheme.ember,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (profile.bio.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      profile.bio,
                      style: const TextStyle(color: AppTheme.inkSoft),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      gradient: AppTheme.heroGradient,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.shield,
                          color: AppTheme.ink,
                          size: 15,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Level $level • ${rankNameForLevel(level)}',
                          style: const TextStyle(
                            color: AppTheme.ink,
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
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

/// Stats strip: Rank, Followers, Following, Best streak as compact
/// pills in one horizontal row (not a 2×2 grid). Followers and
/// Following are tappable — they open the list of people (18 Nov 2026).
class _StatsStrip extends StatelessWidget {
  const _StatsStrip({
    required this.rank,
    required this.followers,
    required this.following,
    required this.bestStreak,
    this.onFollowersTap,
    this.onFollowingTap,
  });

  final int rank;
  final int followers;
  final int following;
  final int bestStreak;
  final VoidCallback? onFollowersTap;
  final VoidCallback? onFollowingTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatPill(value: '#$rank', label: 'Rank'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatPill(
            value: '$followers',
            label: 'Followers',
            onTap: onFollowersTap,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatPill(
            value: '$following',
            label: 'Following',
            onTap: onFollowingTap,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatPill(value: '${bestStreak}d', label: 'Best streak'),
        ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({required this.value, required this.label, this.onTap});

  final String value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: AppTheme.inkSoft, fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
    final onTap = this.onTap;
    if (onTap == null) return pill;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: pill,
      ),
    );
  }
}

/// The tab bar: Habits | Weekly | Monthly. A segmented control —
/// one row, the active tab filled, the others plain. Tapping switches
/// the list below; the lists are no longer stacked on top of each
/// other.
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tab,
    required this.habitsCount,
    required this.weeklyCount,
    required this.monthlyCount,
    required this.onTab,
  });

  final int tab;
  final int habitsCount;
  final int weeklyCount;
  final int monthlyCount;
  final ValueChanged<int> onTab;

  @override
  Widget build(BuildContext context) {
    final labels = ['Habits', 'Weekly', 'Monthly'];
    final counts = [habitsCount, weeklyCount, monthlyCount];
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: List.generate(3, (i) {
          final active = tab == i;
          return Expanded(
            child: Material(
              color: active ? AppTheme.ember : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                onTap: () => onTab(i),
                borderRadius: BorderRadius.circular(999),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  alignment: Alignment.center,
                  child: Text(
                    '${labels[i]} (${counts[i]})',
                    style: TextStyle(
                      color: active ? AppTheme.ink : AppTheme.inkSoft,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// The Habits tab: the user's habits, each row opening the edit
/// dialog (rename / delete). The "+" adds a habit directly — the old
/// "go to Home to add" hint screen is gone.
class _HabitsTab extends StatelessWidget {
  const _HabitsTab({
    required this.habits,
    required this.onEdit,
    required this.onAdd,
  });

  final List<Habit> habits;
  final Future<void> Function(Habit habit) onEdit;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'My Habits',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            IconButton(
              onPressed: onAdd,
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Add habit',
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (habits.isEmpty)
          const Card(
            child: Padding(
              padding: EdgeInsets.all(18),
              child: Text(
                'No habits yet — add your first one with the + button.',
                style: TextStyle(color: AppTheme.inkSoft),
              ),
            ),
          )
        else
          ...habits.map(
            (habit) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _HabitRow(habit: habit, onTap: () => onEdit(habit)),
            ),
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
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.check_circle_outline,
                  color: AppTheme.ink,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  habit.title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
              // Notes indicator: a habit with notes shows a note icon.
              if (habit.notes.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.sticky_note_2_outlined,
                    color: AppTheme.inkSoft,
                    size: 18,
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
            // Flexible so the header never overflows the narrower
            // side-by-side columns on desktop.
            Expanded(
              child: Text(
                subtitle,
                style: const TextStyle(color: AppTheme.inkSoft, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
                    // Done items stay in the list, fully readable:
                    // no strikethrough — the filled checkbox and the
                    // subtle tint are the done state.
                    tileColor: items[i].done
                        ? AppTheme.ember.withValues(alpha: 0.05)
                        : null,
                    title: Text(
                      items[i].title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: AppTheme.ink,
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

/// Public profile view — what anyone sees when they tap a user on the
/// leaderboard or in search. Habits are private (owner-only), so this
/// shows the public profile: identity, bio and stats. Restyled with
/// the same horizontal identity card as the own profile (18 Nov 2026).
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
    final level = levelForXp(profile.xp);
    return Scaffold(
      appBar: AppBar(title: Text('@${profile.username}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: [
          const SizedBox(height: 8),
          _IdentityCard(profile: profile),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Level $level • ${rankNameForLevel(level)}',
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
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StatBox(
                  label: 'XP',
                  value: '${profile.xp}',
                  gradient: AppTheme.emberGradient,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatBox(
                  label: 'Streak',
                  value: '${profile.currentStreak} days',
                  gradient: AppTheme.goldGradient,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StatBox(
                  label: 'Best streak',
                  value: '${profile.longestStreak} days',
                  gradient: AppTheme.flameGradient,
                ),
              ),
            ],
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
              color: AppTheme.ink,
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
          ? const LinearGradient(colors: [Color(0xFF9CA3AF), Color(0xFF6B7280)])
          : AppTheme.heroGradient,
    );
  }
}

/// Followers / Following list (18 Nov 2026): the numbers on the
/// Profile stats strip are tappable and open the actual people.
/// Each row shows avatar, name, username and level/rank; tapping a
/// row opens that person's profile.
class FollowListScreen extends StatefulWidget {
  const FollowListScreen({
    super.key,
    required this.followers,
    this.socialRepo,
  });

  /// True = people following me; false = people I follow.
  final bool followers;
  final SocialRepository? socialRepo;

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  SocialRepository get _social => widget.socialRepo ?? SocialRepository();

  List<Profile> _people = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final people = await _social.followProfiles(
        followers: widget.followers,
      );
      if (mounted) setState(() => _people = people);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.followers ? 'Followers' : 'Following'),
      ),
      body: ResponsiveCenter(
        maxWidth: 720,
        child: _loading
            ? ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                children: const [
                  SkeletonBox(height: 64, borderRadius: 16),
                  SizedBox(height: 10),
                  SkeletonBox(height: 64, borderRadius: 16),
                  SizedBox(height: 10),
                  SkeletonBox(height: 64, borderRadius: 16),
                ],
              )
            : _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Could not load the list. ${_error!}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.inkSoft),
                  ),
                ),
              )
            : _people.isEmpty
            ? EmptyState(
                icon: widget.followers
                    ? Icons.group_outlined
                    : Icons.person_add_outlined,
                title: widget.followers
                    ? 'No followers yet'
                    : 'Not following anyone yet',
                subtitle: widget.followers
                    ? 'When someone follows you, they will show up here.'
                    : 'Follow people from Search or the leaderboard and they will show up here.',
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                  itemCount: _people.length,
                  itemBuilder: (context, index) {
                    final person = _people[index];
                    final level = levelForXp(person.xp);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Material(
                        color: AppTheme.card,
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          onTap: () => Navigator.of(context).push(
                            WarriorPageRoute(
                              builder: (_) => UserProfileScreen(
                                profile: person,
                                socialRepo: _social,
                              ),
                            ),
                          ),
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: AppTheme.cardBorder),
                            ),
                            child: Row(
                              children: [
                                AvatarCircle(
                                  initials: person.initials,
                                  size: 40,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        person.displayName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w700,
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        '@${person.username}',
                                        style: const TextStyle(
                                          color: AppTheme.inkSoft,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 9,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.ember.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    'LVL $level • ${rankNameForLevel(level).toUpperCase()}',
                                    style: const TextStyle(
                                      color: AppTheme.ember,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(
                                  Icons.chevron_right,
                                  color: AppTheme.inkSoft,
                                  size: 20,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
