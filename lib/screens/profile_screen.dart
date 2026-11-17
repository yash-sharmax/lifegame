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

/// Email shown for support — the developer's own address. It is copied
/// to the clipboard on tap (no extra dependency needed for a mail link).
const String _supportEmail = 'yashsharmaup2008@gmail.com';

/// The user's own profile: stats, all habits, weekly + monthly tasks,
/// support + feedback, settings and logout.
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
  // Guards a rapid second tap on the same task while its write is still
  // syncing (same pattern as Home's _toggling set).
  final Set<String> _togglingTasks = {};
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
      if (mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _habitChanges?.cancel();
    _taskChanges?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
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
        await _habits.updateHabit(habit, title: result.title);
        await _load();
      } else if (result.action == HabitEditAction.delete) {
        // Deleting removes the habit's logs and takes back today's +2
        // XP when the habit is done today (see HabitRepository).
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
  /// checkbox and the XP back to the server state.
  /// (Before v2.2.0+7 only the checkbox flipped optimistically; the XP
  /// number waited for the full network refetch, so the tap felt slow
  /// even though the tick itself was instant.)
  Future<void> _toggleWeekly(String id, bool done) async {
    if (_togglingTasks.contains(id)) return;
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
    _togglingTasks.add(id);
    try {
      await _tasks.toggleWeeklyTask(id, done);
      if (!mounted) return;
      // Quiet sync: refresh canonical state without a spinner.
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() {
          _weekly = prev;
          _profile = prevProfile;
        });
        showError(context, e);
        try {
          await _load();
        } catch (_) {}
      }
    } finally {
      _togglingTasks.remove(id);
    }
  }

  Future<void> _toggleMonthly(String id, bool done) async {
    if (_togglingTasks.contains(id)) return;
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
    _togglingTasks.add(id);
    try {
      await _tasks.toggleMonthlyTask(id, done);
      if (!mounted) return;
      // Quiet sync: refresh canonical state without a spinner.
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() {
          _monthly = prev;
          _profile = prevProfile;
        });
        showError(context, e);
        try {
          await _load();
        } catch (_) {}
      }
    } finally {
      _togglingTasks.remove(id);
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
              Text('• Every completion is +2 XP. Unticking takes 2 XP back.'),
              SizedBox(height: 8),
              Text('• Level = XP ÷ 100 + 1. A level takes 50 completions.'),
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
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
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

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final wide = isWideScreen(context);
    // Weekly / monthly task sections, shared by the mobile (stacked)
    // and desktop (side-by-side) layouts below.
    final weeklySection = _TaskSection(
      title: 'Weekly tasks',
      subtitle: 'This week • +2 XP each',
      items: _weekly
          .map((t) => _TaskItem(id: t.id, title: t.title, done: t.done))
          .toList(),
      onToggle: _toggleWeekly,
      onDelete: (id) async {
        await _tasks.deleteWeeklyTask(id);
        await _load();
      },
      onAdd: () => _addTask(weekly: true),
    );
    final monthlySection = _TaskSection(
      title: 'Monthly tasks',
      subtitle: 'This month • +2 XP each',
      items: _monthly
          .map((t) => _TaskItem(id: t.id, title: t.title, done: t.done))
          .toList(),
      onToggle: _toggleMonthly,
      onDelete: (id) async {
        await _tasks.deleteMonthlyTask(id);
        await _load();
      },
      onAdd: () => _addTask(weekly: false),
    );
    return ResponsiveCenter(
      maxWidth: 980,
      child: Stack(
        children: [
          RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
              children: [
                Row(
                  children: [
                    const Text(
                      'Profile',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
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
                      MaterialPageRoute(builder: (_) => const _AddHabitHint()),
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
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: weeklySection),
                        const SizedBox(width: 16),
                        Expanded(child: monthlySection),
                      ],
                    )
                  else ...[
                    weeklySection,
                    const SizedBox(height: 24),
                    monthlySection,
                  ],
                  const SizedBox(height: 24),
                  _FeedbackSection(feedbackRepo: _feedback)
                      .animate()
                      .fadeIn()
                      .slideY(begin: 0.1),
                  const SizedBox(height: 24),
                  const Text(
                    'Support',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
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
                  const SizedBox(height: 24),
                  const Text(
                    'Settings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Card(
                    child: Column(
                      children: [
                        const ListTile(
                          leading: Icon(Icons.info_outline),
                          title: Text('About Life Game'),
                          subtitle: Text(
                            'Version 2.3.0+8 • Flutter • Appwrite',
                          ),
                        ),
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(
                            Icons.delete_forever,
                            color: Colors.red,
                          ),
                          title: const Text(
                            'Delete account',
                            style: TextStyle(color: Colors.red),
                          ),
                          subtitle: const Text(
                            'Removes your account and all your data',
                          ),
                          onTap: _deleteAccount,
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
                      color: Colors.white,
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
              color: AppTheme.teal.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle, color: AppTheme.teal, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Thank you — your feedback was sent.',
                    style: TextStyle(
                      color: AppTheme.teal,
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
  const _SectionTitle({required this.title, required this.count, this.onAdd});

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
                        ? AppTheme.violet.withValues(alpha: 0.05)
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
          Center(child: AvatarCircle(initials: profile.initials, size: 96)),
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
          ? const LinearGradient(colors: [Color(0xFF9CA3AF), Color(0xFF6B7280)])
          : AppTheme.heroGradient,
    );
  }
}
