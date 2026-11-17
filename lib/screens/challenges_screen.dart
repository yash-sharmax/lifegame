// Challenges (v2.3.0): list of challenges + create flow.
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
      if (habits.isEmpty) {
        showInfo(context, 'Add a habit first — a challenge needs habits.');
        return;
      }
      final created = await showCreateChallengeSheet(context, habits);
      if (created == null || !mounted) return;
      await _challenges.createChallenge(
        name: created.name,
        durationDays: created.durationDays,
        habits: created.habits,
      );
      await _load(silent: true);
      if (!mounted) return;
      showInfo(context, 'Challenge created — 3 days to set it up.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Challenges',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.transparent,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _create,
        icon: const Icon(Icons.add),
        label: const Text('New challenge'),
      ),
      body: ResponsiveCenter(
        maxWidth: 720,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () => _load(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.violet.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            color: AppTheme.violet,
                            size: 20,
                          ),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Pick your habits and a duration. You get 3 days to '
                              'change the habits — after that they lock for the '
                              'whole challenge. Daily habits outside a challenge '
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
                        icon: Icons.emoji_events_outlined,
                        title: 'No challenges yet',
                        subtitle:
                            'Start your first challenge — pick habits, set the days, and lock in.',
                        actionLabel: 'Create a challenge',
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
                                MaterialPageRoute(
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
        AppTheme.amber,
      ),
      ChallengePhase.active => ('Active — $remaining days left', AppTheme.teal),
      ChallengePhase.finished => ('Finished', AppTheme.inkSoft),
    };
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEDEAF5)),
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
                      gradient: AppTheme.violetGradient,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.emoji_events,
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
                          challenge.name,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${challenge.habits.length} habits • ${challenge.durationDays} days • $start to $end',
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
                  backgroundColor: const Color(0xFFEDEAF5),
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
/// (7/14/21/30 days or custom), habit multi-select.
Future<CreateChallengeResult?> showCreateChallengeSheet(
  BuildContext context,
  List<Habit> habits,
) async {
  final nameController = TextEditingController();
  var duration = 14;
  var customDays = '';
  final selected = <String>{};
  final customController = TextEditingController();

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
                'New challenge',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              const Text(
                '3 days to set up your habits — then they lock for the whole challenge.',
                style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Challenge name',
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
                'Habits in this challenge',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ...habits.map(
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
                          content: Text('Give your challenge a name.'),
                        ),
                      );
                      return;
                    }
                    if (selected.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Pick at least one habit.'),
                        ),
                      );
                      return;
                    }
                    Navigator.of(context).pop(
                      CreateChallengeResult(
                        name: name,
                        durationDays: days,
                        habits: habits
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
                  child: const Text('Create challenge'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
