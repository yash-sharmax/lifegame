// Chat-reminder parser tests (v2.9.0).
import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/logic/chat_reminders.dart';

void main() {
  group('parseChatReminder', () {
    // Reference moment: Tue 18 Nov 2026, 12:00 (noon).
    final now = DateTime(2026, 11, 18, 12, 0);

    test('example 1: "Adrak aur kaali mirch lana hai at 6pm"', () {
      final parsed = parseChatReminder(
        'Adrak aur kaali mirch lana hai at 6pm',
        now,
      );
      expect(parsed, isNotNull);
      expect(parsed!.text, 'Adrak aur kaali mirch lana hai');
      // 6pm today is still ahead of noon → today.
      expect(parsed.when, DateTime(2026, 11, 18, 18, 0));
    });

    test('example 2: "Kal subah 7 baje mithai lane ka yaad dilao"', () {
      final parsed = parseChatReminder(
        'Kal subah 7 baje mithai lane ka yaad dilao',
        now,
      );
      expect(parsed, isNotNull);
      expect(parsed!.text, 'Mithai lane ka');
      // Kal = tomorrow, subah = AM.
      expect(parsed.when, DateTime(2026, 11, 19, 7, 0));
    });

    test('time already passed today rolls to tomorrow', () {
      final parsed = parseChatReminder('Call mom at 7 am', now);
      expect(parsed, isNotNull);
      // 7am already passed at noon → tomorrow.
      expect(parsed!.when, DateTime(2026, 11, 19, 7, 0));
    });

    test('"tomorrow at 7 pm" and "aaj" day words', () {
      final tomorrow = parseChatReminder('Call mom tomorrow at 7 pm', now);
      expect(tomorrow!.when, DateTime(2026, 11, 19, 19, 0));
      final today = parseChatReminder('Call mom aaj 7 pm', now);
      expect(today!.when, DateTime(2026, 11, 18, 19, 0));
    });

    test('24-hour time and explicit date', () {
      final parsed = parseChatReminder('Gym 18:30', now);
      expect(parsed!.when, DateTime(2026, 11, 18, 18, 30));
      // 24 Dec is still ahead of 18 Nov → same year.
      final dated = parseChatReminder('Submit form 24 Dec at 6pm', now);
      expect(dated!.when, DateTime(2026, 12, 24, 18, 0));
      expect(dated.text, 'Submit form');
      // A past date rolls to next year.
      final past = parseChatReminder('Submit form 24 Aug at 6pm', now);
      expect(past!.when, DateTime(2027, 8, 24, 18, 0));
    });

    test('evening word forces PM on an ambiguous hour', () {
      final parsed = parseChatReminder('Shaam ko 6 baje chai peena hai', now);
      expect(parsed!.when, DateTime(2026, 11, 18, 18, 0));
      expect(parsed.text, 'Chai peena hai');
    });

    test('no time in the message returns null', () {
      expect(parseChatReminder('Buy milk', now), isNull);
      expect(parseChatReminder('Remind me to call mom', now), isNull);
    });

    test('confirmation line reads like the Nevermiss bot', () {
      final line = formatReminderConfirmation(
        DateTime(2026, 8, 24, 18, 0),
        'Adrak aur kaali mirch lana hai',
      );
      expect(
        line,
        'Reminder set for Mon, Aug 24, 2026 at 6:00 PM: '
        'Adrak aur kaali mirch lana hai',
      );
    });
  });
}
