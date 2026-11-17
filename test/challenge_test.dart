import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/data/models.dart';
import 'package:lifegame/logic/challenges.dart';

HabitLog log(String habitId, String date, [int xp = 2]) => HabitLog(
  id: '${habitId}_$date',
  habitId: habitId,
  userId: 'u1',
  logDate: date,
  completed: true,
  xpEarned: xp,
);

void main() {
  group('challenge windows', () {
    // Created Mon 17 Nov 2026, 14-day challenge.
    const created = '2026-11-17';
    const duration = 14;

    test('setup window is 3 days, then the challenge starts', () {
      expect(challengeStartDate(created), '2026-11-20');
      expect(challengeSetupEndDate(created), '2026-11-19');
      expect(challengeEndDate(created, duration), '2026-12-03');
    });

    test('phase: setup, then active, then finished', () {
      expect(
        challengePhase(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 11, 17),
        ),
        ChallengePhase.setup,
      );
      expect(
        challengePhase(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 11, 19),
        ),
        ChallengePhase.setup,
      );
      expect(
        challengePhase(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 11, 20),
        ),
        ChallengePhase.active,
      );
      expect(
        challengePhase(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 12, 3),
        ),
        ChallengePhase.active,
      );
      expect(
        challengePhase(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 12, 4),
        ),
        ChallengePhase.finished,
      );
    });

    test('habits lock the day the challenge starts', () {
      expect(
        challengeHabitsLocked(
          createdDate: created,
          now: DateTime(2026, 11, 19),
        ),
        isFalse,
      );
      expect(
        challengeHabitsLocked(
          createdDate: created,
          now: DateTime(2026, 11, 20),
        ),
        isTrue,
      );
    });

    test('days remaining counts today, 0 when finished', () {
      expect(
        challengeDaysRemaining(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 11, 17),
        ),
        14,
      );
      expect(
        challengeDaysRemaining(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 11, 20),
        ),
        14,
      );
      expect(
        challengeDaysRemaining(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 12, 3),
        ),
        1,
      );
      expect(
        challengeDaysRemaining(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 12, 4),
        ),
        0,
      );
    });

    test('progress is 0 in setup, 1 when finished', () {
      expect(
        challengeProgress(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 11, 17),
        ),
        0,
      );
      expect(
        challengeProgress(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 11, 20),
        ),
        closeTo(1 / 14, 0.001),
      );
      expect(
        challengeProgress(
          createdDate: created,
          durationDays: duration,
          now: DateTime(2026, 12, 4),
        ),
        1,
      );
    });
  });

  group('challenge XP from existing logs', () {
    const start = '2026-11-20';
    const end = '2026-12-03';
    const habitIds = {'h1', 'h2'};

    test('sums xpEarned on challenge habits inside the window only', () {
      final logs = [
        log('h1', '2026-11-20'),
        log('h1', '2026-11-21'),
        log('h2', '2026-11-21'),
        log('h1', '2026-11-19'), // setup day — does not count
        log('h1', '2026-12-04'), // after the end — does not count
        log('h3', '2026-11-21'), // not a challenge habit
      ];
      expect(
        challengeXpFromLogs(
          logs: logs,
          habitIds: habitIds,
          startDate: start,
          endDate: end,
        ),
        6,
      );
    });

    test('incomplete logs earn nothing', () {
      final logs = [
        HabitLog(
          id: 'h1_2026-11-20',
          habitId: 'h1',
          userId: 'u1',
          logDate: '2026-11-20',
          completed: false,
          xpEarned: 0,
        ),
      ];
      expect(
        challengeXpFromLogs(
          logs: logs,
          habitIds: habitIds,
          startDate: start,
          endDate: end,
        ),
        0,
      );
    });
  });

  group('challenge streak', () {
    const start = '2026-11-20';
    const end = '2026-12-03';
    const habitIds = {'h1'};

    test('counts consecutive active days walking back from today', () {
      final logs = [
        log('h1', '2026-11-20'),
        log('h1', '2026-11-21'),
        log('h1', '2026-11-22'),
      ];
      expect(
        challengeStreak(
          logs: logs,
          habitIds: habitIds,
          startDate: start,
          endDate: end,
          now: DateTime(2026, 11, 22),
        ),
        3,
      );
    });

    test('a gap breaks the streak', () {
      final logs = [
        log('h1', '2026-11-20'),
        log('h1', '2026-11-22'),
      ];
      expect(
        challengeStreak(
          logs: logs,
          habitIds: habitIds,
          startDate: start,
          endDate: end,
          now: DateTime(2026, 11, 22),
        ),
        1,
      );
    });

    test('never counts days before the challenge starts', () {
      final logs = [
        log('h1', '2026-11-19'),
        log('h1', '2026-11-20'),
      ];
      expect(
        challengeStreak(
          logs: logs,
          habitIds: habitIds,
          startDate: start,
          endDate: end,
          now: DateTime(2026, 11, 20),
        ),
        1,
      );
    });

    test('0 when nothing is done', () {
      expect(
        challengeStreak(
          logs: const [],
          habitIds: habitIds,
          startDate: start,
          endDate: end,
          now: DateTime(2026, 11, 21),
        ),
        0,
      );
    });
  });
}
