/// Rotating motivational lines — one per day.
///
/// The list is bundled in the app (no network call). [lineForDay] picks
/// deterministically from the date, so the line is the SAME all day and
/// changes the next day. 36 lines, all in English, short and punchy.
/// (The Hinglish lines were replaced with English ones at the user's
/// request, 14 Nov 2026: the daily line is English only.)
const List<String> motivationalQuotes = [
  'Small ticks. Big change.',
  'Trust the process.',
  'Win the day, win the life.',
  'One percent better every day.',
  'Discipline is choosing what you want most over what you want now.',
  'A little progress each day adds up to big results.',
  'Your future self is watching this moment.',
  'Do it for the person you are becoming.',
  'Motivation gets you started. Habit keeps you going.',
  'The hardest part is starting. You already started.',
  'Show up today. That is the whole secret.',
  'Every tick is a vote for the person you want to be.',
  'You are one habit away from a different life.',
  'Champions train when nobody is watching.',
  'You do not rise to your goals. You fall to your systems.',
  'Done is better than perfect.',
  'Small steps every day.',
  'Consistency beats intensity.',
  'Small wins build big lives.',
  'Your habits are your future.',
  'Start small. Stay consistent.',
  'Today is a fresh start.',
  'Progress, not perfection.',
  'Make today count.',
  'Discipline builds freedom.',
  'One day at a time.',
  'Keep going. You are closer than you think.',
  'The best time to start was yesterday. The next best is now.',
  'Turn your goals into habits.',
  'Every day is a new level.',
  'You are stronger than your excuses.',
  'Brick by brick, day by day.',
  'Consistency is your superpower.',
  'Dream big. Tick small.',
  'Your only competition is yesterday.',
  'Focus today, shine tomorrow.',
];

/// Line for a given day — stable for the whole day, rotates daily.
/// The index moves by exactly one each day (dayOfYear % 36), so
/// tomorrow's line is always different from today's.
String quoteForDay([DateTime? now]) {
  final d = now ?? DateTime.now();
  final dayOfYear = d.difference(DateTime(d.year, 1, 1)).inDays;
  return motivationalQuotes[dayOfYear % motivationalQuotes.length];
}

/// Time-of-day greeting.
String greetingForHour([DateTime? now]) {
  final hour = (now ?? DateTime.now()).hour;
  if (hour < 5) return 'Still up?';
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  if (hour < 21) return 'Good evening';
  return 'Good night';
}
