import 'package:flutter_test/flutter_test.dart';
import 'package:lifegame/logic/quotes.dart';

void main() {
  group('daily motivational line', () {
    test('at least 30 lines, all non-empty and unique', () {
      expect(motivationalQuotes.length, greaterThanOrEqualTo(30));
      expect(motivationalQuotes.every((q) => q.trim().isNotEmpty), isTrue);
      expect(motivationalQuotes.toSet().length, motivationalQuotes.length);
    });

    test('the list is English only', () {
      // User feedback, 14 Nov 2026: the daily line is English only —
      // no Hinglish lines remain.
      expect(
        motivationalQuotes,
        contains('Small wins build big lives.'),
      );
      expect(motivationalQuotes, contains('Your only competition is yesterday.'));
      expect(motivationalQuotes, contains('Trust the process.'));
      expect(
        motivationalQuotes,
        isNot(contains('Aaj ka kaam, aaj hi. Kal par mat chhodo.')),
      );
      expect(
        motivationalQuotes,
        isNot(contains('Aalas ko harao, aadat ko jitao.')),
      );
      // English only: every line is plain ASCII.
      for (final q in motivationalQuotes) {
        expect(q.codeUnits.every((c) => c < 128), isTrue, reason: q);
      }
    });

    test('the same date always gives the same line', () {
      final morning = DateTime(2026, 11, 14, 6, 30);
      final night = DateTime(2026, 11, 14, 23, 59);
      expect(quoteForDay(morning), quoteForDay(night));
      expect(quoteForDay(morning), quoteForDay(DateTime(2026, 11, 14)));
    });

    test('consecutive days give a different line', () {
      final today = quoteForDay(DateTime(2026, 11, 14));
      expect(quoteForDay(DateTime(2026, 11, 15)), isNot(today));
      expect(quoteForDay(DateTime(2026, 11, 13)), isNot(today));
    });

    test('a full cycle covers every line exactly once', () {
      // The list has 36 lines and the index moves by one per day, so 36
      // consecutive days must yield 36 distinct lines.
      final seen = {
        for (var i = 0; i < motivationalQuotes.length; i++)
          quoteForDay(DateTime(2026, 1, 1).add(Duration(days: i))),
      };
      expect(seen.length, motivationalQuotes.length);
    });
  });
}
