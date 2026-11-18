// AI reminder parsing (v2.10.0).
//
// The Reminders tab's local parser (logic/chat_reminders.dart) is
// brittle on real messages ("remind me at 12.26am 19nov", "12:26am"
// both failed on the user's phone). When the app is online it asks
// the "parse-reminder" Appwrite Function instead: Gemini reads the
// message and returns ONLY structured data {due, task} — a silent
// parser, never a chatbot. The function holds the Gemini key
// server-side (env var GEMINI_API_KEY); the app contains NO key.
//
// This file is the app side of that call. It NEVER throws: any
// failure (function not deployed yet, offline, timeout, bad JSON,
// a past due time) returns null and the caller falls back to the
// local parser. The AI never produces a chat reply — the app's own
// confirmation / "couldn't find a time" bubbles stay exactly as they
// are.
library;

import 'dart:async';
import 'dart:convert';

import 'package:appwrite/appwrite.dart';

import 'appwrite_service.dart';

/// What the AI parser returned: a due time and/or a task text.
/// Either may be null (no time found, or no task text).
class AiParseResult {
  const AiParseResult({this.due, this.task});

  /// The reminder time (absolute instant; the app uses it as local
  /// time). Null when the message had no usable time.
  final DateTime? due;

  /// The reminder text (time/date part removed). Null when the AI
  /// could not determine one — the caller falls back to the local
  /// parser's stripped text, or the raw message.
  final String? task;
}

/// The Appwrite Function the app calls for AI parsing.
const String kParseReminderFunctionId = 'parse-reminder';

/// Calls the "parse-reminder" function with [message] and returns
/// its {due, task}, or null on ANY failure (so the caller falls back
/// to the local parser). [now] is the reference moment; a due time
/// more than a minute in the past is treated as unusable (the local
/// parser rolls a passed time to tomorrow instead).
Future<AiParseResult?> parseReminderWithAi(
  String message,
  DateTime now,
) async {
  try {
    if (!AppwriteService.isConfigured) return null;
    final execution = await AppwriteService.functions
        .createExecution(
          functionId: kParseReminderFunctionId,
          body: jsonEncode({
            'message': message,
            'nowISO': now.toIso8601String(),
            'timezone': 'Asia/Kolkata',
          }),
        )
        .timeout(const Duration(seconds: 25));
    final body = execution.responseBody;
    if (body.isEmpty) return null;
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    DateTime? due;
    final dueRaw = decoded['due'];
    if (dueRaw is String && dueRaw.trim().isNotEmpty) {
      due = DateTime.tryParse(dueRaw.trim());
      // A due time already in the past is not usable — the local
      // parser's job is to roll it to tomorrow.
      if (due != null &&
          due.isBefore(now.subtract(const Duration(minutes: 1)))) {
        due = null;
      }
    }
    final taskRaw = decoded['task'];
    final task = taskRaw is String && taskRaw.trim().isNotEmpty
        ? taskRaw.trim()
        : null;
    if (due == null && task == null) return null;
    return AiParseResult(due: due, task: task);
  } on AppwriteException {
    return null;
  } on TimeoutException {
    return null;
  } catch (_) {
    return null;
  }
}
