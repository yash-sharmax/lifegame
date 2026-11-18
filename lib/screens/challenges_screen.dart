// Challenges (v2.4.0): list of challenges + create flow.
//
// A challenge is a named, time-boxed commitment over a fixed set of
// habits. The first 3 days after creation are the setup window —
// habits can still change. After that the habits lock for the whole
// challenge duration. Daily habits outside a challenge stay fully
// flexible: add or remove them any time.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/challenge_repository.dart';
import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/challenges.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/habit_dialog.dart';
import 'auth_screen.dart';
import 'challenge_detail_screen.dart';

class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({
    super.key,
    this.challengeRepo,
    this.habitRepo,
  });

  final ChallengeRepository? challengeRepo;
  final HabitRepository? habitRepo;

  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

class _ChallengesScreenState extends State<ChallengesScreen> {
  ChallengeRepository get _challenges =>
      widget.challengeRepo ?? ChallengeRepository();
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();

  List<Challenge> _list = [];
  bool _loading = true;
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
      final list = await _challenges.listMyChallenges();
      if (!mounted) return;
      setState(() {
        _list = list;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  Future<void> _create() async {
    try {
      final habits = await _habits.listMyHabits();
      if (!mounted) return;
      // No "add a habit first" gate: the sheet itself lets the user
      // create a habit inline (18 Nov 2026), so a challenge can start
      // from zero habits.
      final created = await showCreateChallengeSheet(
        context,
        habits,
        habitRepo: _habits,
      );
      if (created == null || !mounted) return;
      await _challenges.createChallenge(
        name: created.name,
        durationDays: created.durationDays,
        habits: created.habits,
      );
      await _load(silent: true);
      if (!mounted) return;
      showInfo(context, 'Campaign started — 3 days to set it up.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Campaigns',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.transparent,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New campaign'),
      ),
      body: ResponsiveCenter(
        maxWidth: 720,
        child: _loading
            ? ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                children: const [
                  SkeletonBox(height: 86, borderRadius: 16),
                  SizedBox(height: 20),
                  SkeletonBox(height: 130, borderRadius: 20),
                  SizedBox(height: 12),
                  SkeletonBox(height: 130, borderRadius: 20),
                ],
              )
            : RefreshIndicator(
                onRefresh: () => _load(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.ember.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppTheme.ember,
                            size: 20,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Choose your battles and a duration. You get 3 days to '
                              'change the battles — after that they lock for the '
                              'whole campaign. Daily battles outside a campaign '
                              'can still change any time.',
                              style: TextStyle(
                                color: AppTheme.inkSoft,
                                fontSize: 13,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_list.isEmpty)
                      EmptyState(
                        icon: Icons.flag_outlined,
                        title: 'No campaigns yet',
                        subtitle:
                            'Start your first campaign — pick battles, set the days, and lock in.',
                        actionLabel: 'Start a campaign',
                        onAction: _create,
                      )
                    else
                      ..._list.asMap().entries.map((entry) {
                        final challenge = entry.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ChallengeCard(
                            challenge: challenge,
                            onTap: () async {
                              await Navigator.of(context).push(
                                WarriorPageRoute(
                                  builder: (_) => ChallengeDetailScreen(
                                    challengeId: challenge.id,
                                  ),
                                ),
                              );
                              if (mounted) _load(silent: true);
                            },
                          ).animate().fadeIn(delay: (60 * entry.key).ms),
                        );
                      }),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ChallengeCard extends StatelessWidget {
  const _ChallengeCard({required this.challenge, required this.onTap});

  final Challenge challenge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final phase = challengePhase(
      createdDate: challenge.createdDate,
      durationDays: challenge.durationDays,
    );
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
    final (badgeLabel, badgeColor) = switch (phase) {
      ChallengePhase.setup => (
        'Setup — locks in ${daysBetweenKeys(todayKey(), start)}d',
        AppTheme.gold,
      ),
      ChallengePhase.active => ('Active — $remaining days left', AppTheme.ember),
      ChallengePhase.finished => ('Finished', AppTheme.inkSoft),
    };
    return Material(
      color: AppTheme.card,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: AppTheme.emberGradient,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.flag,
                      color: AppTheme.ink,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          challenge.name,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${challenge.habits.length} battles • ${challenge.durationDays} days • $start to $end',
                          style: const TextStyle(
                            color: AppTheme.inkSoft,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right,
                    color: AppTheme.inkSoft,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 8,
                  backgroundColor: AppTheme.ember.withValues(alpha: 0.18),
                  valueColor: AlwaysStoppedAnimation<Color>(badgeColor),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeLabel,
                  style: TextStyle(
                    color: badgeColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Result of the create sheet: name + duration + picked habits.
class CreateChallengeResult {
  const CreateChallengeResult({
    required this.name,
    required this.durationDays,
    required this.habits,
  });

  final String name;
  final int durationDays;
  final List<ChallengeHabitEntry> habits;
}

/// Bottom sheet to create a challenge: name, duration picker
/// (7/14/21/30 days or custom), habit multi-select — plus an inline
/// "Add a new habit" row (18 Nov 2026): the user is not limited to
/// picking existing habits. A habit created here is added to the list
/// and auto-selected immediately.
Future<CreateChallengeResult?> showCreateChallengeSheet(
  BuildContext context,
  List<Habit> habits, {
  required HabitRepository habitRepo,
}) async {
  final nameController = TextEditingController();
  var duration = 14;
  var customDays = '';
  final selected = <String>{};
  final customController = TextEditingController();
  // Local copy: the sheet can grow it when the user adds a habit.
  final sheetHabits = List<Habit>.from(habits);

  return showModalBottomSheet<CreateChallengeResult>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'New campaign',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                '3 days to set up your battles — then they lock for the whole campaign.',
                style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Campaign name',
                  hintText: 'e.g. 14-Day Focus',
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Duration',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final days in challengeDurationOptions)
                    ChoiceChip(
                      label: Text('$days days'),
                      selected: duration == days && customDays.isEmpty,
                      onSelected: (_) => setSheetState(() {
                        duration = days;
                        customDays = '';
                      }),
                    ),
                  ChoiceChip(
                    label: const Text('Custom'),
                    selected: customDays.isNotEmpty,
                    onSelected: (_) => setSheetState(() {
                      customDays = customController.text;
                    }),
                  ),
                ],
              ),
              if (customDays.isNotEmpty) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: customController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Days (1–365)',
                    hintText: 'e.g. 10',
                  ),
                  onChanged: (v) => setSheetState(() => customDays = v),
                ),
              ],
              const SizedBox(height: 18),
              const Text(
                'Battles in this campaign',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              if (sheetHabits.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No battles yet — add one below to start your first campaign.',
                    style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
                  ),
                ),
              ...sheetHabits.map(
                (habit) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(habit.title),
                  value: selected.contains(habit.id),
                  onChanged: (v) => setSheetState(() {
                    if (v == true) {
                      selected.add(habit.id);
                    } else {
                      selected.remove(habit.id);
                    }
                  }),
                ),
              ),
              const SizedBox(height: 4),
              OutlinedButton.icon(
                onPressed: () async {
                  final added = await showAddHabitDialog(context);
                  if (added == null) return;
                  try {
                    final habit = await habitRepo.addHabit(
                      title: added.title,
                      color: added.color,
                    );
                    setSheetState(() {
                      sheetHabits.add(habit);
                      selected.add(habit.id);
                    });
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add a new habit'),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final name = nameController.text.trim();
                    var days = duration;
                    if (customDays.isNotEmpty) {
                      final parsed = int.tryParse(customDays);
                      if (parsed == null || parsed < 1 || parsed > 365) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Custom days must be a number between 1 and 365.',
                            ),
                          ),
                        );
                        return;
                      }
                      days = parsed;
                    }
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Give your campaign a name.'),
                        ),
                      );
                      return;
                    }
                    if (selected.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Pick at least one battle.'),
                        ),
                      );
                      return;
                    }
                    Navigator.of(context).pop(
                      CreateChallengeResult(
                        name: name,
                        durationDays: days,
                        habits: sheetHabits
                            .where((h) => selected.contains(h.id))
                            .map(
                              (h) => ChallengeHabitEntry(
                                habitId: h.id,
                                title: h.title,
                              ),
                            )
                            .toList(),
                      ),
                    );
                  },
                  child: const Text('Start campaign'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
