import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/logic/reminders.dart';

void main() {
  group('parseReminderTime', () {
    test('parses HH:MM', () {
      expect(parseReminderTime('07:30'), (hour: 7, minute: 30));
      expect(parseReminderTime('00:00'), (hour: 0, minute: 0));
      expect(parseReminderTime('23:59'), (hour: 23, minute: 59));
    });

    test('rejects bad input', () {
      expect(parseReminderTime(''), isNull);
      expect(parseReminderTime('7:30'), (hour: 7, minute: 30));
      expect(parseReminderTime('24:00'), isNull);
      expect(parseReminderTime('12:60'), isNull);
      expect(parseReminderTime('abc'), isNull);
      expect(parseReminderTime('07-30'), isNull);
    });
  });

  group('formatReminderTime', () {
    test('zero-pads', () {
      expect(formatReminderTime(7, 5), '07:05');
      expect(formatReminderTime(0, 0), '00:00');
      expect(formatReminderTime(23, 59), '23:59');
    });

    test('12-hour format', () {
      expect(formatReminderTime12h(0, 0), '12:00 AM');
      expect(formatReminderTime12h(7, 30), '7:30 AM');
      expect(formatReminderTime12h(12, 0), '12:00 PM');
      expect(formatReminderTime12h(19, 5), '7:05 PM');
    });
  });

  group('isReminderDueNow', () {
    final now = DateTime(2026, 11, 17, 8, 0);

    test('due when the time has passed and it never fired today', () {
      expect(
        isReminderDueNow(time: '07:30', now: now, lastFiredDateKey: null),
        isTrue,
      );
    });

    test('due exactly at the scheduled time', () {
      expect(
        isReminderDueNow(
          time: '08:00',
          now: now,
          lastFiredDateKey: null,
        ),
        isTrue,
      );
    });

    test('not due before the scheduled time', () {
      expect(
        isReminderDueNow(time: '08:30', now: now, lastFiredDateKey: null),
        isFalse,
      );
    });

    test('not due twice on the same day', () {
      expect(
        isReminderDueNow(
          time: '07:30',
          now: now,
          lastFiredDateKey: '2026-11-17',
        ),
        isFalse,
      );
    });

    test('due again on a new day', () {
      expect(
        isReminderDueNow(
          time: '07:30',
          now: now,
          lastFiredDateKey: '2026-11-16',
        ),
        isTrue,
      );
    });

    test('bad time never due', () {
      expect(
        isReminderDueNow(time: 'nope', now: now, lastFiredDateKey: null),
        isFalse,
      );
    });
  });

  group('nextOccurrence', () {
    test('today when the time is still ahead', () {
      final now = DateTime(2026, 11, 17, 8, 0);
      expect(nextOccurrence('09:00', now), DateTime(2026, 11, 17, 9, 0));
    });

    test('tomorrow when the time already passed', () {
      final now = DateTime(2026, 11, 17, 8, 0);
      expect(nextOccurrence('07:30', now), DateTime(2026, 11, 18, 7, 30));
    });

    test('now when the time is exactly now', () {
      final now = DateTime(2026, 11, 17, 8, 0);
      expect(nextOccurrence('08:00', now), DateTime(2026, 11, 17, 8, 0));
    });
  });
}
