// Daily Schedule (v2.3.0): today's habits plus this week's weekly
// tasks and this month's monthly tasks, in time order.
//
// Each row shows its reminder time (when set), an alarm button to set
// or change it, and the same check-off as Home — completing grants
// +2 XP, unticking removes 2 (never below 0), using the existing
// repositories. Done items stay visible with a filled check and no
// strikethrough, like everywhere else in the app.
//
// Alarms, honestly: on the web, reminders show while the app is open
// (in-app banner + browser notification when permitted). On Android
// they also fire as a notification when the app is closed. The screen
// says so at the bottom.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/reminder_repository.dart';
import '../data/reminder_service.dart';
import '../data/repositories.dart';
import '../logic/reminders.dart';
import '../logic/xp.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/reminder_dialog.dart';
import 'auth_screen.dart';

class _ScheduleItem {
  const _ScheduleItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.done,
    this.color = 0xFF7C3AED,
  });

  /// 'habit' | 'weekly' | 'monthly'.
  final String kind;
  final String id;
  final String title;
  final bool done;
  final int color;

  String get key => '$kind:$id';

  String get kindLabel {
    switch (kind) {
      case 'weekly':
        return 'Weekly task';
      case 'monthly':
        return 'Monthly task';
      default:
        return 'Habit';
    }
  }
}

class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({
    super.key,
    this.habitRepo,
    this.taskRepo,
    this.reminderRepo,
  });

  final HabitRepository? habitRepo;
  final TaskRepository? taskRepo;
  final ReminderRepository? reminderRepo;

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  HabitRepository get _habits => widget.habitRepo ?? HabitRepository();
  TaskRepository get _tasks => widget.taskRepo ?? TaskRepository();
  ReminderRepository get _reminders =>
      widget.reminderRepo ?? ReminderRepository();

  List<_ScheduleItem> _items = [];
  Map<String, Reminder> _remindersByKey = {};
  bool _loading = true;
  final Set<String> _toggling = {};
  StreamSubscription<void>? _reminderChanges;

  @override
  void initState() {
    super.initState();
    _reminderChanges = ReminderRepository.onChanged.listen((_) {
      if (mounted) _load(silent: true);
    });
    _load();
  }

  @override
  void dispose() {
    _reminderChanges?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final today = todayKey();
      final habits = await _habits.listMyHabits();
      final logs = await _habits.listLogsForDate(today);
      final doneHabits = logs.map((l) => l.habitId).toSet();
      final weekly = await _tasks.listWeeklyTasks(weekStartKey());
      final monthly = await _tasks.listMonthlyTasks(monthKey());
      // Reminders are best-effort: a reminder-store failure must never
      // hide the schedule.
      Map<String, Reminder> reminders = {};
      try {
        reminders = await _reminders.remindersByTarget();
      } catch (_) {
        reminders = {};
      }
      final items = <_ScheduleItem>[
        for (final h in habits)
          _ScheduleItem(
            kind: 'habit',
            id: h.id,
            title: h.title,
            done: doneHabits.contains(h.id),
            color: h.color,
          ),
        for (final t in weekly)
          _ScheduleItem(
            kind: 'weekly',
            id: t.id,
            title: t.title,
            done: t.done,
          ),
        for (final t in monthly)
          _ScheduleItem(
            kind: 'monthly',
            id: t.id,
            title: t.title,
            done: t.done,
          ),
      ];
      if (!mounted) return;
      setState(() {
        _items = items;
        _remindersByKey = reminders;
        _loading = false;
      });
      // Drop reminders pointing at deleted habits/tasks.
      unawaited(
        _reminders.pruneOrphaned(items.map((i) => i.key).toSet()),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showError(context, e);
      }
    }
  }

  List<_ScheduleItem> get _sortedItems {
    final withTime = <_ScheduleItem>[];
    final withoutTime = <_ScheduleItem>[];
    for (final item in _items) {
      final r = _remindersByKey[item.key];
      if (r != null) {
        withTime.add(item);
      } else {
        withoutTime.add(item);
      }
    }
    withTime.sort((a, b) {
      final ra = _remindersByKey[a.key]!;
      final rb = _remindersByKey[b.key]!;
      final byHour = ra.hour.compareTo(rb.hour);
      return byHour != 0 ? byHour : ra.minute.compareTo(rb.minute);
    });
    return [...withTime, ...withoutTime];
  }

  int get _doneCount => _items.where((i) => i.done).length;

  Future<void> _toggle(_ScheduleItem item, bool value) async {
    if (_toggling.contains(item.key)) return;
    final index = _items.indexWhere((i) => i.key == item.key);
    if (index < 0) return;
    final prev = _items[index];
    setState(() {
      _items[index] = _ScheduleItem(
        kind: item.kind,
        id: item.id,
        title: item.title,
        done: value,
        color: item.color,
      );
    });
    _toggling.add(item.key);
    try {
      if (item.kind == 'habit') {
        final habit = Habit(
          id: item.id,
          userId: '',
          title: item.title,
          color: item.color,
        );
        await _habits.toggleHabit(
          habit: habit,
          date: todayKey(),
          completed: value,
        );
      } else if (item.kind == 'weekly') {
        await _tasks.toggleWeeklyTask(item.id, value);
      } else {
        await _tasks.toggleMonthlyTask(item.id, value);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _items[index] = prev);
        showError(context, e);
      }
    } finally {
      _toggling.remove(item.key);
    }
  }

  Future<void> _editReminder(_ScheduleItem item) async {
    final existing = _remindersByKey[item.key];
    final result = await showReminderDialog(
      context,
      title: item.title,
      existing: existing,
    );
    if (result == null || !mounted) return;
    try {
      if (result.remove) {
        await _reminders.deleteReminder(item.kind, item.id);
        await ReminderService.instance.cancelAndroidReminder(
          existing!,
        );
      } else if (result.time != null) {
        final parsed = parseReminderTime(result.time!);
        if (parsed == null) return;
        final saved = await _reminders.setReminder(
          kind: item.kind,
          targetId: item.id,
          title: item.title,
          hour: parsed.hour,
          minute: parsed.minute,
          enabled: result.enabled,
        );
        await ReminderService.instance.scheduleAndroidReminder(saved);
        await ReminderService.instance.ensureWebPermission();
        await ReminderService.instance.refresh();
      }
      await _load(silent: true);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _sortedItems;
    final done = _doneCount;
    final total = _items.length;
    final fraction = total == 0 ? 0.0 : done / total;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Today’s Schedule',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.transparent,
      ),
      body: ResponsiveCenter(
        maxWidth: 720,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: () => _load(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                  children: [
                    Text(
                      '${months[now.month]} ${now.day}, ${now.year}',
                      style: const TextStyle(
                        color: AppTheme.inkSoft,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFEDEAF5)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Day progress',
                                style: TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const Spacer(),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.violet.withValues(
                                    alpha: 0.1,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  '$done/$total done',
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
                          ClipRRect(
                            borderRadius: BorderRadius.circular(999),
                            child: LinearProgressIndicator(
                              value: fraction,
                              minHeight: 8,
                              backgroundColor: const Color(0xFFEDEAF5),
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                AppTheme.teal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (items.isEmpty)
                      EmptyState(
                        icon: Icons.schedule_outlined,
                        title: 'Nothing scheduled today',
                        subtitle:
                            'Add a habit from Home and it will show up here with its time.',
                      )
                    else
                      ...items.map((item) {
                        final reminder = _remindersByKey[item.key];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _ScheduleTile(
                            item: item,
                            reminder: reminder,
                            onToggle: (v) => _toggle(item, v),
                            onAlarm: () => _editReminder(item),
                          ),
                        );
                      }),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.violet.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline,
                            color: AppTheme.violet,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              kIsWeb
                                  ? 'Reminders on the web show while the app is open. '
                                        'On Android, they also fire as a notification '
                                        'when the app is closed.'
                                  : 'Reminders fire as a notification, even when the '
                                        'app is closed. Keep notifications allowed '
                                        'for Life Game.',
                              style: const TextStyle(
                                color: AppTheme.inkSoft,
                                fontSize: 13,
                                height: 1.4,
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

class _ScheduleTile extends StatelessWidget {
  const _ScheduleTile({
    required this.item,
    required this.reminder,
    required this.onToggle,
    required this.onAlarm,
  });

  final _ScheduleItem item;
  final Reminder? reminder;
  final ValueChanged<bool> onToggle;
  final VoidCallback onAlarm;

  @override
  Widget build(BuildContext context) {
    // Local copy so the analyzer can promote the nullable reminder
    // inside the null-checked branches below.
    final r = reminder;
    final gradient =
        AppTheme.habitGradients[item.color % AppTheme.habitGradients.length];
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: () => onToggle(!item.done),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: item.done
                  ? Colors.transparent
                  : const Color(0xFFEDEAF5),
            ),
            color: item.done ? AppTheme.violet.withValues(alpha: 0.06) : null,
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
                child: Icon(
                  item.kind == 'habit'
                      ? Icons.check_circle_outline
                      : Icons.task_alt_outlined,
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
                      item.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.ink,
                      ),
                    ),
                    Text(
                      item.done
                          ? '${item.kindLabel} • Done • +$xpPerTask XP'
                          : '${item.kindLabel} • Tap to complete • +$xpPerTask XP',
                      style: const TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (r != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: r.enabled
                        ? AppTheme.teal.withValues(alpha: 0.12)
                        : const Color(0xFFEDEAF5),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    formatReminderTime12h(r.hour, r.minute),
                    style: TextStyle(
                      color: r.enabled ? AppTheme.teal : AppTheme.inkSoft,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                )
              else
                TextButton.icon(
                  onPressed: onAlarm,
                  icon: const Icon(Icons.alarm_add_outlined, size: 18),
                  label: const Text('Set time'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.violet,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              if (r != null)
                IconButton(
                  onPressed: onAlarm,
                  tooltip: r.enabled
                      ? 'Change reminder'
                      : 'Reminder off — tap to change',
                  icon: Icon(
                    r.enabled ? Icons.alarm_on : Icons.alarm_off,
                    color: r.enabled ? AppTheme.violet : AppTheme.inkSoft,
                    size: 22,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: item.done ? AppTheme.tealGradient : null,
                  color: item.done ? null : Colors.white,
                  border: item.done
                      ? null
                      : Border.all(color: const Color(0xFFD8D2EA), width: 2),
                ),
                child: item.done
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
