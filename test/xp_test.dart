import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/logic/xp.dart';

void main() {
  group('XP economy: 2 XP per task', () {
    test('one task is worth exactly 2 XP', () {
      expect(xpPerTask, 2);
    });

    test('a level still costs 100 XP, so 50 tasks', () {
      expect(50 * xpPerTask, 100);
      expect(levelForXp(100), 2);
    });
  });

  group('xpDeltaForToggle', () {
    test('completing a pending item grants +2', () {
      expect(xpDeltaForToggle(completing: true, wasDone: false), 2);
    });

    test('unticking a done item removes 1 (18 Nov 2026: was 2)', () {
      expect(xpPerUntick, 1);
      expect(xpDeltaForToggle(completing: false, wasDone: true), -1);
    });

    test('no change when the state does not change', () {
      expect(xpDeltaForToggle(completing: true, wasDone: true), 0);
      expect(xpDeltaForToggle(completing: false, wasDone: false), 0);
    });
  });

  group('warrior ranks (18 Nov 2026)', () {
    test('rank bands by level', () {
      expect(rankNameForLevel(1), 'Recruit');
      expect(rankNameForLevel(2), 'Recruit');
      expect(rankNameForLevel(3), 'Warrior');
      expect(rankNameForLevel(4), 'Warrior');
      expect(rankNameForLevel(5), 'Knight');
      expect(rankNameForLevel(6), 'Knight');
      expect(rankNameForLevel(7), 'Champion');
      expect(rankNameForLevel(8), 'Champion');
      expect(rankNameForLevel(9), 'Warlord');
      expect(rankNameForLevel(10), 'Warlord');
      expect(rankNameForLevel(11), 'Legend');
      expect(rankNameForLevel(50), 'Legend');
    });

    test('rankNameForXp derives the rank from XP', () {
      expect(rankNameForXp(0), 'Recruit');
      expect(rankNameForXp(250), 'Warrior');
      expect(rankNameForXp(1050), 'Legend');
    });
  });

  group('levelForXp', () {
    test('0 XP is level 1', () {
      expect(levelForXp(0), 1);
    });

    test('99 XP is still level 1, 100 XP is level 2', () {
      expect(levelForXp(99), 1);
      expect(levelForXp(100), 2);
      expect(levelForXp(250), 3);
    });
  });

  group('progressToNextLevel', () {
    test('0 XP is 0%, 50 XP is halfway', () {
      expect(progressToNextLevel(0), 0.0);
      expect(progressToNextLevel(50), 0.5);
      expect(progressToNextLevel(99), closeTo(0.99, 0.001));
    });

    test('xpToNextLevel', () {
      expect(xpToNextLevel(0), 100);
      expect(xpToNextLevel(30), 70);
      expect(xpToNextLevel(100), 100);
    });
  });

  group('date keys', () {
    test('dateKey formats YYYY-MM-DD', () {
      expect(dateKey(DateTime(2026, 11, 5)), '2026-11-05');
      expect(dateKey(DateTime(2026, 1, 1)), '2026-01-01');
    });

    test('weekStartKey is the Monday of the week', () {
      // Saturday 2026-11-14 → Monday 2026-11-09.
      expect(weekStartKey(DateTime(2026, 11, 14)), '2026-11-09');
      // Monday itself stays.
      expect(weekStartKey(DateTime(2026, 11, 9)), '2026-11-09');
    });

    test('monthKey formats YYYY-MM', () {
      expect(monthKey(DateTime(2026, 11, 14)), '2026-11');
    });
  });

  group('streakAfterTick', () {
    test('first ever tick starts a streak of 1', () {
      expect(
        streakAfterTick(
          currentStreak: 0,
          lastActiveDate: null,
          today: '2026-11-14',
        ),
        1,
      );
    });

    test('ticking again on the same day keeps the streak', () {
      expect(
        streakAfterTick(
          currentStreak: 4,
          lastActiveDate: '2026-11-14',
          today: '2026-11-14',
        ),
        4,
      );
    });

    test('ticking the day after yesterday continues the streak', () {
      expect(
        streakAfterTick(
          currentStreak: 4,
          lastActiveDate: '2026-11-13',
          today: '2026-11-14',
        ),
        5,
      );
    });

    test('a gap restarts the streak at 1', () {
      expect(
        streakAfterTick(
          currentStreak: 9,
          lastActiveDate: '2026-11-10',
          today: '2026-11-14',
        ),
        1,
      );
    });
  });

  group('computeStreak', () {
    test('counts backwards from today', () {
      expect(
        computeStreak({
          '2026-11-14',
          '2026-11-13',
          '2026-11-12',
          '2026-11-10',
        }, DateTime(2026, 11, 14)),
        3,
      );
    });

    test('today not active yet counts from yesterday', () {
      expect(
        computeStreak({'2026-11-13', '2026-11-12'}, DateTime(2026, 11, 14)),
        2,
      );
    });

    test('no active days is 0', () {
      expect(computeStreak({}, DateTime(2026, 11, 14)), 0);
    });
  });
}
