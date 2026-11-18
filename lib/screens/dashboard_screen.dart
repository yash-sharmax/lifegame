import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';
import 'search_screen.dart';

/// Dashboard: a calendar, like the habit-tracker sheet (18 Nov 2026).
///
/// The month name sits at the top, each date is a row, and under each
/// date are that day's habits (done or not) with a day progress line
/// showing how much of the day was completed. The calendar reads the
/// real habit_logs, so a date shows what was actually done that day.
/// A habit counts for a date only from its creation day onward
/// (nothing is "missed" before it existed).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.habitRepo});

  final HabitRepository? habitRepo;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Habit> _habitsList = [];
  Map<String, Set<String>> _logsByDate = {};
  bool _loading = true;
  StreamSubscription<void>? _habitChanges;

  @override
  void initState() {
    super.initState();
    _habitChanges = HabitRepository.onChanged.listen((_) {
      if (mounted) _load();
    });
    _load();
  }

  @override
  void dispose() {
    _habitChanges?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final firstLoad = _habitsList.isEmpty;
    if (firstLoad) setState(() => _loading = true);
    try {
      final habits = await _habits.listMyHabits();
      final monthStart = DateTime(_month.year, _month.month, 1);
      final monthEnd = DateTime(_month.year, _month.month + 1, 0);
      final logs = await _habits.listLogsInRange(
        dateKey(monthStart),
        dateKey(monthEnd),
      );
      if (!mounted) return;
      final byDate = <String, Set<String>>{};
      for (final log in logs) {
        (byDate[log.logDate] ??= <String>{}).add(log.habitId);
      }
      setState(() {
        _habitsList = habits;
        _logsByDate = byDate;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _loading = true;
    });
    _load();
  }

  void _goToday() {
    final now = DateTime.now();
    setState(() {
      _month = DateTime(now.year, now.month);
      _loading = true;
    });
    _load();
  }

  /// Habits that existed on [date]: a habit counts from its creation
  /// day onward (null createdAt = always counts, for legacy rows).
  List<Habit> _habitsFor(DateTime date) {
    final key = dateKey(date);
    return _habitsList
        .where(
          // Date keys are zero-padded 'yyyy-MM-dd', so lexicographic
          // order is chronological order.
          (h) => h.createdAt == null || dateKey(h.createdAt!).compareTo(key) <= 0,
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = dateKey(now);
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final isCurrentMonth =
        _month.year == now.year && _month.month == now.month;
    final todayDate = DateTime(now.year, now.month, now.day);

    // Month summary: days with at least one completion + total
    // completions in the visible month.
    var activeDays = 0;
    var totalDone = 0;
    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_month.year, _month.month, day);
      if (date.isAfter(todayDate)) break;
      final applicable = _habitsFor(date);
      final done = (_logsByDate[dateKey(date)] ?? <String>{})
          .where((id) => applicable.any((h) => h.id == id))
          .length;
      if (done > 0) activeDays++;
      totalDone += done;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push(
              WarriorPageRoute(builder: (_) => const SearchScreen()),
            ),
            tooltip: 'Search people',
            icon: const Icon(Icons.search),
          ),
        ],
      ),
      body: ResponsiveCenter(
        maxWidth: 980,
        child: Column(
          children: [
            // Month bar: previous / month name / next + Today.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => _changeMonth(-1),
                    tooltip: 'Previous month',
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      monthName(_month),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _changeMonth(1),
                    tooltip: 'Next month',
                    icon: const Icon(Icons.chevron_right),
                  ),
                  TextButton(
                    onPressed: isCurrentMonth ? null : _goToday,
                    child: const Text('Today'),
                  ),
                ],
              ),
            ),
            // Small month summary (not big stat cards — the calendar
            // is the main content).
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$activeDays days with activity • $totalDone habits done',
                  style: const TextStyle(
                    color: AppTheme.inkSoft,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 100),
                      child: Column(
                        children: [
                          SkeletonBox(height: 72, borderRadius: 16),
                          SizedBox(height: 10),
                          SkeletonBox(height: 72, borderRadius: 16),
                          SizedBox(height: 10),
                          SkeletonBox(height: 72, borderRadius: 16),
                          SizedBox(height: 10),
                          SkeletonBox(height: 72, borderRadius: 16),
                        ],
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                        itemCount: daysInMonth,
                        itemBuilder: (context, index) {
                          final day = index + 1;
                          final date = DateTime(
                            _month.year,
                            _month.month,
                            day,
                          );
                          final key = dateKey(date);
                          final isToday = key == today;
                          final isFuture = date.isAfter(todayDate);
                          final applicable = _habitsFor(date);
                          final doneIds = _logsByDate[key] ?? <String>{};
                          final doneCount = applicable
                              .where((h) => doneIds.contains(h.id))
                              .length;
                          return _DayRow(
                            date: date,
                            isToday: isToday,
                            isFuture: isFuture,
                            habits: applicable,
                            doneIds: doneIds,
                            doneCount: doneCount,
                          ).animate().fadeIn(delay: (20 * index).ms);
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One calendar row: the date number + weekday on the left, that
/// day's habits and the day progress line on the right. Only the
/// date number and the weekday are shown — no month/year (18 Nov
/// 2026).
class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.date,
    required this.isToday,
    required this.isFuture,
    required this.habits,
    required this.doneIds,
    required this.doneCount,
  });

  final DateTime date;
  final bool isToday;
  final bool isFuture;
  final List<Habit> habits;
  final Set<String> doneIds;
  final int doneCount;

  static const List<String> _weekdays = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  @override
  Widget build(BuildContext context) {
    final total = habits.length;
    final fraction = total == 0 ? 0.0 : doneCount / total;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        color: isToday
            ? AppTheme.ember.withValues(alpha: 0.08)
            : AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isToday ? AppTheme.ember : AppTheme.cardBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Date: number + weekday only.
          SizedBox(
            width: 44,
            child: Column(
              children: [
                Text(
                  '${date.day}',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: isToday ? AppTheme.ember : AppTheme.ink,
                  ),
                ),
                Text(
                  _weekdays[date.weekday - 1],
                  style: TextStyle(
                    color: isToday ? AppTheme.ember : AppTheme.inkSoft,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (habits.isEmpty)
                  const Text(
                    'No habits',
                    style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
                  )
                else
                  ...habits.map((habit) {
                    final done = doneIds.contains(habit.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Icon(
                            done
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            size: 18,
                            color: done
                                ? AppTheme.ember
                                : AppTheme.inkSoft,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              habit.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isFuture
                                    ? AppTheme.inkSoft
                                    : done
                                    ? AppTheme.ink
                                    : AppTheme.inkSoft,
                              ),
                            ),
                          ),
                          if (done)
                            const Text(
                              'Done',
                              style: TextStyle(
                                color: AppTheme.ember,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                        ],
                      ),
                    );
                  }),
                // Day progress line (past + today only).
                if (!isFuture && total > 0) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(999),
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 6,
                            backgroundColor: AppTheme.cardBorder,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppTheme.ember,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$doneCount/$total done',
                        style: const TextStyle(
                          color: AppTheme.inkSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
