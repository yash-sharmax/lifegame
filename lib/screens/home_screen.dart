import 'dart:async';

import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/models.dart';
import '../data/reminder_repository.dart';
import '../data/reminder_service.dart';
import '../data/repositories.dart';
import '../logic/quotes.dart';
import '../logic/reminders.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/habit_dialog.dart';
import '../widgets/reminder_dialog.dart';
import 'auth_screen.dart';
import 'challenges_screen.dart';
import 'schedule_screen.dart';

/// Home: greeting, quote, streak + XP, today's habits.
/// The screen the user opens every day to tick things off.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.habitRepo, this.profileRepo, this.reminderRepo});

  final HabitRepository? habitRepo;
  final ProfileRepository? profileRepo;
  final ReminderRepository? reminderRepo;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();
  ProfileRepository get _profiles => widget.profileRepo ?? ProfileRepository();
  ReminderRepository get _reminders =>
      widget.reminderRepo ?? ReminderRepository();

  List<Habit> _habitsList = [];
  Set<String> _doneToday = {};
  Map<String, Reminder> _remindersByKey = {};
  Profile? _profile;
  bool _loading = true;
  late final ConfettiController _confetti;
  // Habits whose toggle is still in flight: a second tap while the
  // first toggle is saving is ignored, so two toggles can never run
  // against the same stale state (see repositories.dart).
  final Set<String> _toggling = {};
  StreamSubscription<void>? _habitChanges;
  StreamSubscription<void>? _reminderChanges;

  String get _today => todayKey();

  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 2));
    // Habits can change elsewhere (e.g. deleted from Profile): reload
    // whenever the habit list changes instead of trusting initState.
    _habitChanges = HabitRepository.onChanged.listen((_) {
      if (mounted) _load();
    });
    _reminderChanges = ReminderRepository.onChanged.listen((_) {
      if (mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _habitChanges?.cancel();
    _reminderChanges?.cancel();
    _confetti.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Only show the spinner on the first load: later refreshes
    // (after a toggle, or a change made on another tab) update the
    // list silently instead of flashing a loader over the habits.
    final firstLoad = _profile == null && _habitsList.isEmpty;
    if (firstLoad) setState(() => _loading = true);
    try {
      final habits = await _habits.listMyHabits();
      final logs = await _habits.listLogsForDate(_today);
      final profile = await _profiles.fetchMyProfile();
      // Reminders are best-effort: a reminder-store failure must never
      // hide the habits (and widget tests run without a signed-in user).
      Map<String, Reminder> reminders = {};
      try {
        reminders = await _reminders.remindersByTarget();
      } catch (_) {
        reminders = {};
      }
      if (!mounted) return;
      setState(() {
        _habitsList = habits;
        _doneToday = logs.map((l) => l.habitId).toSet();
        _profile = profile;
        _remindersByKey = reminders;
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

  bool get _allDone =>
      _habitsList.isNotEmpty && _doneToday.length >= _habitsList.length;

  Future<void> _toggle(Habit habit, bool value) async {
    // A tap must feel instant: paint the new state NOW (checked tile +
    // updated XP) and sync to Appwrite in the background. The write
    // itself still runs through the repository's serialised queue with
    // verify-after-write (the v2.2.0+5 fix) — only the painting is
    // optimistic. On a real failure the optimistic state rolls back so
    // the tile shows the true server state.
    // No success toast: the tile already shows "Done • +2 XP" and the
    // XP count updates instantly — a popup on every tap is what made
    // taps feel slow and stuck (user feedback, 14 Nov 2026).
    if (_toggling.contains(habit.id)) return;
    final wasDone = _doneToday.contains(habit.id);
    final wasAllDone = _allDone;
    final delta = xpDeltaForToggle(completing: value, wasDone: wasDone);
    final prevDone = Set<String>.from(_doneToday);
    final prevProfile = _profile;
    setState(() {
      if (value) {
        _doneToday.add(habit.id);
      } else {
        _doneToday.remove(habit.id);
      }
      final profile = _profile;
      if (profile != null && delta != 0) {
        _profile = profile.copyWith(
          xp: (profile.xp + delta).clamp(0, 100000000),
        );
      }
    });
    _toggling.add(habit.id);
    try {
      await _habits.toggleHabit(habit: habit, date: _today, completed: value);
      if (!mounted) return;
      // Quiet sync: refresh streak + canonical state without a spinner
      // and without a toast.
      await _load();
      if (!mounted) return;
      if (value && _allDone && !wasAllDone) _confetti.play();
    } catch (e) {
      // Roll the optimistic paint back, then show the real state.
      if (mounted) {
        setState(() {
          _doneToday = prevDone;
          _profile = prevProfile;
        });
        showError(context, e);
        try {
          await _load();
        } catch (_) {}
      }
    } finally {
      _toggling.remove(habit.id);
    }
  }

  Future<void> _editHabit(Habit habit) async {
    final result = await showHabitEditDialog(context, habit);
    if (result == null || !mounted) return;
    try {
      if (result.action == HabitEditAction.save && result.title.isNotEmpty) {
        await _habits.updateHabit(habit, title: result.title);
      } else if (result.action == HabitEditAction.delete) {
        // Deleting removes the habit's logs and takes back today's +2
        // XP when the habit is done today (see HabitRepository).
        await _habits.deleteHabit(habit.id);
        if (!mounted) return;
        showInfo(context, 'Habit deleted.');
        await _load();
        return;
      } else {
        return;
      }
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _editReminder(Habit habit) async {
    final existing = _remindersByKey['habit:${habit.id}'];
    final result = await showReminderDialog(
      context,
      title: habit.title,
      existing: existing,
    );
    if (result == null || !mounted) return;
    try {
      if (result.remove) {
        await _reminders.deleteReminder('habit', habit.id);
        await ReminderService.instance.cancelAndroidReminder(existing!);
      } else if (result.time != null) {
        final parsed = parseReminderTime(result.time!);
        if (parsed == null) return;
        final saved = await _reminders.setReminder(
          kind: 'habit',
          targetId: habit.id,
          title: habit.title,
          hour: parsed.hour,
          minute: parsed.minute,
          enabled: result.enabled,
        );
        await ReminderService.instance.scheduleAndroidReminder(saved);
        await ReminderService.instance.ensureWebPermission();
        await ReminderService.instance.refresh();
      }
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _addHabit() async {
    final titleController = TextEditingController();
    var color = AppTheme.habitGradients.first.colors.first.toARGB32();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text('Add a habit'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Habit name',
                  hintText: 'e.g. Read 10 pages',
                ),
              ),
              const SizedBox(height: 18),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Pick a colour',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: AppTheme.habitGradients.map((g) {
                  final c = g.colors.first.toARGB32();
                  final selected = c == color;
                  return GestureDetector(
                    onTap: () => setDialogState(() => color = c),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        gradient: g,
                        shape: BoxShape.circle,
                        border: selected
                            ? Border.all(color: AppTheme.ink, width: 2.5)
                            : null,
                      ),
                      child: selected
                          ? const Icon(
                              Icons.check,
                              color: Colors.white,
                              size: 20,
                            )
                          : null,
                    ),
                  );
                }).toList(),
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
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && titleController.text.trim().isNotEmpty) {
      try {
        await _habits.addHabit(
          title: titleController.text.trim(),
          color: color,
        );
        await _load();
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final streak = profile?.currentStreak ?? 0;
    final xp = profile?.xp ?? 0;
    final wide = isWideScreen(context);

    // The XP bar is pinned above the scrollable list, so the user's
    // current XP (and level) is visible at the top at all times.
    return ResponsiveCenter(
      maxWidth: 980,
      child: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: _Header(
                  displayName: profile?.displayName ?? 'Player',
                  streak: streak,
                ).animate().fadeIn().slideY(begin: -0.1),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: XpBar(xp: xp)
                    .animate()
                    .fadeIn(delay: 60.ms)
                    .slideY(begin: 0.1),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                    children: [
                      _DailyLineCard(line: quoteForDay())
                          .animate()
                          .fadeIn(delay: 80.ms)
                          .slideY(begin: 0.1),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _FeatureCard(
                              icon: Icons.schedule_outlined,
                              title: 'Today’s Schedule',
                              subtitle: 'Your day, in time order',
                              gradient: AppTheme.tealGradient,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const ScheduleScreen(),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _FeatureCard(
                              icon: Icons.emoji_events_outlined,
                              title: 'Challenges',
                              subtitle: 'Lock in and compete',
                              gradient: AppTheme.amberGradient,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => const ChallengesScreen(),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          const Flexible(
                            child: Text(
                              "Today's habits",
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const Spacer(),
                          if (_habitsList.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.violet.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '${_doneToday.length}/${_habitsList.length} done',
                                style: const TextStyle(
                                  color: AppTheme.violet,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_loading)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 48),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      else if (_habitsList.isEmpty)
                        EmptyState(
                          icon: Icons.flag_outlined,
                          title: 'Your journey starts here',
                          subtitle: 'No habits yet. Add your first one — small steps, big change.',
                          actionLabel: 'Add your first habit',
                          onAction: _addHabit,
                        )
                      else if (wide)
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final tileWidth = (constraints.maxWidth - 12) / 2;
                            return Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: _habitsList.asMap().entries.map((
                                entry,
                              ) {
                                final habit = entry.value;
                                final done = _doneToday.contains(habit.id);
                                return SizedBox(
                                  width: tileWidth,
                                  child:
                                      _HabitTile(
                                            habit: habit,
                                            done: done,
                                            reminder:
                                                _remindersByKey['habit:${habit.id}'],
                                            onToggle: (v) => _toggle(habit, v),
                                            onEdit: () => _editHabit(habit),
                                            onAlarm: () =>
                                                _editReminder(habit),
                                          )
                                          .animate()
                                          .fadeIn(delay: (60 * entry.key).ms)
                                          .slideX(begin: 0.08),
                                );
                              }).toList(),
                            );
                          },
                        )
                      else
                        ..._habitsList.asMap().entries.map((entry) {
                          final habit = entry.value;
                          final done = _doneToday.contains(habit.id);
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child:
                                _HabitTile(
                                      habit: habit,
                                      done: done,
                                      reminder:
                                          _remindersByKey['habit:${habit.id}'],
                                      onToggle: (v) => _toggle(habit, v),
                                      onEdit: () => _editHabit(habit),
                                      onAlarm: () => _editReminder(habit),
                                    )
                                    .animate()
                                    .fadeIn(delay: (60 * entry.key).ms)
                                    .slideX(begin: 0.08),
                          );
                        }),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _addHabit,
                        icon: const Icon(Icons.add),
                        label: const Text('Add habit'),
                      ),
                      if (_allDone) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            gradient: AppTheme.amberGradient,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.emoji_events,
                                color: Colors.white,
                                size: 34,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Day complete! Every habit ticked.',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ).animate().fadeIn().scale(
                          begin: const Offset(0.95, 0.95),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.topCenter,
            child: ConfettiWidget(
              confettiController: _confetti,
              blastDirectionality: BlastDirectionality.explosive,
              shouldLoop: false,
              numberOfParticles: 60,
              gravity: 0.25,
              colors: const [
                AppTheme.violet,
                AppTheme.pink,
                AppTheme.amber,
                AppTheme.teal,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.displayName, required this.streak});

  final String displayName;
  final int streak;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${greetingForHour()},',
                style: const TextStyle(
                  color: AppTheme.inkSoft,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                displayName,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${months[now.month]} ${now.day}, ${now.year} • '
                'Day ${now.difference(DateTime(now.year, 1, 1)).inDays + 1} of the year',
                style: const TextStyle(color: AppTheme.inkSoft, fontSize: 13),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.local_fire_department,
                color: Colors.deepOrange,
                size: 22,
              ),
              const SizedBox(width: 4),
              Text(
                '$streak',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The line of the day: one motivational line, the same all day,
/// picked deterministically from the date (see logic/quotes.dart).
/// Shown prominently on Home so the user sees today's line every time
/// they open the app.
class _DailyLineCard extends StatelessWidget {
  const _DailyLineCard({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
      decoration: BoxDecoration(
        gradient: AppTheme.heroGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.auto_awesome, color: Colors.white70, size: 16),
              const SizedBox(width: 6),
              Text(
                'LINE OF THE DAY',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.9),
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  letterSpacing: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.format_quote, color: Colors.white70, size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  line,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HabitTile extends StatelessWidget {
  const _HabitTile({
    required this.habit,
    required this.done,
    required this.onToggle,
    required this.onEdit,
    required this.onAlarm,
    this.reminder,
  });

  final Habit habit;
  final bool done;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onAlarm;
  final Reminder? reminder;

  @override
  Widget build(BuildContext context) {
    final gradient =
        AppTheme.habitGradients[habit.color % AppTheme.habitGradients.length];
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        onTap: () => onToggle(!done),
        // Long-press opens the same edit dialog (rename / delete) that
        // Profile offers — a habit card must always have a delete path.
        onLongPress: onEdit,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: done ? Colors.transparent : const Color(0xFFEDEAF5),
            ),
            color: done ? AppTheme.violet.withValues(alpha: 0.06) : null,
          ),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(
                  Icons.check_circle_outline,
                  color: Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      habit.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        // Done items stay fully readable: no
                        // strikethrough — the filled check circle and
                        // the tinted tile are the done state.
                        color: AppTheme.ink,
                      ),
                    ),
                    Text(
                      done
                          ? 'Done • +$xpPerTask XP'
                          : 'Tap to complete • +$xpPerTask XP',
                      style: const TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                    if (reminder != null)
                      Text(
                        reminder!.enabled
                            ? 'Alarm ${formatReminderTime12h(reminder!.hour, reminder!.minute)}'
                            : 'Alarm off',
                        style: TextStyle(
                          color: reminder!.enabled
                              ? AppTheme.teal
                              : AppTheme.inkSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                onPressed: onAlarm,
                tooltip: reminder == null
                    ? 'Set a reminder'
                    : 'Change reminder',
                icon: Icon(
                  reminder == null
                      ? Icons.alarm_add_outlined
                      : reminder!.enabled
                      ? Icons.alarm_on
                      : Icons.alarm_off,
                  color: reminder != null && reminder!.enabled
                      ? AppTheme.violet
                      : AppTheme.inkSoft,
                  size: 20,
                ),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
              IconButton(
                onPressed: onEdit,
                tooltip: 'Edit or delete habit',
                icon: const Icon(
                  Icons.more_vert,
                  color: AppTheme.inkSoft,
                  size: 20,
                ),
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: done ? AppTheme.tealGradient : null,
                  color: done ? null : Colors.white,
                  border: done
                      ? null
                      : Border.all(color: const Color(0xFFD8D2EA), width: 2),
                ),
                child: done
                    ? const Icon(Icons.check, color: Colors.white, size: 20)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Entry card for a feature screen (Schedule / Challenges) on Home.
class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gradient,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Gradient gradient;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEDEAF5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: gradient,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: Colors.white, size: 22),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppTheme.inkSoft,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
