import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/subtasks.dart';
import '../logic/xp.dart';
import '../screens/auth_screen.dart';
import '../theme.dart';

/// What the user chose in the habit edit dialog.
enum HabitEditAction { save, delete }

/// The dialog result: the chosen action plus the (possibly edited)
/// title and notes.
class HabitEditResult {
  const HabitEditResult(this.action, this.title, {this.notes = ''});

  final HabitEditAction action;
  final String title;

  /// The (possibly edited) notes text. Empty means "no notes".
  final String notes;
}

/// The result of the add-habit dialog: the title and the chosen banner
/// colour (a gradient's first colour, stored as an ARGB int — the same
/// value Home has always stored for a habit).
class HabitAddResult {
  const HabitAddResult({required this.title, required this.color});

  final String title;
  final int color;
}

/// The add-habit dialog, shared by Home and Schedule (18 Nov 2026):
/// one habit-creation flow everywhere, so a habit added from Schedule
/// behaves exactly like one added from Home. Returns null on cancel.
Future<HabitAddResult?> showAddHabitDialog(BuildContext context) async {
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
                            color: AppTheme.ink,
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
    return HabitAddResult(title: titleController.text.trim(), color: color);
  }
  return null;
}

/// The habit edit dialog, shared by Home and Profile: rename a habit,
/// add or edit its notes, manage its sub-tasks, or delete it. Returns
/// null when the user cancels. The caller performs the habit save /
/// delete itself and reloads afterwards. Sub-task changes (tick, add,
/// delete) apply right away through [habitRepo] — they are not part
/// of the returned result.
Future<HabitEditResult?> showHabitEditDialog(
  BuildContext context,
  Habit habit, {
  HabitRepository? habitRepo,
}) async {
  return showDialog<HabitEditResult>(
    context: context,
    builder: (context) => _HabitEditDialog(
      habit: habit,
      repo: habitRepo ?? HabitRepository(),
    ),
  );
}

class _HabitEditDialog extends StatefulWidget {
  const _HabitEditDialog({required this.habit, required this.repo});

  final Habit habit;
  final HabitRepository repo;

  @override
  State<_HabitEditDialog> createState() => _HabitEditDialogState();
}

class _HabitEditDialogState extends State<_HabitEditDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _notesController;
  final _dailyAddController = TextEditingController();
  final _todayAddController = TextEditingController();
  List<HabitSubtask> _subtasks = [];
  Set<String> _doneToday = {};
  bool _loadingSubtasks = true;

  String get _today => todayKey();

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.habit.title);
    _notesController = TextEditingController(text: widget.habit.notes);
    _loadSubtasks();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _dailyAddController.dispose();
    _todayAddController.dispose();
    super.dispose();
  }

  Future<void> _loadSubtasks() async {
    try {
      final subtasks =
          await widget.repo.listSubtasksForHabit(widget.habit.id);
      final done = await widget.repo.completedSubtaskIdsForDate(_today);
      if (!mounted) return;
      setState(() {
        _subtasks = subtasks;
        _doneToday = done;
        _loadingSubtasks = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingSubtasks = false);
    }
  }

  /// Sub-tasks due today, split by kind.
  List<HabitSubtask> get _daily =>
      dueSubtasks(_subtasks, _today)
          .where((s) => s.kind == HabitSubtask.kindDaily)
          .toList();
  List<HabitSubtask> get _todayOnly =>
      dueSubtasks(_subtasks, _today)
          .where((s) => s.kind == HabitSubtask.kindToday)
          .toList();

  Future<void> _toggleSubtask(HabitSubtask sub, bool value) async {
    final wasDone = _doneToday.contains(sub.id);
    if (wasDone == value) return;
    setState(() {
      if (value) {
        _doneToday.add(sub.id);
      } else {
        _doneToday.remove(sub.id);
      }
    });
    try {
      await widget.repo.toggleSubtask(
        subtask: sub,
        date: _today,
        completed: value,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (wasDone) {
          _doneToday.add(sub.id);
        } else {
          _doneToday.remove(sub.id);
        }
      });
      showError(context, e);
    }
  }

  Future<void> _addSubtask(
    String kind,
    TextEditingController controller,
  ) async {
    final title = controller.text.trim();
    if (title.isEmpty) return;
    controller.clear();
    try {
      final sub = await widget.repo.addSubtask(
        habit: widget.habit,
        title: title,
        kind: kind,
      );
      if (!mounted) return;
      setState(() => _subtasks.add(sub));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _deleteSubtask(HabitSubtask sub) async {
    setState(() {
      _subtasks.removeWhere((s) => s.id == sub.id);
      _doneToday.remove(sub.id);
    });
    try {
      await widget.repo.deleteSubtask(sub);
    } catch (e) {
      if (!mounted) return;
      setState(() => _subtasks.add(sub));
      showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final due = dueSubtasks(_subtasks, _today);
    final doneCount = due.where((s) => _doneToday.contains(s.id)).length;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('Edit habit'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _titleController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Habit name'),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _notesController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                hintText: 'Anything to remember about this habit…',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Sub-tasks',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                  ),
                ),
                if (!_loadingSubtasks && due.isNotEmpty)
                  Text(
                    '$doneCount/${due.length} done today',
                    style: const TextStyle(
                      color: AppTheme.inkSoft,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'A habit is done when all its sub-tasks for today are done.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
            if (_loadingSubtasks)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              )
            else ...[
              const SizedBox(height: 10),
              _SubtaskGroup(
                heading: 'Daily',
                hint: 'Add a daily sub-task…',
                subtasks: _daily,
                doneToday: _doneToday,
                onToggle: _toggleSubtask,
                onDelete: _deleteSubtask,
                onAdd: (controller) =>
                    _addSubtask(HabitSubtask.kindDaily, controller),
                addController: _dailyAddController,
              ),
              const SizedBox(height: 12),
              _SubtaskGroup(
                heading: 'Today',
                hint: 'Add a sub-task for today only…',
                subtasks: _todayOnly,
                doneToday: _doneToday,
                onToggle: _toggleSubtask,
                onDelete: _deleteSubtask,
                onAdd: (controller) =>
                    _addSubtask(HabitSubtask.kindToday, controller),
                addController: _todayAddController,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            HabitEditResult(
              HabitEditAction.delete,
              _titleController.text.trim(),
              notes: _notesController.text.trim(),
            ),
          ),
          child: const Text('Delete', style: TextStyle(color: AppTheme.flame)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            HabitEditResult(
              HabitEditAction.save,
              _titleController.text.trim(),
              notes: _notesController.text.trim(),
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// One sub-task group ("Daily" or "Today") inside the habit edit
/// dialog: the heading, its sub-tasks with a tick checkbox and a
/// delete button, and an add field.
class _SubtaskGroup extends StatelessWidget {
  const _SubtaskGroup({
    required this.heading,
    required this.hint,
    required this.subtasks,
    required this.doneToday,
    required this.onToggle,
    required this.onDelete,
    required this.onAdd,
    required this.addController,
  });

  final String heading;
  final String hint;
  final List<HabitSubtask> subtasks;
  final Set<String> doneToday;
  final Future<void> Function(HabitSubtask, bool) onToggle;
  final Future<void> Function(HabitSubtask) onDelete;
  final Future<void> Function(TextEditingController) onAdd;
  final TextEditingController addController;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AppTheme.inkSoft,
          ),
        ),
        const SizedBox(height: 4),
        if (subtasks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              heading == 'Daily'
                  ? 'No daily sub-tasks yet.'
                  : 'No sub-tasks for today yet.',
              style: const TextStyle(color: AppTheme.inkSoft, fontSize: 13),
            ),
          ),
        for (final sub in subtasks)
          Row(
            children: [
              Checkbox(
                value: doneToday.contains(sub.id),
                onChanged: (v) => onToggle(sub, v ?? false),
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: Text(
                  sub.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => onDelete(sub),
                tooltip: 'Delete sub-task',
                icon: const Icon(Icons.close, size: 18),
                color: AppTheme.inkSoft,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                padding: EdgeInsets.zero,
              ),
            ],
          ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: addController,
                decoration: InputDecoration(
                  hintText: hint,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                onSubmitted: (_) => onAdd(addController),
              ),
            ),
            const SizedBox(width: 6),
            IconButton(
              onPressed: () => onAdd(addController),
              tooltip: 'Add sub-task',
              icon: const Icon(Icons.add_circle, color: AppTheme.ember),
            ),
          ],
        ),
      ],
    );
  }
}
