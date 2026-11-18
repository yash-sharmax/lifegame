// Dialog to set (or remove) a reminder time for one habit or task.
//
// Returns null when the dialog is cancelled, otherwise a
// [ReminderDialogResult]: [ReminderDialogResult.remove] is true when
// the user chose Remove, else [ReminderDialogResult.time] is the
// chosen "HH:MM" time and [ReminderDialogResult.enabled] is the
// on/off switch state.
library;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../logic/reminders.dart';
import '../theme.dart';

class ReminderDialogResult {
  const ReminderDialogResult({
    required this.remove,
    this.time,
    this.enabled = true,
  });

  final bool remove;
  final String? time;
  final bool enabled;
}

Future<ReminderDialogResult?> showReminderDialog(
  BuildContext context, {
  required String title,
  Reminder? existing,
}) async {
  TimeOfDay initial = const TimeOfDay(hour: 7, minute: 30);
  if (existing != null) {
    initial = TimeOfDay(hour: existing.hour, minute: existing.minute);
  }
  var selected = initial;
  var enabled = existing?.enabled ?? true;

  final result = await showDialog<ReminderDialogResult>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            const Icon(Icons.alarm, color: AppTheme.ember),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Reminder for $title',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Pick a time. The app reminds you every day at this time.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 14),
            ),
            const SizedBox(height: 16),
            InkWell(
              onTap: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: selected,
                );
                if (picked != null) {
                  setDialogState(() => selected = picked);
                }
              },
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.ember.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule, color: AppTheme.ember),
                    const SizedBox(width: 12),
                    Text(
                      formatReminderTime12h(selected.hour, selected.minute),
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    const Text(
                      'Change',
                      style: TextStyle(
                        color: AppTheme.ember,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Reminder on'),
              value: enabled,
              onChanged: (v) => setDialogState(() => enabled = v),
            ),
            const SizedBox(height: 4),
            Text(
              'On the web, reminders show while the app is open. On Android, '
              'they also fire as a notification when the app is closed.',
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(
                const ReminderDialogResult(remove: true),
              ),
              child: const Text(
                'Remove',
                style: TextStyle(color: AppTheme.flame),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              ReminderDialogResult(
                remove: false,
                time: formatReminderTime(selected.hour, selected.minute),
                enabled: enabled,
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  return result;
}
