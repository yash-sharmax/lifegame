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
import 'leaderboard_screen.dart';
import 'schedule_screen.dart';
import 'search_screen.dart';

/// Home: greeting, date + days left, XP + streak, today's progress,
/// today's habits. The screen the user opens every day to tick things
/// off.
///
/// Local-first (18 Nov 2026): a tap flips the tile and the XP
/// instantly in memory; the server sync runs in the background. The
/// user never waits for a network round trip to see the tick.
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
  // Strike counter per habit: bumped on every completion so the slash
  // sweep (StrikeOverlay) replays for that tile.
  final Map<String, int> _strikeKeys = {};
  // Toggles currently syncing to the server. While one is in flight,
  // a reload (triggered by the repository's onChanged notification)
  // must NOT overwrite the locally-correct done set / XP with server
  // data that predates the in-flight toggle — that is what made rapid
  // double-taps flicker back. The reload still applies the habit list
  // and reminders; the done set and profile are applied once no toggle
  // is in flight (the toggle's own completion refreshes the streak).
  int _pendingToggles = 0;
  StreamSubscription<void>? _habitChanges;
  StreamSubscription<void>? _reminderChanges;
  StreamSubscription<void>? _profileChanges;

  String get _today => todayKey();

  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 2));
    // Habits can change elsewhere (e.g. deleted from Profile): reload
    // whenever the habit list changes instead of trusting initState.
    _habitChanges = HabitRepository.onChanged.listen((_) {
      // Skip while a toggle is syncing: the local state is newer than
      // the server data a reload would fetch right now (see
      // _pendingToggles). The toggle's own completion refreshes the
      // streak; the next notification (after the write lands) reloads.
      if (mounted && _pendingToggles == 0) _load();
    });
    _reminderChanges = ReminderRepository.onChanged.listen((_) {
      if (mounted) _load();
    });
    // The profile itself can change (the once-per-session derived-XP
    // sync corrects a drifted XP): reload so the XP pill stays true.
    _profileChanges = ProfileRepository.onChanged.listen((_) {
      if (mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _habitChanges?.cancel();
    _reminderChanges?.cancel();
    _profileChanges?.cancel();
    _confetti.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceApply = false}) async {
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
      // Apply the done set + profile only when no toggle is in
      // flight: a reload that lands mid-toggle would fetch server
      // data predating the local flip and paint it back over the
      // user's tap (rapid double-tap flicker). The habit list and
      // reminders are unaffected by toggles, so they always apply.
      // forceApply (used after a failed toggle's rollback) always
      // applies: the server state is the true state then.
      final applyState = forceApply || _pendingToggles == 0;
      setState(() {
        _habitsList = habits;
        if (applyState) {
          _doneToday = logs.map((l) => l.habitId).toSet();
          _profile = profile;
        }
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

  /// Refreshes only the streak fields from the server after a toggle.
  /// XP and the done set are already correct locally (optimistic
  /// paint + full-reversal delta), so they are deliberately NOT
  /// overwritten here — a re-fetch that lands between two fast taps
  /// would otherwise flicker the XP back to the pre-tap value.
  Future<void> _refreshStreak() async {
    try {
      final profile = await _profiles.fetchMyProfile();
      if (!mounted || profile == null) return;
      final current = _profile;
      if (current == null) return;
      setState(() {
        _profile = current.copyWith(
          currentStreak: profile.currentStreak,
          longestStreak: profile.longestStreak,
          lastActiveDate: profile.lastActiveDate,
        );
      });
    } catch (_) {
      // Best-effort: the streak is a small header number; a failed
      // refresh leaves the local estimate until the next full load.
    }
  }

  Future<void> _toggle(Habit habit, bool value) async {
    // Local-first: paint the new state NOW (checked tile + updated XP
    // + streak estimate) and sync to Appwrite in the background. The
    // write itself still runs through the repository's serialised
    // queue — only the painting is optimistic. Rapid taps are allowed:
    // each tap flips the local state and queues its own server write,
    // and the queue runs them in order, so the server ends in the same
    // state as the screen. On a real failure the optimistic state
    // rolls back so the tile shows the true server state.
    // No success toast: the tile already shows "Done • +2 XP" and the
    // XP count updates instantly — a popup on every tap is what made
    // taps feel slow and stuck (user feedback, 14 Nov 2026).
    final wasDone = _doneToday.contains(habit.id);
    if (wasDone == value) return;
    final wasAllDone = _allDone;
    final delta = xpDeltaForToggle(completing: value, wasDone: wasDone);
    final prevDone = Set<String>.from(_doneToday);
    final prevProfile = _profile;
    setState(() {
      if (value) {
        _doneToday.add(habit.id);
        _strikeKeys[habit.id] = (_strikeKeys[habit.id] ?? 0) + 1;
      } else {
        _doneToday.remove(habit.id);
      }
      final profile = _profile;
      if (profile != null) {
        // Streak estimate: the first tick of the day advances it
        // (same rule the server uses). Unticking today's last done
        // habit drops it by one right away — the background refresh
        // corrects the estimate if it is off.
        var streak = profile.currentStreak;
        var lastActive = profile.lastActiveDate;
        if (value && !wasDone) {
          streak = streakAfterTick(
            currentStreak: profile.currentStreak,
            lastActiveDate: profile.lastActiveDate,
            today: _today,
          );
          lastActive = _today;
        } else if (!value &&
            wasDone &&
            _doneToday.isEmpty &&
            profile.lastActiveDate == _today) {
          // The streak run ending today loses its final day, so it
          // drops by exactly one (to the run ending yesterday, or
          // to 0 when today was the only active day).
          streak = (profile.currentStreak - 1).clamp(0, 1000000);
          lastActive = streak > 0 ? yesterdayKey() : null;
        }
        _profile = profile.copyWith(
          xp: (profile.xp + delta).clamp(0, 100000000),
          currentStreak: streak,
          lastActiveDate: lastActive,
        );
      }
    });
    if (value && _allDone && !wasAllDone) _confetti.play();
    _pendingToggles++;
    try {
      await _habits.toggleHabit(habit: habit, date: _today, completed: value);
      if (!mounted) return;
      // Quiet sync: refresh the streak from the server without
      // touching the locally-correct XP or done set.
      unawaited(_refreshStreak());
    } catch (e) {
      // Roll the optimistic paint back, then show the real state.
      if (mounted) {
        setState(() {
          _doneToday = prevDone;
          _profile = prevProfile;
        });
        showError(context, e);
        try {
          await _load(forceApply: true);
        } catch (_) {}
      }
    } finally {
      _pendingToggles--;
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
      } else if (result.action == HabitEditAction.delete) {
        // Deleting removes the habit's logs and takes back the XP its
        // completions contributed (see HabitRepository).
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
    // One shared creation flow (see widgets/habit_dialog.dart) — the
    // same dialog Schedule uses, so habits behave identically.
    final result = await showAddHabitDialog(context);
    if (result == null || !mounted) return;
    try {
      await _habits.addHabit(title: result.title, color: result.color);
      await _load();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _openLeaderboard() {
    Navigator.of(context).push(
      WarriorPageRoute(builder: (_) => const LeaderboardScreen()),
    );
  }

  void _openSearch() {
    Navigator.of(context).push(
      WarriorPageRoute(builder: (_) => const SearchScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final streak = profile?.currentStreak ?? 0;
    final xp = profile?.xp ?? 0;
    final wide = isWideScreen(context);
    final doneCount = _doneToday.length;
    final totalCount = _habitsList.length;
    final progress = totalCount == 0 ? 0.0 : doneCount / totalCount;

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
                  xp: xp,
                  onXpTap: _openLeaderboard,
                  onSearchTap: _openSearch,
                ).animate().fadeIn().slideY(begin: -0.1),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 84),
                    children: [
                      _TodayProgressCard(
                        done: doneCount,
                        total: totalCount,
                        fraction: progress,
                      ).animate().fadeIn(delay: 60.ms).slideY(begin: 0.1),
                      const SizedBox(height: 12),
                      _DailyLineCard(line: quoteForDay())
                          .animate()
                          .fadeIn(delay: 80.ms)
                          .slideY(begin: 0.1),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: _QuickLinkCard(
                              icon: Icons.calendar_today_outlined,
                              title: 'Schedule',
                              subtitle: "Today's plan, in time order",
                              onTap: () => Navigator.of(context).push(
                                WarriorPageRoute(
                                  builder: (_) => const ScheduleScreen(),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _QuickLinkCard(
                              icon: Icons.flag_outlined,
                              title: 'Challenges',
                              subtitle: 'Pick a challenge, stick to it',
                              onTap: () => Navigator.of(context).push(
                                WarriorPageRoute(
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
                          // Expanded so the heading wraps instead of
                          // overflowing on a narrow screen (or a wide
                          // font): it must never truncate. The pill
                          // stays pinned to the right edge.
                          const Expanded(
                            child: Text(
                              "Today's Habits",
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (_habitsList.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.ember.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                '$doneCount/$totalCount done',
                                style: const TextStyle(
                                  color: AppTheme.ember,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            children: [
                              SkeletonBox(height: 76, borderRadius: 20),
                              SizedBox(height: 12),
                              SkeletonBox(height: 76, borderRadius: 20),
                              SizedBox(height: 12),
                              SkeletonBox(height: 76, borderRadius: 20),
                            ],
                          ),
                        )
                      else if (_habitsList.isEmpty)
                        EmptyState(
                          icon: Icons.check_circle_outline,
                          title: 'No habits yet',
                          subtitle: 'Small steps, every day.',
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
                                      _HabitRow(
                                            habit: habit,
                                            done: done,
                                            strikeKey:
                                                _strikeKeys[habit.id] ?? 0,
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
                                _HabitRow(
                                      habit: habit,
                                      done: done,
                                      strikeKey: _strikeKeys[habit.id] ?? 0,
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
                            gradient: AppTheme.goldGradient,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.emoji_events,
                                color: AppTheme.ink,
                                size: 34,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'All done for today! Great work.',
                                  style: TextStyle(
                                    color: AppTheme.ink,
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
                AppTheme.ember,
                AppTheme.flame,
                AppTheme.gold,
                AppTheme.ember,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Header: greeting + date on the left; XP pill (tap → leaderboard),
/// streak pill and search on the right.
///
/// The XP pill is the way into the leaderboard now that it is no
/// longer a bottom tab (18 Nov 2026): tapping the XP number opens the
/// leaderboard screen.
class _Header extends StatelessWidget {
  const _Header({
    required this.displayName,
    required this.streak,
    required this.xp,
    required this.onXpTap,
    required this.onSearchTap,
  });

  final String displayName;
  final int streak;
  final int xp;
  final VoidCallback onXpTap;
  final VoidCallback onSearchTap;

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
    final day = dayOfYear(now);
    final left = daysLeftInYear(now);
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
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                displayName,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${months[now.month]} ${now.day}, ${now.year} • '
                'Day $day of the year • $left days left',
                style: const TextStyle(color: AppTheme.inkSoft, fontSize: 13),
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
                // XP pill — tap to open the leaderboard.
                Material(
                  color: AppTheme.card,
                  borderRadius: BorderRadius.circular(999),
                  child: InkWell(
                    onTap: onXpTap,
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.bolt,
                            color: AppTheme.gold,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$xp XP',
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: AppTheme.cardBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.local_fire_department,
                        color: AppTheme.flame,
                        size: 18,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$streak',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            IconButton(
              onPressed: onSearchTap,
              tooltip: 'Search people',
              icon: const Icon(Icons.search, color: AppTheme.inkSoft),
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      ],
    );
  }
}

/// Today's progress: a day progress line — how much of today's plan
/// is done, as a bar plus a count. The same line appears per day on
/// the Dashboard calendar (18 Nov 2026).
class _TodayProgressCard extends StatelessWidget {
  const _TodayProgressCard({
    required this.done,
    required this.total,
    required this.fraction,
  });

  final int done;
  final int total;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
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
              // Expanded so the title wraps instead of overflowing
              // on a narrow screen (or a wide font).
              const Expanded(
                child: Text(
                  "Today's progress",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              // The count pill is hidden when there are no habits: the
              // empty state below already says "No habits yet".
              if (total > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.ember.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$done of $total done',
                    style: const TextStyle(
                      color: AppTheme.ember,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: fraction),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 10,
                backgroundColor: AppTheme.cardBorder,
                valueColor: const AlwaysStoppedAnimation<Color>(
                  AppTheme.ember,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The line of the day: one motivational line, the same all day,
/// picked deterministically from the date (see logic/quotes.dart).
class _DailyLineCard extends StatelessWidget {
  const _DailyLineCard({required this.line});

  final String line;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        gradient: AppTheme.heroGradient,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome,
                color: AppTheme.ink.withValues(alpha: 0.7),
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                "TODAY'S THOUGHT",
                style: TextStyle(
                  color: AppTheme.ink.withValues(alpha: 0.9),
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
              Icon(
                Icons.format_quote,
                color: AppTheme.ink.withValues(alpha: 0.7),
                size: 26,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  line,
                  style: const TextStyle(
                    color: AppTheme.ink,
                    fontSize: 15,
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

/// A habit row: the check button is the big element on the LEFT
/// (tap it to tick/untick), then the title + status, then the alarm
/// and menu on the right. Done items stay fully readable: no
/// strikethrough — the filled check and the tinted row are the done
/// state.
class _HabitRow extends StatelessWidget {
  const _HabitRow({
    required this.habit,
    required this.done,
    required this.onToggle,
    required this.onEdit,
    required this.onAlarm,
    this.reminder,
    this.strikeKey = 0,
  });

  final Habit habit;
  final bool done;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onAlarm;
  final Reminder? reminder;

  /// Bumped on every completion — drives the slash sweep (see
  /// StrikeOverlay). 0 means "never completed yet".
  final int strikeKey;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => onToggle(!done),
        // Long-press opens the same edit dialog (rename / delete) that
        // Profile offers — a habit row must always have a delete path.
        onLongPress: onEdit,
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: done ? Colors.transparent : AppTheme.cardBorder,
                ),
                color: done ? AppTheme.ember.withValues(alpha: 0.07) : null,
              ),
              child: Row(
                children: [
                  BattleCheck(done: done, size: 36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          habit.title,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.ink,
                          ),
                        ),
                        Text(
                          done
                              ? 'Done • +$xpPerTask XP'
                              : 'Tap to complete • +$xpPerTask XP',
                          style: const TextStyle(
                            color: AppTheme.inkSoft,
                            fontSize: 12,
                          ),
                        ),
                        // Notes preview: the first line, with a note
                        // icon — the full note lives in the edit dialog.
                        if (habit.notes.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.sticky_note_2_outlined,
                                  color: AppTheme.inkSoft,
                                  size: 13,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    habit.notes.split('\n').first,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.inkSoft,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (reminder != null)
                          Text(
                            reminder!.enabled
                                ? 'Alarm ${formatReminderTime12h(reminder!.hour, reminder!.minute)}'
                                : 'Alarm off',
                            style: TextStyle(
                              color: reminder!.enabled
                                  ? AppTheme.ember
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
                          ? AppTheme.ember
                          : AppTheme.inkSoft,
                      size: 20,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
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
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            StrikeOverlay(strikeKey: strikeKey),
          ],
        ),
      ),
    );
  }
}

/// Compact quick-link card (Schedule / Challenges): icon on the left,
/// title + subtitle on the right, chevron at the end. Short and wide,
/// not the tall icon-on-top cards of v2.4.0.
class _QuickLinkCard extends StatelessWidget {
  const _QuickLinkCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: AppTheme.emberGradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: AppTheme.ink, size: 19),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
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
              // No chevron: on a narrow phone the chevron squeezed
              // the text column and broke "Schedule"/"Challenges"
              // mid-word ("Sched ule"). The whole card is tappable.
            ],
          ),
        ),
      ),
    );
  }
}
