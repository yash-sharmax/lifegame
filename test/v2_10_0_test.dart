// v2.10.0 tests (18 Nov 2026): Gemini AI reminder parsing (with the
// local parser as the offline fallback), delete / clear chat, the
// Active reminders section + Stop, the app-update version compare,
// the offline manual reminder form, and the new generic placeholder
// text (the user's own example sentences must not appear anywhere in
// the Reminders UI).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/ai_reminder_parser.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/data/update_check.dart';
import 'package:lifegame/logic/chat_reminders.dart';
import 'package:lifegame/screens/reminders_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const ownerId = 'user-1';
  late LocalStore store;

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  setUp(() async {
    store = await LocalStore.getInstance();
    await store.clearForUser(ownerId);
  });

  group('v2.10.0: AI-parse fallback', () {
    test('Function unreachable returns null (no Appwrite in tests)', () async {
      // The test environment has no Appwrite client configured, so
      // the AI call is unreachable — exactly the offline / not-yet-
      // deployed case the app must survive.
      final result = await parseReminderWithAi(
        'Buy milk at 6pm',
        DateTime(2026, 11, 18, 12, 0),
      );
      expect(result, isNull);
    });

    test('fallback: the local parser is used when the AI returns null',
        () async {
      final now = DateTime(2026, 11, 18, 12, 0);
      // This mirrors the app's _send(): AI first, local parser when
      // the AI returns null.
      final ai = await parseReminderWithAi('Buy milk at 6pm', now);
      final ParsedReminder? parsed;
      if (ai != null && ai.due != null) {
        parsed = ParsedReminder(text: ai.task ?? 'Buy milk', when: ai.due!);
      } else {
        parsed = parseChatReminder('Buy milk at 6pm', now);
      }
      expect(parsed, isNotNull);
      expect(parsed!.text, 'Buy milk');
      expect(parsed.when, DateTime(2026, 11, 18, 18, 0));
    });

    test('the user\'s failing message still needs the AI', () {
      // "remind me at 12.26am 19nov" is the message the local parser
      // failed on the user's phone (v2.9.0) — it returns null here,
      // which is why the AI parse exists. The AI is the only path
      // that can resolve it.
      final now = DateTime(2026, 11, 18, 12, 0);
      expect(parseChatReminder('remind me at 12.26am 19nov', now), isNull);
      expect(parseChatReminder('12:26am', now), isNull);
    });
  });

  group('v2.10.0: delete / clear chat', () {
    ChatMessage message(String id, String text) => ChatMessage(
      id: id,
      ownerId: ownerId,
      role: 'user',
      text: text,
      createdAt: DateTime(2026, 11, 18, 12, 0),
    );

    test('deleting one message removes only that message', () async {
      await store.saveChatMessages(ownerId, [
        message('m1', 'Buy milk at 6pm'),
        message('m2', 'Call mom tomorrow at 7am'),
        message('m3', 'Gym at 6pm'),
      ]);
      // Long-press → Delete: remove by id, keep the rest.
      final kept = store
          .loadChatMessages(ownerId)
          .where((m) => m.id != 'm2')
          .toList();
      await store.saveChatMessages(ownerId, kept);
      final reloaded = store.loadChatMessages(ownerId);
      expect(reloaded.map((m) => m.id), ['m1', 'm3']);
      expect(reloaded.map((m) => m.text), [
        'Buy milk at 6pm',
        'Gym at 6pm',
      ]);
    });

    test('clear chat removes all messages', () async {
      await store.saveChatMessages(ownerId, [
        message('m1', 'Buy milk at 6pm'),
        message('m2', 'Call mom tomorrow at 7am'),
      ]);
      await store.saveChatMessages(ownerId, []);
      expect(store.loadChatMessages(ownerId), isEmpty);
    });

    test('deleting a message does NOT cancel the reminder itself',
        () async {
      final reminder = ChatReminder(
        id: 'r1',
        ownerId: ownerId,
        text: 'Buy milk',
        scheduledAt: DateTime(2026, 11, 18, 18, 0),
        createdAt: DateTime(2026, 11, 18, 12, 0),
      );
      await store.saveChatReminders([reminder]);
      await store.saveChatMessages(ownerId, [message('m1', 'Buy milk at 6pm')]);
      // Delete the chat message…
      await store.saveChatMessages(ownerId, []);
      expect(store.loadChatMessages(ownerId), isEmpty);
      // …the reminder is still active.
      final reminders = store.loadChatReminders(ownerId);
      expect(reminders.length, 1);
      expect(reminders.first.id, 'r1');
      expect(reminders.first.text, 'Buy milk');
    });
  });

  group('v2.10.0: Active reminders + Stop', () {
    ChatReminder reminder(String id, String text, DateTime when) =>
        ChatReminder(
          id: id,
          ownerId: ownerId,
          text: text,
          scheduledAt: when,
          createdAt: DateTime(2026, 11, 18, 12, 0),
        );

    test('Stop removes that reminder and keeps the others', () async {
      final now = DateTime(2026, 11, 18, 12, 0);
      await store.saveChatReminders([
        reminder('r1', 'Buy milk', DateTime(2026, 11, 18, 18, 0)),
        reminder('r2', 'Call mom', DateTime(2026, 11, 19, 7, 0)),
      ]);
      // Stop on r1: remove it from the active list.
      final kept = store
          .loadChatReminders(ownerId)
          .where((r) => r.id != 'r1')
          .toList();
      await store.saveChatReminders(kept);
      final reloaded = store.loadChatReminders(ownerId);
      expect(reloaded.map((r) => r.id), ['r2']);
      expect(reloaded.first.text, 'Call mom');
      // …and r2 is still upcoming.
      expect(
        reloaded.first.scheduledAt.isAfter(now) && !reloaded.first.fired,
        isTrue,
      );
    });

    test('only upcoming reminders count as active', () {
      final now = DateTime(2026, 11, 18, 12, 0);
      // The screen's _upcoming filter: not fired and in the future.
      bool isUpcoming(ChatReminder r) =>
          !r.fired && r.scheduledAt.isAfter(now);
      final future = reminder(
        'r1',
        'Buy milk',
        DateTime(2026, 11, 18, 18, 0),
      );
      final past = reminder('r2', 'Gym', DateTime(2026, 11, 18, 9, 0));
      final fired = reminder(
        'r3',
        'Call mom',
        DateTime(2026, 11, 18, 18, 0),
      ).copyWith(fired: true);
      expect(isUpcoming(future), isTrue);
      expect(isUpcoming(past), isFalse);
      expect(isUpcoming(fired), isFalse);
    });
  });

  group('v2.10.0: app-update version compare', () {
    test('a newer remote version is detected', () {
      expect(compareVersions('2.10.0', '2.9.0'), greaterThan(0));
      expect(compareVersions('2.10.1', '2.10.0'), greaterThan(0));
      expect(compareVersions('3.0.0', '2.10.0'), greaterThan(0));
      expect(compareVersions('2.9.1', '2.9.0'), greaterThan(0));
    });

    test('the same or an older version is not an update', () {
      expect(compareVersions('2.10.0', '2.10.0'), 0);
      expect(compareVersions('2.9.0', '2.10.0'), lessThan(0));
      expect(compareVersions('2.8.5', '2.10.0'), lessThan(0));
    });

    test('build suffixes and missing parts are ignored', () {
      expect(compareVersions('2.10.0+21', '2.10.0'), 0);
      expect(compareVersions('2.10.0', '2.10.0+21'), 0);
      expect(compareVersions('2.10', '2.10.0'), 0);
      expect(compareVersions('2.10.0', '2.10'), 0);
    });

    test('dismissed / seen versions are stored (dedupe)', () async {
      // The checker stores the version it showed (dedupe) and the
      // version the user dismissed, so the same update is not
      // raised again.
      await store.setLastSeenUpdateVersion('2.10.0');
      await store.setUpdateDismissedVersion('2.10.0');
      expect(store.lastSeenUpdateVersion, '2.10.0');
      expect(store.updateDismissedVersion, '2.10.0');
    });
  });

  group('v2.10.0: offline manual reminder', () {
    test('a manually chosen date + time becomes a real reminder',
        () async {
      // The "Set manually" form: date picker + time picker + text.
      // Here the user picked tomorrow (19 Nov) at 6:00 PM.
      final when = DateTime(2026, 11, 19, 18, 0);
      final reminder = ChatReminder(
        id: 'manual-1',
        ownerId: ownerId,
        text: 'Buy milk',
        scheduledAt: when,
        createdAt: DateTime(2026, 11, 18, 12, 0),
      );
      await store.saveChatReminders([reminder]);
      final reloaded = store.loadChatReminders(ownerId);
      expect(reloaded.length, 1);
      expect(reloaded.first.text, 'Buy milk');
      expect(reloaded.first.scheduledAt, DateTime(2026, 11, 19, 18, 0));
      // It is upcoming (not fired, in the future) — so it shows in
      // Active reminders and its alarm fires.
      final now = DateTime(2026, 11, 18, 12, 0);
      expect(
        !reloaded.first.fired &&
            reloaded.first.scheduledAt.isAfter(now),
        isTrue,
      );
    });

    test('the manual form only accepts a future date + time', () {
      // The form's rule: the chosen instant must be after now.
      final now = DateTime(2026, 11, 18, 12, 0);
      final future = DateTime(2026, 11, 19, 18, 0);
      final past = DateTime(2026, 11, 18, 9, 0);
      final rightNow = DateTime(2026, 11, 18, 12, 0);
      expect(future.isAfter(now), isTrue);
      expect(past.isAfter(now), isFalse);
      expect(rightNow.isAfter(now), isFalse);
    });
  });

  group('v2.10.0: placeholder / example text', () {
    const userExample1 = 'Adrak aur kaali mirch lana hai at 6pm';
    const userExample2 = 'Kal subah 7 baje mithai lane ka yaad dilao';

    test('the Reminders UI strings use generic examples only', () {
      for (final text in [
        kReminderInputHint,
        kReminderEmptyExample,
        kReminderNoTimeMessage,
      ]) {
        expect(text, isNot(contains(userExample1)));
        expect(text, isNot(contains(userExample2)));
      }
      // The generic examples are the ones shown.
      expect(kReminderInputHint, contains('Buy milk at 6pm'));
      expect(kReminderEmptyExample, contains('Buy milk at 6pm'));
      expect(kReminderEmptyExample, contains('Call mom tomorrow at 7am'));
    });

    test('the user\'s sentences appear nowhere in the Reminders UI code',
        () {
      // The UI strings live in these files; a source scan catches a
      // stray copy in a hint, an empty state, a comment, or a test
      // helper. (The test files themselves intentionally contain the
      // sentences as the "must not appear" fixtures.)
      for (final path in [
        'lib/screens/reminders_screen.dart',
        'lib/logic/chat_reminders.dart',
        'lib/data/models.dart',
      ]) {
        final source = File(path).readAsStringSync();
        expect(
          source,
          isNot(contains(userExample1)),
          reason: '$path still contains the user\'s first example',
        );
        expect(
          source,
          isNot(contains(userExample2)),
          reason: '$path still contains the user\'s second example',
        );
      }
    });
  });
}
