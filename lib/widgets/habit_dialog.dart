import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/repositories.dart';
import '../logic/subtasks.dart';
import '../logic/xp.dart';
import '../screens/auth_screen.dart';
import '../theme.dart';
import 'common.dart';

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

/// The result of the add-habit dialog: the title and the chosen
/// colour. The colour is the palette INDEX (0..5) for a preset, or
/// the picked colour as an ARGB int for a custom colour — see
/// [AppTheme.gradientForHabitColor], which renders both.
class HabitAddResult {
  const HabitAddResult({required this.title, required this.color});

  final String title;
  final int color;
}

/// The add-habit dialog, shared by Home and Schedule (18 Nov 2026):
/// one habit-creation flow everywhere, so a habit added from Schedule
/// behaves exactly like one added from Home. Returns null on cancel.
///
/// Colour picker (v2.9.0): exactly ONE colour is selected at a time.
/// The selection is tracked by palette INDEX (not by colour value) —
/// the old code compared the gradient's first colour, and two
/// gradients shared the same violet, so two circles showed a
/// checkmark at once (18 Nov 2026). The palette itself has no
/// duplicates any more (the sixth colour is mint, not a second
/// violet). A "+" tile opens a custom colour picker (hue / saturation
/// / brightness sliders + a hex field); the picked colour becomes a
/// circle of its own and follows the same single-selection rule.
Future<HabitAddResult?> showAddHabitDialog(BuildContext context) async {
  final titleController = TextEditingController();
  // The selected preset (0..5), or -1 when the custom colour is
  // selected. One variable, one selection — never two checkmarks.
  var selectedIndex = 0;
  Color? customColor;
  final saved = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        // Local snapshot of the custom colour: `customColor` is
        // reassigned inside the dialog's setState closures, so it
        // cannot be null-promoted — this final copy can.
        final custom = customColor;
        final circles = <Widget>[
          for (var i = 0; i < AppTheme.habitGradients.length; i++)
            _ColorCircle(
              gradient: AppTheme.habitGradients[i],
              selected: selectedIndex == i,
              onTap: () => setDialogState(() => selectedIndex = i),
            ),
          if (custom != null)
            _ColorCircle(
              gradient: AppTheme.gradientForHabitColor(custom.toARGB32()),
              selected: selectedIndex == -1,
              onTap: () => setDialogState(() => selectedIndex = -1),
            ),
          // The "+" tile: pick a custom colour.
          GestureDetector(
            onTap: () async {
              final picked = await _showCustomColorPicker(
                context,
                initial: customColor ?? AppTheme.ember,
              );
              if (picked == null) return;
              setDialogState(() {
                customColor = picked;
                selectedIndex = -1;
              });
            },
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppTheme.inkSoft,
                  width: 1.5,
                  style: BorderStyle.solid,
                ),
              ),
              child: Icon(Icons.add, color: AppTheme.inkSoft, size: 22),
            ),
          ),
        ];
        return AlertDialog(
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
              Wrap(spacing: 10, runSpacing: 10, children: circles),
              if (customColor != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Custom colour — tap + to change it',
                      style: TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 12,
                      ),
                    ),
                  ),
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
        );
      },
    ),
  );
  if (saved == true && titleController.text.trim().isNotEmpty) {
    // A preset stores its index; a custom colour stores the colour.
    final color = selectedIndex >= 0
        ? selectedIndex
        : (customColor?.toARGB32() ?? 0);
    return HabitAddResult(title: titleController.text.trim(), color: color);
  }
  return null;
}

/// One colour circle in the picker: a gradient disc with a white
/// checkmark when [selected].
class _ColorCircle extends StatelessWidget {
  const _ColorCircle({
    required this.gradient,
    required this.selected,
    required this.onTap,
  });

  final Gradient gradient;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: gradient,
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: AppTheme.ink, width: 2.5)
              : null,
        ),
        child: selected
            ? Icon(
                // On the gradient circle — always white.
                Icons.check,
                color: AppTheme.onAccent,
                size: 20,
              )
            : null,
      ),
    );
  }
}

/// A small built-in custom colour picker (v2.9.0): hue, saturation
/// and brightness sliders over gradient tracks, a live preview, and
/// a hex field for an exact colour. No extra package — three sliders
/// and a text field are all it needs. Returns the picked colour, or
/// null when the user cancels.
Future<Color?> _showCustomColorPicker(
  BuildContext context, {
  required Color initial,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => _CustomColorPickerDialog(initial: initial),
  );
}

class _CustomColorPickerDialog extends StatefulWidget {
  const _CustomColorPickerDialog({required this.initial});

  final Color initial;

  @override
  State<_CustomColorPickerDialog> createState() =>
      _CustomColorPickerDialogState();
}

class _CustomColorPickerDialogState extends State<_CustomColorPickerDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hexController = TextEditingController(text: _hex);
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String get _hex {
    final c = _hsv.toColor();
    final r = (c.r * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    final g = (c.g * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    final b = (c.b * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
    return '#$r$g$b'.toUpperCase();
  }

  void _updateHexField() {
    final hex = _hex;
    if (_hexController.text != hex) {
      _hexController.text = hex;
      _hexController.selection = TextSelection.fromPosition(
        TextPosition(offset: hex.length),
      );
    }
  }

  void _applyHex(String value) {
    final cleaned = value.replaceAll('#', '').trim();
    if (cleaned.length != 6) return;
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return;
    setState(() {
      _hsv = HSVColor.fromColor(Color(0xFF000000 | parsed));
      _updateHexField();
    });
  }

  /// A slider over a gradient track: the slider's own track is
  /// transparent so only the thumb shows, over the gradient.
  Widget _gradientSlider({
    required String label,
    required double value,
    required List<Color> trackColors,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppTheme.inkSoft,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 12,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: trackColors),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Slider(
              value: value,
              onChanged: onChanged,
              activeColor: Colors.transparent,
              inactiveColor: Colors.transparent,
              thumbColor: AppTheme.ink,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final color = _hsv.toColor();
    final hueColor = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('Custom colour'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.cardBorder),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hexController,
                    decoration: const InputDecoration(
                      labelText: 'Hex',
                      hintText: '#7C5CFF',
                      isDense: true,
                    ),
                    onSubmitted: _applyHex,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _gradientSlider(
              label: 'Hue',
              value: _hsv.hue / 360,
              trackColors: const [
                Color(0xFFFF0000),
                Color(0xFFFFFF00),
                Color(0xFF00FF00),
                Color(0xFF00FFFF),
                Color(0xFF0000FF),
                Color(0xFFFF00FF),
                Color(0xFFFF0000),
              ],
              onChanged: (v) => setState(() {
                _hsv = _hsv.withHue(v * 360);
                _updateHexField();
              }),
            ),
            const SizedBox(height: 10),
            _gradientSlider(
              label: 'Saturation',
              value: _hsv.saturation,
              trackColors: [
                HSVColor.fromAHSV(1, _hsv.hue, 0, _hsv.value).toColor(),
                hueColor,
              ],
              onChanged: (v) => setState(() {
                _hsv = _hsv.withSaturation(v);
                _updateHexField();
              }),
            ),
            const SizedBox(height: 10),
            _gradientSlider(
              label: 'Brightness',
              value: _hsv.value,
              trackColors: [Colors.black, hueColor],
              onChanged: (v) => setState(() {
                _hsv = _hsv.withValue(v);
                _updateHexField();
              }),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(color),
          child: const Text('Use this colour'),
        ),
      ],
    );
  }
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
                    style: TextStyle(
                      color: AppTheme.inkSoft,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'A habit is done when all its sub-tasks for today are done.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
            if (_loadingSubtasks)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Center(child: LoadingIcon(size: 36)),
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
          style: TextStyle(
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
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 13),
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
