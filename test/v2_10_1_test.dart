// v2.10.1 tests (18 Nov 2026): the AI past-due roll-forward fix and
// the no-time banner layout fix.
//
// Fix 1 — the v2.10.0 interactive verification found the Function
// parses "checking messages remind me at 12.26am 19nov" correctly
// (due 00:26 on 19 Nov IST), but the app DISCARDED it because the
// check ran at ~01:11 IST, ~45 min after 00:26 — then the local
// parser failed on the same message and the user got "I couldn't
// find a time". A past due time is now rolled forward 24h instead
// of being discarded (only a time more than a day old is dropped).
//
// Fix 2 — the old "Couldn't find a time — set it manually?" SnackBar
// overlaid the bottom of the screen and hid the composer after a
// failed parse. The banner is now an inline row in the layout, so
// the composer stays visible.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/ai_reminder_parser.dart';
import 'package:lifegame/data/local_store.dart';
import 'package:lifegame/data/repositories.dart';
import 'package:lifegame/screens/reminders_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('v2.10.1: AI past-due roll-forward', () {
    // v2.11.3: `now` is an Asia/Kolkata wall-clock reading and
    // `due` is returned in the same frame — the Function's
    // Z-suffixed instant is converted to IST fields first. The
    // scenarios below are the same instants as before, restated
    // in IST wall time.
    test('a due time ~45 min in the past rolls forward 24h, task kept',
        () {
      // The verification scenario: the AI parsed 12.26am on 19 Nov
      // IST (00:26 IST = 18:56 UTC on 18 Nov) and the check ran at
      // 01:11 IST on 19 Nov — 45 min later.
      final now = DateTime(2026, 11, 19, 1, 11);
      final result = aiResultFromResponse(<String, dynamic>{
        'due': '2026-11-18T18:56:00.000Z',
        'task': 'check messages',
      }, now);
      expect(result, isNotNull);
      // Same time tomorrow, in IST — the AI's parse and task are
      // preserved.
      expect(result!.due, DateTime(2026, 11, 20, 0, 26));
      expect(result.task, 'check messages');
    });

    test('a due time more than a day in the past is discarded', () {
      // 00:26 IST on 18 Nov, checked at 01:11 IST on 19 Nov — ~25h
      // in the past. Rolling it forward 24h still leaves it in the
      // past, so the due time is dropped (the caller falls back to
      // the local parser).
      final now = DateTime(2026, 11, 19, 1, 11);
      final result = aiResultFromResponse(<String, dynamic>{
        'due': '2026-11-17T18:56:00.000Z',
        'task': 'old task',
      }, now);
      expect(result, isNotNull);
      expect(result!.due, isNull);
      expect(result.task, 'old task');
    });

    test('a future due time is returned unchanged', () {
      // 12:00 UTC on 18 Nov is 17:30 IST; the AI's due 18:00 UTC
      // is 23:30 IST the same day — in the future, returned as
      // IST fields.
      final now = DateTime(2026, 11, 18, 17, 30);
      final result = aiResultFromResponse(<String, dynamic>{
        'due': '2026-11-18T18:00:00.000Z',
        'task': 'Buy milk',
      }, now);
      expect(result, isNotNull);
      expect(result!.due, DateTime(2026, 11, 18, 23, 30));
      expect(result.task, 'Buy milk');
    });
  });

  group('v2.10.1: no-time banner keeps the composer visible', () {
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

    testWidgets('the composer stays in view when the banner shows',
        (tester) async {
      // A phone-sized surface (360x640 logical) — the layout the
      // verification ran on, where the old SnackBar hid the composer.
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(home: RemindersScreen()),
      );
      await tester.pumpAndSettle();

      // Send a message with no time in it — neither the AI (not
      // configured in tests) nor the local parser finds one.
      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      // The banner is shown, with the same text and action.
      expect(
        find.text("Couldn't find a time — set it manually?"),
        findsOneWidget,
      );
      expect(find.text('Set manually'), findsOneWidget);
      // …and the composer is still fully inside the viewport.
      final composer = find.byType(TextField);
      expect(composer, findsOneWidget);
      final rect = tester.getRect(composer);
      final logicalSize =
          tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(logicalSize.height));
      // The send button is reachable too.
      final sendButton = find.byIcon(Icons.send);
      expect(sendButton, findsOneWidget);
      expect(
        tester.getRect(sendButton).bottom,
        lessThanOrEqualTo(logicalSize.height),
      );
    });
  });
}
