import 'package:flutter/material.dart';

import '../data/models.dart';

/// What the user chose in the habit edit dialog.
enum HabitEditAction { save, delete }

/// The dialog result: the chosen action plus the (possibly edited) title.
class HabitEditResult {
  const HabitEditResult(this.action, this.title);

  final HabitEditAction action;
  final String title;
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
          child: const Text('Delete', style: TextStyle(color: Colors.red)),
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
