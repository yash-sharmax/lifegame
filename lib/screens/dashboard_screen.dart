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

/// Dashboard (v2.7.0, 18 Nov 2026): an Excel-sheet TABLE, not a list,
/// plus full analytics — pie chart, bar graph, line graph, daily pace
/// and a daily score.
///
/// Habits run down one column, dates run across as columns, and each
/// cell is a small box — filled when that habit was done that day,
/// empty when it was not. The table is READ-ONLY (view only): ticking
/// happens on Home, never from here.
///
/// The Daily / Weekly / Monthly switcher changes what the table and
/// the charts show: Daily = one day in detail (today's score card,
/// per-habit bars, 7-day trend line); Weekly = the Monday–Sunday week
/// containing the shown day; Monthly = the whole month (the old view).
/// Below the charts: an XP breakdown — every +2 entry listed, so the
/// total can be counted by hand and checked against the XP shown on
/// the profile.
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

/// The three analytics periods on the Dashboard.
enum _DashboardPeriod { daily, weekly, monthly }

extension on _DashboardPeriod {
  String get label => switch (this) {
    _DashboardPeriod.daily => 'Daily',
    _DashboardPeriod.weekly => 'Weekly',
    _DashboardPeriod.monthly => 'Monthly',
  };
}

/// X-axis label for a chart point on [day] of a [dayCount]-day axis.
///
/// Monthly axes label every 5th day (1, 5, 10, 15, 20, 25, 30) plus
/// the last day, so 30 day numbers never cram together. The old code
/// relied on fl_chart's `SideTitles.interval: 5` — which does NOTHING
/// on bar charts: fl_chart draws one bottom title per bar group and
/// ignores `interval` there (see side_titles_widget.dart in
/// fl_chart 0.69.2). The filter has to live in `getTitlesWidget`,
/// which is what this helper is for: null means "draw no label".
/// Weekly / 7-day axes are short enough to label every day.
String? chartDayLabel(int day, int dayCount, {bool sparse = true}) {
  if (!sparse) return '$day';
  if (day == 1 || day % 5 == 0 || day == dayCount) return '$day';
  return null;
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

  _DashboardPeriod _period = _DashboardPeriod.monthly;
  DateTime _anchor = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );
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

  /// Monday of the week containing [date].
  static DateTime _weekStart(DateTime date) =>
      date.subtract(Duration(days: date.weekday - 1));

  /// The dates the table (and the per-day charts) cover for the
  /// current period: 1 day (daily), 7 days Mon–Sun (weekly), or the
  /// whole month (monthly).
  List<DateTime> _periodDates() {
    switch (_period) {
      case _DashboardPeriod.daily:
        return [_anchor];
      case _DashboardPeriod.weekly:
        final start = _weekStart(_anchor);
        return [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];
      case _DashboardPeriod.monthly:
        final days = DateTime(_anchor.year, _anchor.month + 1, 0).day;
        return [
          for (var d = 1; d <= days; d++)
            DateTime(_anchor.year, _anchor.month, d),
        ];
    }
  }

  /// The dates the line graph covers: the period's days for weekly /
  /// monthly, the last 7 days ending at the anchor day for daily.
  /// Future days are cut off — a trend line must never dive to zero
  /// for days that have not happened yet.
  List<DateTime> _lineDates() {
    final now = DateTime.now();
    final todayDate = DateTime(now.year, now.month, now.day);
    final List<DateTime> days;
    switch (_period) {
      case _DashboardPeriod.daily:
        days = [
          for (var i = 6; i >= 0; i--) _anchor.subtract(Duration(days: i)),
        ];
      case _DashboardPeriod.weekly:
      case _DashboardPeriod.monthly:
        days = _periodDates();
    }
    return days.where((d) => !d.isAfter(todayDate)).toList();
  }

  /// The log range to fetch for the current period: the last 7 days
  /// for daily (the trend line needs them), the week for weekly, the
  /// month for monthly.
  (DateTime, DateTime) _loadRange() {
    switch (_period) {
      case _DashboardPeriod.daily:
        return (
          _anchor.subtract(const Duration(days: 6)),
          _anchor,
        );
      case _DashboardPeriod.weekly:
        final start = _weekStart(_anchor);
        return (start, start.add(const Duration(days: 6)));
      case _DashboardPeriod.monthly:
        return (
          DateTime(_anchor.year, _anchor.month, 1),
          DateTime(_anchor.year, _anchor.month + 1, 0),
        );
    }
  }

  Future<void> _load() async {
    final firstLoad = _habitsList.isEmpty && _ledger.isEmpty;
    if (firstLoad) setState(() => _loading = true);
    try {
      final habits = await _habits.listMyHabits();
      final (rangeStart, rangeEnd) = _loadRange();
      final logs = await _habits.listLogsInRange(
        dateKey(rangeStart),
        dateKey(rangeEnd),
      );
      // The score card always shows TODAY (plus this week's pace),
      // even when the viewed period is in the past — so the current
      // week's logs are fetched alongside the period's logs.
      final now = DateTime.now();
      final todayDate = DateTime(now.year, now.month, now.day);
      final weekStart = _weekStart(todayDate);
      final weekLogs = await _habits.listLogsInRange(
        dateKey(weekStart),
        dateKey(todayDate),
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
      for (final log in [...logs, ...weekLogs]) {
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

  void _shiftPeriod(int delta) {
    setState(() {
      switch (_period) {
        case _DashboardPeriod.daily:
          _anchor = _anchor.add(Duration(days: delta));
        case _DashboardPeriod.weekly:
          _anchor = _anchor.add(Duration(days: 7 * delta));
        case _DashboardPeriod.monthly:
          _anchor = DateTime(_anchor.year, _anchor.month + delta);
      }
      _loading = true;
    });
    _load();
  }

  void _goToday() {
    final now = DateTime.now();
    setState(() {
      _anchor = DateTime(now.year, now.month, now.day);
      _loading = true;
    });
    _load();
  }

  void _setPeriod(_DashboardPeriod period) {
    if (period == _period) return;
    setState(() {
      _period = period;
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

  /// How many applicable habits were done on [date].
  int _doneOn(DateTime date) {
    final doneIds = _logsByDate[dateKey(date)] ?? const <String>{};
    return _habitsFor(date).where((h) => doneIds.contains(h.id)).length;
  }

  /// The label above the table: the day, the week, or the month.
  String _periodLabel() {
    switch (_period) {
      case _DashboardPeriod.daily:
        if (dateKey(_anchor) == dateKey(DateTime.now())) {
          return 'Today, ${_prettyDate(dateKey(_anchor))}';
        }
        return _prettyDay(_anchor);
      case _DashboardPeriod.weekly:
        return 'Week of ${_prettyDate(dateKey(_weekStart(_anchor)))}';
      case _DashboardPeriod.monthly:
        return monthName(_anchor);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = dateKey(now);
    final todayDate = DateTime(now.year, now.month, now.day);
    final isTodayAnchor = dateKey(_anchor) == today;

    final tableDates = _periodDates();
    final lineDates = _lineDates();
    final doneByDate = <String, int>{
      for (final d in {...tableDates, ...lineDates}) dateKey(d): _doneOn(d),
    };

    // Period summary + pie data: days with at least one completion,
    // total completions, and applicable habit-days. Future days do
    // not count as missed.
    var activeDays = 0;
    var totalDone = 0;
    var applicableDays = 0;
    for (final date in tableDates) {
      if (date.isAfter(todayDate)) break;
      applicableDays += _habitsFor(date).length;
      final done = doneByDate[dateKey(date)] ?? 0;
      totalDone += done;
      if (done > 0) activeDays++;
    }
    final missed = (applicableDays - totalDone).clamp(0, 1000000);
    final ledgerTotal = _ledger.length * xpPerTask;

    // Today's score: habits due today, and which of them are done.
    final todayHabits = _habitsFor(todayDate);
    final todayDoneIds = (_logsByDate[today] ?? const <String>{})
        .where((id) => todayHabits.any((h) => h.id == id))
        .toSet();
    // This week's pace: Monday to today.
    final weekStart = _weekStart(todayDate);
    var weekDone = 0;
    var weekApplicable = 0;
    for (var d = weekStart; !d.isAfter(todayDate); d = d.add(const Duration(days: 1))) {
      weekApplicable += _habitsFor(d).length;
      weekDone += _doneOn(d);
    }

    final String statsLine;
    switch (_period) {
      case _DashboardPeriod.daily:
        final total = _habitsFor(_anchor).length;
        final done = _doneOn(_anchor);
        final pct = total == 0 ? 0 : (done / total * 100).round();
        statsLine = '${_prettyDay(_anchor)}: $done of $total done — $pct%';
      case _DashboardPeriod.weekly:
        statsLine =
            'Week of ${_prettyDate(dateKey(weekStart))}: $totalDone of $applicableDays done • $activeDays ${activeDays == 1 ? 'day' : 'days'} with activity';
      case _DashboardPeriod.monthly:
        statsLine =
            '$activeDays ${activeDays == 1 ? 'day' : 'days'} with activity • $totalDone ${totalDone == 1 ? 'habit' : 'habits'} done';
    }

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
                    // Daily / Weekly / Monthly switcher.
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 6),
                      child: SegmentedButton<_DashboardPeriod>(
                        segments: [
                          for (final p in _DashboardPeriod.values)
                            ButtonSegment(
                              value: p,
                              label: Text(p.label),
                            ),
                        ],
                        selected: {_period},
                        onSelectionChanged: (selected) =>
                            _setPeriod(selected.first),
                        showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          backgroundColor: AppTheme.card,
                          foregroundColor: AppTheme.inkSoft,
                          selectedBackgroundColor: AppTheme.ember,
                          selectedForegroundColor: AppTheme.ink,
                          side: const BorderSide(color: AppTheme.cardBorder),
                        ),
                      ),
                    ),
                    // Period bar: previous / label / next + Today.
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => _shiftPeriod(-1),
                          tooltip: 'Previous',
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Expanded(
                          child: Text(
                            _periodLabel(),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _shiftPeriod(1),
                          tooltip: 'Next',
                          icon: const Icon(Icons.chevron_right),
                        ),
                        TextButton(
                          onPressed: isTodayAnchor ? null : _goToday,
                          child: const Text('Today'),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          statsLine,
                          style: const TextStyle(
                            color: AppTheme.inkSoft,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    // Today's score — always today, whatever period
                    // is being viewed.
                    _TodayScoreCard(
                      today: todayDate,
                      habitsToday: todayHabits,
                      doneIds: todayDoneIds,
                      weekDone: weekDone,
                      weekApplicable: weekApplicable,
                    ).animate().fadeIn().slideY(begin: 0.05),
                    const SizedBox(height: 14),
                    if (_habitsList.isEmpty)
                      const EmptyState(
                        icon: Icons.check_circle_outline,
                        title: 'No habits yet',
                        subtitle:
                            'Add a habit from Home and the table will fill in here.',
                      )
                    else ...[
                      _HabitTable(
                        dates: tableDates,
                        todayKey: today,
                        todayDate: todayDate,
                        habits: _habitsList,
                        logsByDate: _logsByDate,
                        habitsFor: _habitsFor,
                        perDayDone: [
                          for (final d in tableDates)
                            doneByDate[dateKey(d)] ?? 0,
                        ],
                      ).animate().fadeIn().slideY(begin: 0.05),
                      const SizedBox(height: 14),
                      _ChartsCard(
                        period: _period,
                        dates: tableDates,
                        lineDates: lineDates,
                        doneByDate: doneByDate,
                        done: totalDone,
                        missed: missed,
                        habits: _habitsList,
                        logsByDate: _logsByDate,
                        anchorDay: _anchor,
                        todayKey: today,
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

const _weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// "Tue, 18 Nov 2026" — a single day with its weekday.
String _prettyDay(DateTime date) =>
    '${_weekdayShort[date.weekday - 1]}, ${_prettyDate(dateKey(date))}';

/// "November 2026" from a 'YYYY-MM' key.
String _prettyMonth(String key) {
  final parts = key.split('-');
  if (parts.length != 2) return key;
  final year = int.tryParse(parts[0]) ?? DateTime.now().year;
  final month = int.tryParse(parts[1]) ?? DateTime.now().month;
  return monthName(DateTime(year, month));
}

/// Today's score: the honest percent for today, what was done (each
/// habit + its +2 XP) and what is still pending — so the percent can
/// be checked by hand. Score = done today / habits due today × 100.
/// Plus today's pace and this week's pace.
class _TodayScoreCard extends StatelessWidget {
  const _TodayScoreCard({
    required this.today,
    required this.habitsToday,
    required this.doneIds,
    required this.weekDone,
    required this.weekApplicable,
  });

  final DateTime today;
  final List<Habit> habitsToday;
  final Set<String> doneIds;
  final int weekDone;
  final int weekApplicable;

  @override
  Widget build(BuildContext context) {
    final total = habitsToday.length;
    final doneHabits = habitsToday.where((h) => doneIds.contains(h.id)).toList();
    final pendingHabits =
        habitsToday.where((h) => !doneIds.contains(h.id)).toList();
    final done = doneHabits.length;
    final pct = total == 0 ? 0 : (done / total * 100).round();
    final todayXp = done * xpPerTask;
    final weekPct = weekApplicable == 0
        ? 0
        : (weekDone / weekApplicable * 100).round();

    final String pace;
    final IconData paceIcon;
    final Color paceColor;
    if (total == 0) {
      pace = 'No habits due today';
      paceIcon = Icons.schedule;
      paceColor = AppTheme.inkSoft;
    } else if (done == total) {
      pace = 'All done — great day!';
      paceIcon = Icons.check_circle;
      paceColor = AppTheme.gold;
    } else if (pct >= 50) {
      pace = 'On track — ${total - done} to go';
      paceIcon = Icons.trending_up;
      paceColor = AppTheme.ember;
    } else if (done > 0) {
      pace = 'Getting there — ${total - done} to go';
      paceIcon = Icons.hourglass_bottom;
      paceColor = AppTheme.inkSoft;
    } else {
      pace = 'Not started yet — $total to go';
      paceIcon = Icons.schedule;
      paceColor = AppTheme.inkSoft;
    }

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
                  "Today's score",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                total == 0 ? '—' : '$pct%',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.ember,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(paceIcon, color: paceColor, size: 15),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  total == 0
                      ? pace
                      : 'Today: $done of $total done — $pct% • $pace',
                  style: const TextStyle(
                    color: AppTheme.inkSoft,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 2),
            Text(
              "Today's XP: $todayXp XP ($done done × $xpPerTask XP)",
              style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
          ],
          if (weekApplicable > 0) ...[
            const SizedBox(height: 2),
            Text(
              'This week: $weekDone of $weekApplicable done — $weekPct%',
              style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
          ],
          if (total == 0) ...[
            const SizedBox(height: 8),
            const Text(
              'Add a habit from Home and your score will show up here.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
            ),
          ] else ...[
            const SizedBox(height: 10),
            if (doneHabits.isNotEmpty) ...[
              Text(
                'Done ($done)',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.inkSoft,
                ),
              ),
              const SizedBox(height: 6),
              for (final habit in doneHabits)
                _scoreRow(
                  habit: habit,
                  done: true,
                ),
            ],
            if (pendingHabits.isNotEmpty) ...[
              if (doneHabits.isNotEmpty) const SizedBox(height: 8),
              Text(
                'Still to do (${pendingHabits.length})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.inkSoft,
                ),
              ),
              const SizedBox(height: 6),
              for (final habit in pendingHabits)
                _scoreRow(
                  habit: habit,
                  done: false,
                ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _scoreRow({required Habit habit, required bool done}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.circle_outlined,
            color: done ? AppTheme.ember : AppTheme.inkSoft,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              habit.title,
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
            done ? '+$xpPerTask XP' : '+$xpPerTask XP when done',
            style: TextStyle(
              color: done ? AppTheme.ember : AppTheme.inkSoft,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// The Excel-style table: habits down one column, dates across, each
/// cell a small box — filled when done, empty when not. READ-ONLY:
/// there is no tap handler on the cells; ticking happens on Home.
/// The [dates] are the period's days (1 for daily, 7 for weekly,
/// the whole month for monthly).
class _HabitTable extends StatelessWidget {
  const _HabitTable({
    required this.dates,
    required this.todayKey,
    required this.todayDate,
    required this.habits,
    required this.logsByDate,
    required this.habitsFor,
    required this.perDayDone,
  });

  final List<DateTime> dates;
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
    final tableWidth = _nameWidth + _cellWidth * dates.length;
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
                      for (final date in dates) _dateHeader(date),
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
                      for (var i = 0; i < dates.length; i++)
                        SizedBox(
                          width: _cellWidth,
                          child: Center(
                            child: Text(
                              _isFuture(dates[i]) ? '' : '${perDayDone[i]}',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: _isToday(dates[i])
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

  bool _isToday(DateTime date) => dateKey(date) == todayKey;

  bool _isFuture(DateTime date) => date.isAfter(todayDate);

  Widget _dateHeader(DateTime date) {
    final isToday = _isToday(date);
    return SizedBox(
      width: _cellWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${date.day}',
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
          for (final date in dates) _cell(habit, date),
        ],
      ),
    );
  }

  Widget _cell(Habit habit, DateTime date) {
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

/// Pie chart (done vs missed in the period) + bar graph (completions
/// per day — or per habit, in the Daily period) + line graph (daily
/// completions trend), side by side on wide screens, stacked on
/// phones. When a chart has no data at all it shows an intentional
/// empty state instead of a big blank card (18 Nov 2026: the old bar
/// graph was a huge empty area on a fresh account).
class _ChartsCard extends StatelessWidget {
  const _ChartsCard({
    required this.period,
    required this.dates,
    required this.lineDates,
    required this.doneByDate,
    required this.done,
    required this.missed,
    required this.habits,
    required this.logsByDate,
    required this.anchorDay,
    required this.todayKey,
  });

  final _DashboardPeriod period;
  final List<DateTime> dates;
  final List<DateTime> lineDates;
  final Map<String, int> doneByDate;
  final int done;
  final int missed;
  final List<Habit> habits;
  final Map<String, Set<String>> logsByDate;
  final DateTime anchorDay;
  final String todayKey;

  @override
  Widget build(BuildContext context) {
    final total = done + missed;
    final pct = total == 0 ? 0.0 : done / total * 100;
    final isDaily = period == _DashboardPeriod.daily;
    final (String, String) title;
    switch (period) {
      case _DashboardPeriod.daily:
        title = ('Today', "Today's habits and the last 7 days.");
      case _DashboardPeriod.weekly:
        title = ('This week', 'How much got done, and when.');
      case _DashboardPeriod.monthly:
        title = ('This month', 'How much got done, and when.');
    }

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
                Text(
                  title.$1,
                  style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final barSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isDaily ? "Today's habits" : 'Completions per day',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        _barChart(),
      ],
    );

    final lineSection = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Trend',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          isDaily
              ? 'Daily completions — last 7 days'
              : period == _DashboardPeriod.weekly
                  ? 'Daily completions — this week'
                  : 'Daily completions — this month',
          style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
        ),
        const SizedBox(height: 6),
        _lineChart(),
      ],
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
          Text(
            title.$1,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            title.$2,
            style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 560) {
                return Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: pie),
                        const SizedBox(width: 16),
                        Expanded(child: barSection),
                      ],
                    ),
                    const SizedBox(height: 16),
                    lineSection,
                  ],
                );
              }
              return Column(
                children: [
                  pie,
                  const SizedBox(height: 8),
                  barSection,
                  const SizedBox(height: 16),
                  lineSection,
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Bar graph: per day in the Weekly/Monthly period, per habit in
  /// the Daily period (one bar per habit: 1 if done that day, 0 if
  /// not). X labels are filtered by [chartDayLabel] — every 5th day
  /// on monthly axes — so they never cram together.
  Widget _barChart() {
    final isDaily = period == _DashboardPeriod.daily;
    final anchorDone =
        logsByDate[dateKey(anchorDay)] ?? const <String>{};
    final barTotal = isDaily
        ? habits.where((h) => anchorDone.contains(h.id)).length
        : dates.fold<int>(
            0,
            (sum, d) => sum + (doneByDate[dateKey(d)] ?? 0),
          );
    if (barTotal == 0) {
      return const _ChartEmptyState(
        icon: Icons.bar_chart_outlined,
        title: 'No completions in this period yet',
        subtitle: 'Tick a habit on Home and the bars will fill in here.',
      );
    }
    final maxDone = isDaily
        ? 1
        : dates.fold<int>(
            0,
            (m, d) {
              final v = doneByDate[dateKey(d)] ?? 0;
              return v > m ? v : m;
            },
          );
    final daysInMonth = DateTime(anchorDay.year, anchorDay.month + 1, 0).day;
    return SizedBox(
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
                isDaily
                    ? '${habits[group.x].title}: ${rod.toY.toInt() == 1 ? 'Done' : 'Not done'}'
                    : 'Day ${group.x}: ${rod.toY.toInt()} done',
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
                interval: 1,
                getTitlesWidget: (value, _) {
                  if (isDaily) {
                    final index = value.toInt();
                    if (index < 0 || index >= habits.length) {
                      return const SizedBox.shrink();
                    }
                    final title = habits[index].title;
                    final short = title.length > 10
                        ? '${title.substring(0, 10)}…'
                        : title;
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        short,
                        style: const TextStyle(
                          color: AppTheme.inkSoft,
                          fontSize: 10,
                        ),
                      ),
                    );
                  }
                  final day = value.toInt();
                  final label = chartDayLabel(
                    day,
                    daysInMonth,
                    sparse: period == _DashboardPeriod.monthly,
                  );
                  if (label == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      label,
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
          barGroups: isDaily
              ? [
                  for (var i = 0; i < habits.length; i++)
                    BarChartGroupData(
                      x: i,
                      barRods: [
                        BarChartRodData(
                          toY: anchorDone.contains(habits[i].id) ? 1 : 0,
                          color: anchorDone.contains(habits[i].id)
                              ? AppTheme.ember
                              : AppTheme.cardBorder,
                          width: 22,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(3),
                          ),
                        ),
                      ],
                    ),
                ]
              : [
                  for (final date in dates)
                    BarChartGroupData(
                      x: date.day,
                      barRods: [
                        BarChartRodData(
                          toY: (doneByDate[dateKey(date)] ?? 0).toDouble(),
                          color: dateKey(date) == todayKey
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
  }

  /// Line graph: daily completions over [lineDates] (the period's
  /// days, or the last 7 days in the Daily period). X labels use the
  /// same every-5th-day rule as the bar graph on monthly axes.
  Widget _lineChart() {
    if (lineDates.isEmpty) {
      return const _ChartEmptyState(
        icon: Icons.show_chart,
        title: 'No trend yet',
        subtitle: 'Complete a habit and the line will appear here.',
      );
    }
    final values = [
      for (final d in lineDates) doneByDate[dateKey(d)] ?? 0,
    ];
    final maxDone = values.fold<int>(0, (m, v) => v > m ? v : m);
    if (maxDone == 0) {
      return const _ChartEmptyState(
        icon: Icons.show_chart,
        title: 'No trend yet',
        subtitle: 'Complete a habit and the line will appear here.',
      );
    }
    final sparse = period == _DashboardPeriod.monthly;
    final maxX = lineDates.length <= 1
        ? 1.0
        : (lineDates.length - 1).toDouble();
    return SizedBox(
      height: 180,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: maxX,
          minY: 0,
          maxY: (maxDone + 1).toDouble(),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: 1,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: AppTheme.cardBorder, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => AppTheme.card,
              getTooltipItems: (spots) => spots
                  .map((spot) {
                    final date = lineDates[spot.x.toInt()];
                    return LineTooltipItem(
                      '${_prettyDate(dateKey(date))}: ${spot.y.toInt()} done',
                      const TextStyle(
                        color: AppTheme.ink,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    );
                  })
                  .toList(),
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
                interval: 1,
                getTitlesWidget: (value, _) {
                  final index = value.toInt();
                  if (index < 0 || index >= lineDates.length) {
                    return const SizedBox.shrink();
                  }
                  final date = lineDates[index];
                  final daysInMonth = DateTime(
                    date.year,
                    date.month + 1,
                    0,
                  ).day;
                  final label = chartDayLabel(
                    date.day,
                    daysInMonth,
                    sparse: sparse,
                  );
                  if (label == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      label,
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
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < lineDates.length; i++)
                  FlSpot(i.toDouble(), values[i].toDouble()),
              ],
              isCurved: false,
              color: AppTheme.ember,
              barWidth: 2.5,
              dotData: const FlDotData(show: true),
              belowBarData: BarAreaData(
                show: true,
                color: AppTheme.ember.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
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

/// Intentional empty state for a chart with no data yet — a compact
/// message, not a giant blank card.
class _ChartEmptyState extends StatelessWidget {
  const _ChartEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppTheme.inkSoft, size: 28),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
          ],
        ),
      ),
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
