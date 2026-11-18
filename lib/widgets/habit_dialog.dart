import 'package:flutter/material.dart';

import '../data/models.dart';
import '../theme.dart';

/// What the user chose in the habit edit dialog.
enum HabitEditAction { save, delete }

/// The dialog result: the chosen action plus the (possibly edited) title.
class HabitEditResult {
  const HabitEditResult(this.action, this.title);

  final HabitEditAction action;
  final String title;
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

/// The habit edit dialog, shared by Home and Profile: rename a habit or
/// delete it. Returns null when the user cancels. The caller performs
/// the save/delete itself and reloads afterwards.
Future<HabitEditResult?> showHabitEditDialog(
  BuildContext context,
  Habit habit,
) async {
  final controller = TextEditingController(text: habit.title);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: const Text('Edit habit'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Habit name'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('delete'),
          child: const Text('Delete', style: TextStyle(color: AppTheme.flame)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop('save'),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (result == 'save') {
    return HabitEditResult(HabitEditAction.save, controller.text.trim());
  }
  if (result == 'delete') {
    return HabitEditResult(HabitEditAction.delete, controller.text.trim());
  }
  return null;
}
