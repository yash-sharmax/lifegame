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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
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
                gradient: AppTheme.violetGradient,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                icon: Icons.local_fire_department,
                label: 'Current streak',
                valueWidget: CountUp(
                  value: profile?.currentStreak ?? 0,
                  suffix: ' days',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                gradient: AppTheme.amberGradient,
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
                label: 'Longest streak',
                valueWidget: CountUp(
                  value: profile?.longestStreak ?? 0,
                  suffix: ' days',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                gradient: AppTheme.pinkGradient,
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
                gradient: AppTheme.tealGradient,
              ),
            ),
          ],
        ).animate().fadeIn(delay: 120.ms).slideY(begin: 0.1),
      ],
    );
  }

  Widget _weeklyCard(List<MapEntry<String, double>> weekly) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Weekly completion',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
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
                          gradient: AppTheme.violetGradient,
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
            ),
          ),
        ],
      ),
    ),
  ).animate().fadeIn(delay: 160.ms).slideY(begin: 0.1);

  Widget _trendCard(List<double> trend) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Daily trend — last 14 days',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
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
                    color: AppTheme.pink,
                    barWidth: 3.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          AppTheme.pink.withValues(alpha: 0.35),
                          AppTheme.pink.withValues(alpha: 0.02),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
                titlesData: const FlTitlesData(
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                ),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: const Color(0xFFEDEAF5), strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
              ),
            ),
          ),
        ],
      ),
    ),
  ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.1);

  Widget _topHabitsCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Top habits',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
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
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 15,
                      backgroundColor: AppTheme.violet.withValues(alpha: 0.12),
                      child: Text(
                        '${entry.key + 1}',
                        style: const TextStyle(
                          color: AppTheme.violet,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
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

  @override
  Widget build(BuildContext context) {
    final profile = _profile;
    final monthFraction = _monthFraction();
    final trend = _trend();
    final weekly = _weekly();
    final last30 = _last30DaysFraction();
    final wide = isWideScreen(context);

    // The XP bar is pinned above the scrollable content, so the user's
    // current XP (and level) is visible at the top at all times.
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
              'Dashboard',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
            ).animate().fadeIn().slideY(begin: -0.1),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: XpBar(xp: profile?.xp ?? 0)
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
                  if (_loading)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: CircularProgressIndicator(),
                      ),
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
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(height: 10),
          DefaultTextStyle(
            style: const TextStyle(color: Colors.white),
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
