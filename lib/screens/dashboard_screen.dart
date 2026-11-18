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

/// Dashboard: monthly ring, weekly bars, 14-day trend, top habits, stats.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, this.habitRepo, this.profileRepo});

  final HabitRepository? habitRepo;
  final ProfileRepository? profileRepo;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();
  ProfileRepository get _profiles => widget.profileRepo ?? ProfileRepository();

  bool _loading = true;
  Profile? _profile;
  int _habitCount = 0;
  List<HabitLog> _monthLogs = [];
  List<HabitLog> _recentLogs = [];
  List<MapEntry<String, int>> _topHabits = [];
  StreamSubscription<void>? _habitChanges;

  @override
  void initState() {
    super.initState();
    // This screen loads once (IndexedStack keeps it alive), so a habit
    // ticked on Home would leave the charts stale. Reload whenever
    // habits or their logs change.
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
    // Only show the spinner on the first load: later refreshes update
    // silently instead of flashing a loader over the charts.
    final firstLoad = _profile == null && _habitCount == 0;
    if (firstLoad) setState(() => _loading = true);
    try {
      final now = DateTime.now();
      final monthStart = DateTime(now.year, now.month, 1);
      final ninetyDaysAgo = now.subtract(const Duration(days: 90));
      final habits = await _habits.listMyHabits();
      final monthLogs = await _habits.listLogsInRange(
        dateKey(monthStart),
        dateKey(now),
      );
      final recentLogs = await _habits.listLogsInRange(
        dateKey(ninetyDaysAgo),
        dateKey(now),
      );
      final profile = await _profiles.fetchMyProfile();
      if (!mounted) return;
      // Top habits by completions in the last 90 days.
      final counts = <String, int>{};
      for (final log in recentLogs) {
        counts[log.habitId] = (counts[log.habitId] ?? 0) + 1;
      }
      final sortedHabits = habits.toList()
        ..sort((a, b) => (counts[b.id] ?? 0).compareTo(counts[a.id] ?? 0));
      final topHabits = sortedHabits
          .where((h) => (counts[h.id] ?? 0) > 0)
          .take(5)
          .map((h) => MapEntry(h.title, counts[h.id]!))
          .toList();
      setState(() {
        _habitCount = habits.length;
        _monthLogs = monthLogs;
        _recentLogs = recentLogs;
        _profile = profile;
        _topHabits = topHabits;
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

  int _daysElapsedThisMonth() {
    final now = DateTime.now();
    return now.day;
  }

  double _monthFraction() {
    if (_habitCount == 0) return 0;
    final possible = _habitCount * _daysElapsedThisMonth();
    if (possible == 0) return 0;
    return _monthLogs.length / possible;
  }

  /// Daily completion % for the last 14 days (oldest → newest).
  List<double> _trend() {
    final now = DateTime.now();
    final values = <double>[];
    for (var i = 13; i >= 0; i--) {
      final day = now.subtract(Duration(days: i));
      final key = dateKey(day);
      final done = _recentLogs.where((l) => l.logDate == key).length;
      values.add(_habitCount == 0 ? 0 : done / _habitCount);
    }
    return values;
  }

  /// Weekly % for the last 4 weeks (oldest → newest), Mon–Sun weeks.
  List<MapEntry<String, double>> _weekly() {
    final now = DateTime.now();
    final result = <MapEntry<String, double>>[];
    for (var w = 3; w >= 0; w--) {
      final weekMonday = now.subtract(Duration(days: now.weekday - 1 + w * 7));
      var done = 0;
      var possible = 0;
      for (var d = 0; d < 7; d++) {
        final day = weekMonday.add(Duration(days: d));
        if (day.isAfter(now)) break;
        possible += _habitCount;
        final key = dateKey(day);
        done += _recentLogs.where((l) => l.logDate == key).length;
      }
      final pct = possible == 0 ? 0.0 : done / possible;
      final label = w == 0 ? 'This week' : 'W${4 - w}';
      result.add(MapEntry(label, pct));
    }
    return result;
  }

  double _last30DaysFraction() {
    final now = DateTime.now();
    var done = 0;
    var possible = 0;
    for (var i = 0; i < 30; i++) {
      final day = now.subtract(Duration(days: i));
      possible += _habitCount;
      final key = dateKey(day);
      done += _recentLogs.where((l) => l.logDate == key).length;
    }
    if (possible == 0) return 0;
    return done / possible;
  }

  Widget _monthlyCard(double monthFraction) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          const Text(
            'Monthly Progress',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            '${_monthLogs.length} of ${_habitCount * _daysElapsedThisMonth()} battles won so far',
            style: const TextStyle(color: AppTheme.inkSoft, fontSize: 13),
          ),
          const SizedBox(height: 8),
          ProgressRing(
            fraction: monthFraction,
            size: 190,
            centerLabel: 'this month',
          ),
          const SizedBox(height: 8),
          Text(
            '${_monthLogs.length} completions so far this month',
            style: const TextStyle(color: AppTheme.inkSoft),
          ),
        ],
      ),
    ),
  ).animate().fadeIn().slideY(begin: 0.1);

  Widget _statsGrid(Profile? profile, double last30) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.bolt,
                label: 'Total XP',
                valueWidget: CountUp(
                  value: profile?.xp ?? 0,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                gradient: AppTheme.emberGradient,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.local_fire_department,
                label: 'Battle streak',
                valueWidget: CountUp(
                  value: profile?.currentStreak ?? 0,
                  suffix: ' days',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                gradient: AppTheme.goldGradient,
              ),
            ),
          ],
        ).animate().fadeIn(delay: 80.ms).slideY(begin: 0.1),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.emoji_events,
                label: 'Best battle streak',
                valueWidget: CountUp(
                  value: profile?.longestStreak ?? 0,
                  suffix: ' days',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                gradient: AppTheme.flameGradient,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.percent,
                label: 'Last 30 days',
                valueWidget: Text(
                  '${(last30 * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                gradient: AppTheme.emberGradient,
              ),
            ),
          ],
        ).animate().fadeIn(delay: 120.ms).slideY(begin: 0.1),
      ],
    );
  }

  Widget _weeklyCard(List<MapEntry<String, double>> weekly) {
    final allZero = weekly.every((e) => e.value == 0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Weekly completion',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            const Text(
              'Share of your plan finished each week',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (allZero)
              const _ChartEmptyState(
                text: 'No completions yet — tick a habit to start this chart.',
              )
            else
              SizedBox(
                height: 180,
                child: BarChart(
                  BarChartData(
                    maxY: 1.0,
                    barGroups: [
                      for (var i = 0; i < weekly.length; i++)
                        BarChartGroupData(
                          x: i,
                          barRods: [
                            BarChartRodData(
                              toY: weekly[i].value,
                              width: 34,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(10),
                              ),
                              gradient: AppTheme.emberGradient,
                              // Light full-height track behind each bar
                              // so 0% weeks still read as a chart.
                              backDrawRodData: BackgroundBarChartRodData(
                                show: true,
                                toY: 1.0,
                                color: AppTheme.cardBorder,
                              ),
                            ),
                          ],
                        ),
                    ],
                    titlesData: FlTitlesData(
                      leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      topTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              '${(weekly[value.toInt()].value * 100).round()}%',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) => Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              weekly[value.toInt()].key,
                              style: const TextStyle(
                                color: AppTheme.inkSoft,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                  ),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                ),
              ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 160.ms).slideY(begin: 0.1);
  }

  Widget _trendCard(List<double> trend) {
    final allZero = trend.every((v) => v == 0);
    final now = DateTime.now();
    final startDay = now.subtract(const Duration(days: 13));
    String dayLabel(int index) {
      if (index == trend.length - 1) return 'Today';
      if (index == 0) {
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
        final day = startDay.add(Duration(days: index));
        return '${day.day} ${months[day.month]}';
      }
      return '';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Daily trend — last 14 days',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            const Text(
              'Share of habits done each day',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (allZero)
              const _ChartEmptyState(
                text: 'No completions yet — tick a habit to start your trend.',
              )
            else
              SizedBox(
                height: 170,
                child: LineChart(
                  LineChartData(
                    minY: 0,
                    maxY: 1.0,
                    lineBarsData: [
                      LineChartBarData(
                        spots: [
                          for (var i = 0; i < trend.length; i++)
                            FlSpot(i.toDouble(), trend[i]),
                        ],
                        isCurved: true,
                        color: AppTheme.flame,
                        barWidth: 3.5,
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          gradient: LinearGradient(
                            colors: [
                              AppTheme.flame.withValues(alpha: 0.35),
                              AppTheme.flame.withValues(alpha: 0.02),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ],
                    titlesData: FlTitlesData(
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 36,
                          interval: 0.5,
                          getTitlesWidget: (value, meta) => Text(
                            '${(value * 100).round()}%',
                            style: const TextStyle(
                              color: AppTheme.inkSoft,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 26,
                          interval: 1,
                          getTitlesWidget: (value, meta) => Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              dayLabel(value.toInt()),
                              style: const TextStyle(
                                color: AppTheme.inkSoft,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    gridData: FlGridData(
                      show: true,
                      drawVerticalLine: false,
                      getDrawingHorizontalLine: (_) => FlLine(
                        color: AppTheme.cardBorder,
                        strokeWidth: 1,
                      ),
                    ),
                    borderData: FlBorderData(show: false),
                  ),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                ),
              ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.1);
  }

  Widget _topHabitsCard() {
    final maxCount = _topHabits.isEmpty
        ? 0
        : _topHabits.map((e) => e.value).reduce((a, b) => a > b ? a : b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Top habits',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            const Text(
              'Most completed in the last 90 days',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
            ),
            const SizedBox(height: 12),
            if (_topHabits.isEmpty)
              const Text(
                'Complete habits to see your top performers here.',
                style: TextStyle(color: AppTheme.inkSoft),
              )
            else
              ..._topHabits.asMap().entries.map((entry) {
                final title = entry.value.key;
                final count = entry.value.value;
                final fraction = maxCount == 0 ? 0.0 : count / maxCount;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 15,
                        backgroundColor: AppTheme.ember.withValues(
                          alpha: 0.12,
                        ),
                        child: Text(
                          '${entry.key + 1}',
                          style: const TextStyle(
                            color: AppTheme.ember,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 5),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: TweenAnimationBuilder<double>(
                                tween: Tween<double>(begin: 0, end: fraction),
                                duration: const Duration(milliseconds: 700),
                                curve: Curves.easeOutCubic,
                                builder: (context, value, _) =>
                                    LinearProgressIndicator(
                                      value: value,
                                      minHeight: 6,
                                      backgroundColor: AppTheme.cardBorder,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                            AppTheme.ember,
                                          ),
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '$count times',
                        style: const TextStyle(
                          color: AppTheme.inkSoft,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 240.ms).slideY(begin: 0.1);
  }

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final monthFraction = _monthFraction();
    final trend = _trend();
    final weekly = _weekly();
    final last30 = _last30DaysFraction();
    final wide = isWideScreen(context);

    // No XP bar here (18 Nov 2026): the level lives on Profile now.
    // Desktop (>=600px) lays the dashboard out in two columns inside a
    // centred, wider frame; phones keep the stacked app layout.
    return ResponsiveCenter(
      maxWidth: 1100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            child: const Text(
              'War Record',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ).animate().fadeIn().slideY(begin: -0.1),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                children: [
                  if (_loading)
                    const Column(
                      children: [
                        SkeletonBox(height: 190, borderRadius: 20),
                        SizedBox(height: 16),
                        SkeletonBox(height: 100, borderRadius: 20),
                        SizedBox(height: 12),
                        SkeletonBox(height: 100, borderRadius: 20),
                      ],
                    )
                  else if (_habitCount == 0)
                    EmptyState(
                      icon: Icons.insights_outlined,
                      title: 'No data yet',
                      subtitle: 'Add your first habit from the Home tab and your dashboard will come alive.',
                    )
                  else if (wide) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _monthlyCard(monthFraction)),
                        const SizedBox(width: 16),
                        Expanded(child: _statsGrid(profile, last30)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: _weeklyCard(weekly)),
                        const SizedBox(width: 16),
                        Expanded(child: _trendCard(trend)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _topHabitsCard(),
                  ] else ...[
                    _monthlyCard(monthFraction),
                    const SizedBox(height: 16),
                    _statsGrid(profile, last30),
                    const SizedBox(height: 16),
                    _weeklyCard(weekly),
                    const SizedBox(height: 16),
                    _trendCard(trend),
                    const SizedBox(height: 16),
                    _topHabitsCard(),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact inline empty state shown inside a chart card when the user
/// has habits but no completions yet — a chart with all-zero bars reads
/// as broken, a short line explains what to do.
class _ChartEmptyState extends StatelessWidget {
  const _ChartEmptyState({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.insights_outlined, color: AppTheme.ember, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppTheme.inkSoft,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.valueWidget,
    required this.gradient,
  });

  final IconData icon;
  final String label;
  final Widget valueWidget;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: AppTheme.ink, size: 22),
          const SizedBox(height: 10),
          DefaultTextStyle(
            style: const TextStyle(color: AppTheme.ink),
            child: valueWidget,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
