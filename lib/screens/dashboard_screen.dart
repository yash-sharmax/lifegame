import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'auth_screen.dart';
import 'search_screen.dart';

/// Dashboard (v2.6.0, 18 Nov 2026): an Excel-sheet TABLE, not a list.
///
/// Habits run down one column, dates run across as columns, and each
/// cell is a small box — filled when that habit was done that day,
/// empty when it was not. The table is READ-ONLY (view only): ticking
/// happens on Home, never from here. Below the table: a pie chart
/// (done vs missed this month), a bar graph (completions per day),
/// and an XP breakdown — every +2 entry listed, so the total can be
/// counted by hand and checked against the XP shown on the profile.
///
/// A habit counts for a date only from its creation day onward
/// (nothing is "missed" before it existed).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.habitRepo, this.taskRepo, this.profileRepo});

  final HabitRepository? habitRepo;
  final TaskRepository? taskRepo;
  final ProfileRepository? profileRepo;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

/// One +2 XP entry in the ledger: which item, on which day.
class _LedgerEntry {
  const _LedgerEntry({
    required this.title,
    required this.kind,
    required this.dateLabel,
    required this.sortKey,
  });

  /// Habit or task title.
  final String title;

  /// 'Habit', 'Weekly task' or 'Monthly task'.
  final String kind;

  /// Human date label, e.g. "18 Nov 2026" or "Week of 17 Nov 2026".
  final String dateLabel;

  /// 'YYYY-MM-DD' (weekly tasks: their week start; monthly: the 1st),
  /// so entries sort newest-first.
  final String sortKey;
}

class _DashboardScreenState extends State<DashboardScreen> {
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();
  TaskRepository get _tasks => widget.taskRepo ?? TaskRepository();
  ProfileRepository get _profiles =>
      widget.profileRepo ?? ProfileRepository();

  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Habit> _habitsList = [];
  Map<String, Set<String>> _logsByDate = {};
  List<_LedgerEntry> _ledger = [];
  int _profileXp = 0;
  bool _loading = true;
  StreamSubscription<void>? _habitChanges;
  StreamSubscription<void>? _taskChanges;

  @override
  void initState() {
    super.initState();
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
    final firstLoad = _habitsList.isEmpty && _ledger.isEmpty;
    if (firstLoad) setState(() => _loading = true);
    try {
      final habits = await _habits.listMyHabits();
      final monthStart = DateTime(_month.year, _month.month, 1);
      final monthEnd = DateTime(_month.year, _month.month + 1, 0);
      final logs = await _habits.listLogsInRange(
        dateKey(monthStart),
        dateKey(monthEnd),
      );
      final profile = await _profiles.fetchMyProfile();
      // The ledger is derived from the same source as the XP rule:
      // every completed habit log + every done weekly/monthly task
      // is +2 XP, so the ledger total must equal the profile XP.
      final allLogs = await _habits.listAllCompletedLogs();
      final weeklyDone = await _tasks.listAllDoneWeeklyTasks();
      final monthlyDone = await _tasks.listAllDoneMonthlyTasks();
      if (!mounted) return;
      final byDate = <String, Set<String>>{};
      for (final log in logs) {
        (byDate[log.logDate] ??= <String>{}).add(log.habitId);
      }
      final titles = {for (final h in habits) h.id: h.title};
      final entries = <_LedgerEntry>[
        for (final log in allLogs)
          _LedgerEntry(
            title: titles[log.habitId] ?? 'Habit',
            kind: 'Habit',
            dateLabel: _prettyDate(log.logDate),
            sortKey: log.logDate,
          ),
        for (final task in weeklyDone)
          _LedgerEntry(
            title: task.title,
            kind: 'Weekly task',
            dateLabel: 'Week of ${_prettyDate(task.weekStart)}',
            sortKey: task.weekStart,
          ),
        for (final task in monthlyDone)
          _LedgerEntry(
            title: task.title,
            kind: 'Monthly task',
            dateLabel: _prettyMonth(task.month),
            sortKey: '${task.month}-01',
          ),
      ];
      // Newest first; same-day entries keep a stable order.
      entries.sort((a, b) {
        final byDateCmp = b.sortKey.compareTo(a.sortKey);
        if (byDateCmp != 0) return byDateCmp;
        return a.title.compareTo(b.title);
      });
      setState(() {
        _habitsList = habits;
        _logsByDate = byDate;
        _ledger = entries;
        _profileXp = profile?.xp ?? 0;
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

    // Month summary + chart data: days with at least one completion,
    // total completions, and per-day completion counts.
    var activeDays = 0;
    var totalDone = 0;
    var applicableDays = 0;
    final perDayDone = List<int>.filled(daysInMonth + 1, 0);
    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(_month.year, _month.month, day);
      if (date.isAfter(todayDate)) break;
      final applicable = _habitsFor(date);
      applicableDays += applicable.length;
      final done = (_logsByDate[dateKey(date)] ?? <String>{})
          .where((id) => applicable.any((h) => h.id == id))
          .length;
      perDayDone[day] = done;
      if (done > 0) activeDays++;
      totalDone += done;
    }
    final missed = (applicableDays - totalDone).clamp(0, 1000000);
    final ledgerTotal = _ledger.length * xpPerTask;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard', style: TextStyle(fontSize: 19)),
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
        child: _loading
            ? const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 40),
                child: Column(
                  children: [
                    SkeletonBox(height: 44, borderRadius: 12),
                    SizedBox(height: 10),
                    SkeletonBox(height: 120, borderRadius: 16),
                    SizedBox(height: 10),
                    SkeletonBox(height: 140, borderRadius: 16),
                  ],
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  children: [
                    // Month bar: previous / month name / next + Today.
                    Row(
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
                              fontSize: 18,
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
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '$activeDays days with activity • $totalDone habits done',
                          style: const TextStyle(
                            color: AppTheme.inkSoft,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    if (_habitsList.isEmpty)
                      const EmptyState(
                        icon: Icons.check_circle_outline,
                        title: 'No habits yet',
                        subtitle:
                            'Add a habit from Home and the table will fill in here.',
                      )
                    else ...[
                      _HabitTable(
                        month: _month,
                        daysInMonth: daysInMonth,
                        todayKey: today,
                        todayDate: todayDate,
                        habits: _habitsList,
                        logsByDate: _logsByDate,
                        habitsFor: _habitsFor,
                        perDayDone: perDayDone,
                      ).animate().fadeIn().slideY(begin: 0.05),
                      const SizedBox(height: 14),
                      _ChartsCard(
                        done: totalDone,
                        missed: missed,
                        perDayDone: perDayDone,
                        daysInMonth: daysInMonth,
                        month: _month,
                      ).animate().fadeIn(delay: 60.ms).slideY(begin: 0.05),
                    ],
                    const SizedBox(height: 14),
                    _XpLedgerCard(
                      entries: _ledger,
                      ledgerTotal: ledgerTotal,
                      profileXp: _profileXp,
                    ).animate().fadeIn(delay: 100.ms).slideY(begin: 0.05),
                  ],
                ),
              ),
      ),
    );
  }
}

/// "18 Nov 2026" from a 'YYYY-MM-DD' key.
String _prettyDate(String key) {
  final parts = key.split('-');
  if (parts.length != 3) return key;
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
  final month = int.tryParse(parts[1]) ?? 0;
  final day = int.tryParse(parts[2]) ?? 0;
  final year = parts[0];
  final name = month >= 1 && month <= 12 ? months[month] : parts[1];
  return '$day $name $year';
}

/// "November 2026" from a 'YYYY-MM' key.
String _prettyMonth(String key) {
  final parts = key.split('-');
  if (parts.length != 2) return key;
  final year = int.tryParse(parts[0]) ?? DateTime.now().year;
  final month = int.tryParse(parts[1]) ?? DateTime.now().month;
  return monthName(DateTime(year, month));
}

/// The Excel-style table: habits down one column, dates across, each
/// cell a small box — filled when done, empty when not. READ-ONLY:
/// there is no tap handler on the cells; ticking happens on Home.
class _HabitTable extends StatelessWidget {
  const _HabitTable({
    required this.month,
    required this.daysInMonth,
    required this.todayKey,
    required this.todayDate,
    required this.habits,
    required this.logsByDate,
    required this.habitsFor,
    required this.perDayDone,
  });

  final DateTime month;
  final int daysInMonth;
  final String todayKey;
  final DateTime todayDate;
  final List<Habit> habits;
  final Map<String, Set<String>> logsByDate;
  final List<Habit> Function(DateTime date) habitsFor;
  final List<int> perDayDone;

  static const double _nameWidth = 128;
  static const double _cellWidth = 30;
  static const double _cellSize = 20;

  static const List<String> _weekdayLetters = [
    'M',
    'T',
    'W',
    'T',
    'F',
    'S',
    'S',
  ];

  @override
  Widget build(BuildContext context) {
    final tableWidth = _nameWidth + _cellWidth * daysInMonth;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Habit table',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                ),
                const Icon(
                  Icons.visibility_outlined,
                  color: AppTheme.inkSoft,
                  size: 15,
                ),
                const SizedBox(width: 4),
                const Text(
                  'View only — tick from Home',
                  style: TextStyle(color: AppTheme.inkSoft, fontSize: 11),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: tableWidth,
              child: Column(
                children: [
                  // Header row: "Habit" + one column per date.
                  Row(
                    children: [
                      const SizedBox(
                        width: _nameWidth,
                        child: Padding(
                          padding: EdgeInsets.only(left: 14),
                          child: Text(
                            'Habit',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                              color: AppTheme.inkSoft,
                            ),
                          ),
                        ),
                      ),
                      for (var day = 1; day <= daysInMonth; day++)
                        _dateHeader(day),
                    ],
                  ),
                  const Divider(height: 1),
                  // One row per habit.
                  for (final habit in habits)
                    _habitRow(habit),
                  const Divider(height: 1),
                  // Footer: done count per day.
                  Row(
                    children: [
                      const SizedBox(
                        width: _nameWidth,
                        child: Padding(
                          padding: EdgeInsets.only(left: 14),
                          child: Text(
                            'Done',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                              color: AppTheme.inkSoft,
                            ),
                          ),
                        ),
                      ),
                      for (var day = 1; day <= daysInMonth; day++)
                        SizedBox(
                          width: _cellWidth,
                          child: Center(
                            child: Text(
                              _isFuture(day) ? '' : '${perDayDone[day]}',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: _isToday(day)
                                    ? AppTheme.ember
                                    : AppTheme.inkSoft,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isToday(int day) =>
      dateKey(DateTime(month.year, month.month, day)) == todayKey;

  bool _isFuture(int day) =>
      DateTime(month.year, month.month, day).isAfter(todayDate);

  Widget _dateHeader(int day) {
    final isToday = _isToday(day);
    final date = DateTime(month.year, month.month, day);
    return SizedBox(
      width: _cellWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$day',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isToday ? AppTheme.ember : AppTheme.ink,
            ),
          ),
          Text(
            _weekdayLetters[date.weekday - 1],
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: isToday ? AppTheme.ember : AppTheme.inkSoft,
            ),
          ),
        ],
      ),
    );
  }

  Widget _habitRow(Habit habit) {
    final gradient =
        AppTheme.habitGradients[habit.color % AppTheme.habitGradients.length];
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _nameWidth,
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 6),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: gradient,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      habit.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (var day = 1; day <= daysInMonth; day++)
            _cell(habit, day),
        ],
      ),
    );
  }

  Widget _cell(Habit habit, int day) {
    final date = DateTime(month.year, month.month, day);
    final key = dateKey(date);
    final applicable =
        habit.createdAt == null || dateKey(habit.createdAt!).compareTo(key) <= 0;
    final done = applicable && (logsByDate[key]?.contains(habit.id) ?? false);
    final isFuture = date.isAfter(todayDate);
    return SizedBox(
      width: _cellWidth,
      child: Center(
        child: Container(
          width: _cellSize,
          height: _cellSize,
          decoration: BoxDecoration(
            color: done ? null : Colors.transparent,
            gradient: done ? AppTheme.emberGradient : null,
            borderRadius: BorderRadius.circular(6),
            border: done || !applicable || isFuture
                ? null
                : Border.all(color: AppTheme.cardBorder, width: 1.5),
          ),
          child: done
              ? const Icon(Icons.check, color: AppTheme.ink, size: 13)
              : null,
        ),
      ),
    );
  }
}

/// Pie chart (done vs missed this month) + bar graph (completions
/// per day), side by side on wide screens, stacked on phones.
class _ChartsCard extends StatelessWidget {
  const _ChartsCard({
    required this.done,
    required this.missed,
    required this.perDayDone,
    required this.daysInMonth,
    required this.month,
  });

  final int done;
  final int missed;
  final List<int> perDayDone;
  final int daysInMonth;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final total = done + missed;
    final pct = total == 0 ? 0.0 : done / total * 100;
    final maxDone = perDayDone.fold<int>(0, (m, v) => v > m ? v : m);
    final pie = SizedBox(
      height: 168,
      child: Row(
        children: [
          SizedBox(
            width: 132,
            height: 132,
            child: Stack(
              alignment: Alignment.center,
              children: [
                PieChart(
                  PieChartData(
                    startDegreeOffset: -90,
                    sectionsSpace: 1,
                    centerSpaceRadius: 34,
                    sections: total == 0
                        ? [
                            PieChartSectionData(
                              value: 1,
                              color: AppTheme.cardBorder,
                              showTitle: false,
                              radius: 16,
                            ),
                          ]
                        : [
                            PieChartSectionData(
                              value: done.toDouble(),
                              color: AppTheme.ember,
                              showTitle: false,
                              radius: 16,
                            ),
                            if (missed > 0)
                              PieChartSectionData(
                                value: missed.toDouble(),
                                color: AppTheme.cardBorder,
                                showTitle: false,
                                radius: 16,
                              ),
                          ],
                  ),
                ),
                Text(
                  '${pct.toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _legendDot(AppTheme.ember, 'Done — $done'),
                const SizedBox(height: 8),
                _legendDot(AppTheme.cardBorder, 'Missed — $missed'),
                const SizedBox(height: 8),
                const Text(
                  'This month',
                  style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final bars = SizedBox(
      height: 168,
      child: BarChart(
        BarChartData(
          alignment: BarChartAlignment.spaceAround,
          maxY: (maxDone + 1).toDouble(),
          minY: 0,
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => AppTheme.card,
              getTooltipItem: (group, _, rod, _) => BarTooltipItem(
                'Day ${group.x}: ${rod.toY.toInt()} done',
                const TextStyle(
                  color: AppTheme.ink,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 20,
                interval: 1,
                getTitlesWidget: (value, _) => Text(
                  value.toInt().toString(),
                  style: const TextStyle(
                    color: AppTheme.inkSoft,
                    fontSize: 10,
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 5,
                getTitlesWidget: (value, _) {
                  final day = value.toInt();
                  if (day < 1 || day > daysInMonth) {
                    return const SizedBox.shrink();
                  }
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '$day',
                      style: const TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 10,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barGroups: [
            for (var day = 1; day <= daysInMonth; day++)
              BarChartGroupData(
                x: day,
                barRods: [
                  BarChartRodData(
                    toY: perDayDone[day].toDouble(),
                    color: dateKey(DateTime(month.year, month.month, day)) ==
                            dateKey(DateTime.now())
                        ? AppTheme.flame
                        : AppTheme.ember,
                    width: 10,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This month',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          const Text(
            'How much got done, and when.',
            style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 560) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: pie),
                    const SizedBox(width: 16),
                    Expanded(child: bars),
                  ],
                );
              }
              return Column(children: [pie, const SizedBox(height: 8), bars]);
            },
          ),
        ],
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// XP breakdown / ledger: every +2 entry listed (habit or task, with
/// its date), newest first, so the total can be counted by hand.
/// The total is entries × 2 XP and must equal the XP on the profile.
class _XpLedgerCard extends StatelessWidget {
  const _XpLedgerCard({
    required this.entries,
    required this.ledgerTotal,
    required this.profileXp,
  });

  final List<_LedgerEntry> entries;
  final int ledgerTotal;
  final int profileXp;

  @override
  Widget build(BuildContext context) {
    // The ledger shows the latest entries; the total always counts all.
    const shownLimit = 100;
    final shown = entries.length > shownLimit
        ? entries.sublist(0, shownLimit)
        : entries;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'XP breakdown',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.gold.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Total $ledgerTotal XP',
                  style: const TextStyle(
                    color: AppTheme.gold,
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${entries.length} entries × $xpPerTask XP = $ledgerTotal XP',
            style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
          ),
          if (profileXp != ledgerTotal) ...[
            const SizedBox(height: 4),
            Text(
              'Your profile shows $profileXp XP — the ledger above is the true count and will match after the next sync.',
              style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          if (entries.isEmpty)
            const Text(
              'No XP yet — complete a habit or a task and it will show up here.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
            )
          else
            ...shown.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.ember.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '+$xpPerTask XP',
                        style: TextStyle(
                          color: AppTheme.ember,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      entry.dateLabel,
                      style: const TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (entries.length > shownLimit)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Showing the latest $shownLimit of ${entries.length} entries.',
                style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
