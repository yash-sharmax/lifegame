// Challenge detail (v2.3.0): status, progress, locked habits with
// today's check-ins, and the leaderboard.
//
// Check-ins reuse the normal habit toggles (+2 XP per completion,
// -2 on untick) — challenge XP is computed from the existing habit
// logs inside the active window, never from a second XP system.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';

import '../data/challenge_repository.dart';
import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/challenges.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';

class ChallengeDetailScreen extends StatefulWidget {
  const ChallengeDetailScreen({
    super.key,
    required this.challengeId,
    this.challengeRepo,
    this.habitRepo,
  });

  final String challengeId;
  final ChallengeRepository? challengeRepo;
  final HabitRepository? habitRepo;

  @override
  State<ChallengeDetailScreen> createState() => _ChallengeDetailScreenState();
}

class _ChallengeDetailScreenState extends State<ChallengeDetailScreen> {
  ChallengeRepository get _challenges =>
      widget.challengeRepo ?? ChallengeRepository();
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();

  Challenge? _challenge;
  ChallengeStats? _stats;
  List<ChallengeLeaderboardEntry> _leaderboard = [];
  List<Habit> _myHabits = [];
  Set<String> _doneToday = {};
  bool _loading = true;
  final Set<String> _toggling = {};
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = ChallengeRepository.onChanged.listen((_) {
      if (mounted) _load(silent: true);
    });
    _load();
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final challenge = await _challenges.getChallenge(widget.challengeId);
      if (challenge == null) {
        if (mounted) Navigator.of(context).pop();
        return;
      }
      final stats = await _challenges.statsFor(challenge);
      final board = await _challenges.leaderboardFor(challenge);
      final habits = await _habits.listMyHabits();
      final logs = await _habits.listLogsForDate(todayKey());
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _stats = stats;
        _leaderboard = board;
        _myHabits = habits;
        _doneToday = logs.map((l) => l.habitId).toSet();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  Future<void> _toggle(ChallengeHabitEntry entry, bool value) async {
    final habit = _myHabits.where((h) => h.id == entry.habitId).firstOrNull;
    if (habit == null) return;
    if (_toggling.contains(entry.habitId)) return;
    final wasDone = _doneToday.contains(entry.habitId);
    setState(() {
      if (value) {
        _doneToday.add(entry.habitId);
      } else {
        _doneToday.remove(entry.habitId);
      }
    });
    _toggling.add(entry.habitId);
    try {
      await _habits.toggleHabit(
        habit: habit,
        date: todayKey(),
        completed: value,
      );
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          if (wasDone) {
            _doneToday.add(entry.habitId);
          } else {
            _doneToday.remove(entry.habitId);
          }
        });
        showError(context, e);
      }
    } finally {
      _toggling.remove(entry.habitId);
    }
  }

  Future<void> _editHabits() async {
    final challenge = _challenge;
    if (challenge == null) return;
    final selected = challenge.habitIds.toSet();
    final result = await showDialog<List<ChallengeHabitEntry>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          title: const Text('Challenge habits'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: _myHabits
                  .map(
                    (habit) => CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(habit.title),
                      value: selected.contains(habit.id),
                      onChanged: (v) => setDialogState(() {
                        if (v == true) {
                          selected.add(habit.id);
                        } else {
                          selected.remove(habit.id);
                        }
                      }),
                    ),
                  )
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _myHabits
                    .where((h) => selected.contains(h.id))
                    .map(
                      (h) => ChallengeHabitEntry(habitId: h.id, title: h.title),
                    )
                    .toList(),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    try {
      await _challenges.updateHabits(challenge, result);
      await _load(silent: true);
      if (mounted) showInfo(context, 'Challenge habits updated.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete() async {
    final challenge = _challenge;
    if (challenge == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete challenge?'),
        content: Text(
          '“${challenge.name}” will be removed. Your habits and XP stay as they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _challenges.deleteChallenge(challenge.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final challenge = _challenge;
    final stats = _stats;
    if (_loading || challenge == null) {
      return Scaffold(
        appBar: AppBar(backgroundColor: Colors.transparent),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final phase = challengePhase(
      createdDate: challenge.createdDate,
      durationDays: challenge.durationDays,
    );
    final locked = challengeHabitsLocked(createdDate: challenge.createdDate);
    final remaining = challengeDaysRemaining(
      createdDate: challenge.createdDate,
      durationDays: challenge.durationDays,
    );
    final progress = challengeProgress(
      createdDate: challenge.createdDate,
      durationDays: challenge.durationDays,
    );
    final start = challengeStartDate(challenge.createdDate);
    final end = challengeEndDate(
      challenge.createdDate,
      challenge.durationDays,
    );
    final setupEnd = challengeSetupEndDate(challenge.createdDate);
    final phaseLabel = switch (phase) {
      ChallengePhase.setup =>
        'Setup — habits lock on $start (${daysBetweenKeys(todayKey(), start)} days left to edit)',
      ChallengePhase.active => 'Active — $remaining days left',
      ChallengePhase.finished => 'Finished on $end',
    };
    final doneTodayCount = challenge.habits
        .where((h) => _doneToday.contains(h.habitId))
        .length;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          challenge.name,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            onPressed: _delete,
            tooltip: 'Delete challenge',
            icon: const Icon(Icons.delete_outline, color: Colors.red),
          ),
        ],
      ),
      body: ResponsiveCenter(
        maxWidth: 720,
        child: RefreshIndicator(
          onRefresh: () => _load(),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: AppTheme.heroGradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  children: [
                    ProgressRing(
                      fraction: progress,
                      size: 110,
                      centerLabel: phase == ChallengePhase.finished
                          ? 'done'
                          : 'complete',
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            phaseLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            phase == ChallengePhase.setup
                                ? 'Setup ends $setupEnd • Challenge runs $start to $end'
                                : '$start to $end • ${challenge.durationDays} days',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${stats?.xp ?? 0} challenge XP • ${stats?.streak ?? 0}-day streak • ${stats?.daysCompleted ?? 0} days completed',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text(
                    'Locked habits',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const Spacer(),
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
                      '$doneTodayCount/${challenge.habits.length} done today',
                      style: const TextStyle(
                        color: AppTheme.violet,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                locked
                    ? 'Habits are locked — no changes during the challenge.'
                    : 'You can still change these habits until the setup window ends.',
                style: const TextStyle(color: AppTheme.inkSoft, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ...challenge.habits.map((entry) {
                final habit = _myHabits
                    .where((h) => h.id == entry.habitId)
                    .firstOrNull;
                final done = _doneToday.contains(entry.habitId);
                final gone = habit == null;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      onTap: gone || phase == ChallengePhase.finished
                          ? null
                          : () => _toggle(entry, !done),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: done
                                ? Colors.transparent
                                : const Color(0xFFEDEAF5),
                          ),
                          color: done
                              ? AppTheme.violet.withValues(alpha: 0.06)
                              : null,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                gradient: AppTheme.tealGradient,
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
                                    entry.title,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.ink,
                                    ),
                                  ),
                                  Text(
                                    gone
                                        ? 'Habit removed — kept here for history'
                                        : done
                                        ? 'Done today • +$xpPerTask XP'
                                        : 'Tap to complete • +$xpPerTask XP',
                                    style: const TextStyle(
                                      color: AppTheme.inkSoft,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
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
                                    : Border.all(
                                        color: const Color(0xFFD8D2EA),
                                        width: 2,
                                      ),
                              ),
                              child: done
                                  ? const Icon(
                                      Icons.check,
                                      color: Colors.white,
                                      size: 20,
                                    )
                                  : null,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
              if (!locked) ...[
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: _editHabits,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Edit challenge habits'),
                ),
              ],
              const SizedBox(height: 20),
              const Text(
                'Challenge leaderboard',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                'Ranked by XP earned on the challenge habits during the challenge.',
                style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
              ),
              const SizedBox(height: 12),
              Card(
                child: Column(
                  children: [
                    for (final entry in _leaderboard)
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: AppTheme.violet.withValues(
                            alpha: 0.12,
                          ),
                          child: Text(
                            '#${entry.rank}',
                            style: const TextStyle(
                              color: AppTheme.violet,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        title: Text(
                          entry.displayName,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        trailing: Text(
                          '${entry.xp} XP',
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    const Divider(height: 1),
                    const ListTile(
                      leading: Icon(Icons.info_outline, color: AppTheme.violet),
                      title: Text(
                        'Solo challenge — only your XP shows here for now.',
                        style: TextStyle(
                          color: AppTheme.inkSoft,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
