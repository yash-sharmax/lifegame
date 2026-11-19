// v2.11.3 tests — the residual bugs from the live interactive
// retest of v2.11.2 (demo account, cloud browser), 19 Nov 2026:
//
// FAIL 1 — bare time "remind me to test at 3:55" sent at 3:53 PM
//   IST set the reminder for tomorrow 3:55 AM. Root cause: the app
//   parsed times in the DEVICE timezone and the retest browser is
//   UTC, so bare "3:55" was 03:55 UTC. Reminder times are now
//   pinned to Asia/Kolkata end to end (ist_time.dart).
// FAIL 2 — the Tip line still appeared on a bare-time SUCCESSFUL
//   set. Rule now: the Tip never appears on a successful set —
//   only a message that could not be understood gets its own
//   reply (no-time / clarification), which already carries the
//   hint.
// FAIL 3 — hide reveal worked only after pressing Enter: a stale
//   keystroke handler reset _revealActive after the keyword
//   handler revealed the chats. Fixed with a search generation
//   guard + a cached keyword (state logic — verified live by the
//   parent's retest; the pure rule, visibleChatItems with
//   revealActive, is already covered by the v2.11.2 tests).
// FAIL 4 — group list previews flipped back to "Encrypted
//   message": every _load cleared the resolved overrides and the
//   slow full-list re-resolution left the stale label showing.
//   Fixed by preserving resolved previews while the last message
//   is unchanged + a targeted newest-first preview fetch
//   (service behaviour — verified live by the parent's retest).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/ai_reminder_parser.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/logic/chat_reminders.dart';
import 'package:lifegame/logic/ist_time.dart';
import 'package:lifegame/screens/reminders_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('v2.11.3: IST helpers', () {
    test('istNow is UTC + 05:30', () {
      final utc = DateTime.now().toUtc();
      final ist = istNow();
      // The UTC fields read back as a naive DateTime, so the
      // difference to the IST fields is +05:30 on any device
      // timezone (±1 min for a clock tick between the two reads).
      final utcAsNaive = DateTime(
        utc.year,
        utc.month,
        utc.day,
        utc.hour,
        utc.minute,
      );
      expect(ist.difference(utcAsNaive).inMinutes, closeTo(330, 1));
    });

    test('istFromUtc / utcFromIst round-trip', () {
      final utc = DateTime.utc(2026, 11, 19, 10, 23);
      final ist = istFromUtc(utc);
      expect(ist, DateTime(2026, 11, 19, 15, 53));
      expect(utcFromIst(ist), utc);
    });

    test('istIso8601 carries an explicit +05:30 offset', () {
      final iso = istIso8601(DateTime(2026, 11, 19, 15, 53));
      expect(iso, '2026-11-19T15:53:00.000+05:30');
    });
  });

  group('v2.11.3 FAIL 1: bare times parse in IST', () {
    test('the retest case: "at 3:55" at 3:53 PM IST is today 3:55 PM',
        () {
      final parsed = parseChatReminder(
        'remind me to test at 3:55',
        DateTime(2026, 11, 19, 15, 53),
      );
      expect(parsed, isNotNull);
      expect(parsed!.when, DateTime(2026, 11, 19, 15, 55));
      expect(parsed.text, 'Test');
    });

    test('the user case: "at 3:09" at 3:11 PM IST rolls to tomorrow, PM kept',
        () {
      final parsed = parseChatReminder(
        'remind me to drink water at 3:09',
        DateTime(2026, 11, 19, 15, 11),
      );
      expect(parsed, isNotNull);
      // 3:09 PM today already passed → tomorrow 3:09 PM (never AM).
      expect(parsed!.when, DateTime(2026, 11, 20, 15, 9));
      expect(parsed.text, 'Drink water');
    });

    test('a bare time in the morning means AM', () {
      final parsed = parseChatReminder(
        'remind me to test at 3:55',
        DateTime(2026, 11, 19, 2, 0),
      );
      expect(parsed, isNotNull);
      expect(parsed!.when, DateTime(2026, 11, 19, 3, 55));
    });

    test('the default reference moment is IST, not the device clock',
        () {
      // No `now` passed: the parser must use istNow(). On this
      // machine the device clock is UTC — if the parser used it,
      // a bare 3:55 in the IST afternoon would infer AM.
      final ist = istNow();
      final parsed = parseChatReminder('remind me to test at 3:55');
      expect(parsed, isNotNull);
      if (ist.hour >= 12) {
        // IST afternoon/evening: bare 1–11 is PM.
        expect(parsed!.when.hour, 15);
      } else {
        expect(parsed!.when.hour, 3);
      }
    });
  });

  group('v2.11.3 FAIL 1: the AI due converts to IST', () {
    test('a future Function due (Z) returns as IST fields', () {
      // Gemini said 3:55 PM IST; the Function sends it as UTC Z.
      final result = aiResultFromResponse(<String, dynamic>{
        'due': '2026-11-19T10:25:00.000Z',
        'task': 'test',
      }, DateTime(2026, 11, 19, 15, 53));
      expect(result, isNotNull);
      expect(result!.due, DateTime(2026, 11, 19, 15, 55));
      expect(result.task, 'test');
    });

    test('a past IST due rolls forward 24h keeping PM', () {
      // 3:09 PM IST today (09:39Z), checked at 3:11 PM IST.
      final result = aiResultFromResponse(<String, dynamic>{
        'due': '2026-11-19T09:39:00.000Z',
        'task': 'drink water',
      }, DateTime(2026, 11, 19, 15, 11));
      expect(result, isNotNull);
      expect(result!.due, DateTime(2026, 11, 20, 15, 9));
      expect(result.task, 'drink water');
    });

    test('a due string with no offset is already IST fields', () {
      final result = aiResultFromResponse(<String, dynamic>{
        'due': '2026-11-19T15:55:00',
        'task': 'test',
      }, DateTime(2026, 11, 19, 15, 53));
      expect(result, isNotNull);
      expect(result!.due, DateTime(2026, 11, 19, 15, 55));
    });
  });

  group('v2.11.3 FAIL 2: no Tip on a successful set', () {
    setUpAll(() {
      SharedPreferences.setMockInitialValues({});
    });

    setUp(() async {
      final store = await LocalStore.getInstance();
      await store.clearForUser('user-1');
      AuthRepository.debugSetCachedUserForTest(
        const AppAuthUser(uid: 'user-1', email: 'test@example.com'),
      );
    });

    tearDown(() {
      AuthRepository.debugSetCachedUserForTest(null);
    });

    testWidgets('a successful set shows the confirmation, never the Tip',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(home: RemindersScreen()),
      );
      await tester.pumpAndSettle();

      // An explicit-time message: the local parser handles it
      // (the AI is not configured in tests), and the set succeeds.
      await tester.enterText(find.byType(TextField), 'Buy milk at 6pm');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(find.textContaining('Reminder set for'), findsOneWidget);
      expect(find.textContaining('Buy milk'), findsWidgets);
      expect(find.textContaining('Tip:'), findsNothing);
    });
  });
}
