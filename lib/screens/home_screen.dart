import 'package:confetti/confetti.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/quotes.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';

/// Home: greeting, quote, streak + XP, today's habits.
/// The screen the user opens every day to tick things off.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.habitRepo, this.profileRepo});

  final HabitRepository? habitRepo;
  final ProfileRepository? profileRepo;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();
  ProfileRepository get _profiles =>
      widget.profileRepo ?? ProfileRepository();

  List<Habit> _habitsList = [];
  Set<String> _doneToday = {};
  Profile? _profile;
  bool _loading = true;
  late final ConfettiController _confetti;

  String get _today => todayKey();

  @override
  void initState() {
    super.initState();
    _confetti = ConfettiController(duration: const Duration(seconds: 2));
    _load();
  }

  @override
  void dispose() {
    _confetti.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final habits = await _habits.listMyHabits();
      final logs = await _habits.listLogsForDate(_today);
      final profile = await _profiles.fetchMyProfile();
      if (!mounted) return;
      setState(() {
        _habitsList = habits;
        _doneToday = logs.map((l) => l.habitId).toSet();
        _profile = profile;
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
    try {
      final wasAllDone = _allDone;
      final result = await _habits.toggleHabit(
        habit: habit,
        date: _today,
        completed: value,
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      if (result.bonusGranted && !wasAllDone) {
        _confetti.play();
        showInfo(context, 'Day complete! +${result.xpDelta} XP. Legendary!');
      } else if (value) {
        showInfo(context, '+$xpPerHabit XP — nice one!');
      }
      // Confetti also fires when the day becomes complete even if the
      // bonus was already granted earlier (e.g. after an untick).
      if (result.allDone && !wasAllDone && !result.bonusGranted) {
        _confetti.play();
      }
    } on AuthException catch (e) {
      if (mounted) showError(context, e);
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

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
            children: [
              _Header(
                displayName: profile?.displayName ?? 'Player',
                streak: streak,
              ).animate().fadeIn().slideY(begin: -0.1),
              const SizedBox(height: 16),
              _QuoteCard(
                quote: quoteForDay(),
              ).animate().fadeIn(delay: 80.ms).slideY(begin: 0.1),
              const SizedBox(height: 16),
              XpBar(xp: xp).animate().fadeIn(delay: 140.ms).slideY(begin: 0.1),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text(
                    "Today's habits",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
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
                  subtitle:
                      'No habits yet. Add your first one — small steps, big change.',
                  actionLabel: 'Add your first habit',
                  onAction: _addHabit,
                )
              else
                ..._habitsList.asMap().entries.map((entry) {
                  final habit = entry.value;
                  final done = _doneToday.contains(habit.id);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _HabitTile(
                      habit: habit,
                      done: done,
                      onToggle: (v) => _toggle(habit, v),
                    ).animate().fadeIn(delay: (60 * entry.key).ms).slideX(begin: 0.08),
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
                      Icon(Icons.emoji_events, color: Colors.white, size: 34),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Day complete! Every habit ticked. +50 XP bonus earned.',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ],
                  ),
                ).animate().fadeIn().scale(begin: const Offset(0.95, 0.95)),
              ],
            ],
          ),
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
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
              const Text(
                ' streak',
                style: TextStyle(
                  color: AppTheme.inkSoft,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _QuoteCard extends StatelessWidget {
  const _QuoteCard({required this.quote});

  final String quote;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: AppTheme.heroGradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const Icon(Icons.format_quote, color: Colors.white70, size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              quote,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
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
  });

  final Habit habit;
  final bool done;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final gradient = AppTheme.habitGradients[habit.color % AppTheme.habitGradients.length];
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      elevation: 0,
      child: InkWell(
        onTap: () => onToggle(!done),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: done
                  ? Colors.transparent
                  : const Color(0xFFEDEAF5),
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
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        decoration: done
                            ? TextDecoration.lineThrough
                            : null,
                        color: done ? AppTheme.inkSoft : AppTheme.ink,
                      ),
                    ),
                    Text(
                      done ? 'Done • +$xpPerHabit XP' : 'Tap to complete • +$xpPerHabit XP',
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
