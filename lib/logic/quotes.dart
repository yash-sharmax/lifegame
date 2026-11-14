/// Rotating motivational quotes — one per day of the year.
const List<String> motivationalQuotes = [
  'Small ticks. Big change.',
  'Trust the process.',
  'Win the day, win the life.',
  'You do not rise to your goals. You fall to your systems.',
  'One percent better every day.',
  'Discipline is choosing what you want most over what you want now.',
  'A little progress each day adds up to big results.',
  'Your future self is watching this moment.',
  'Do it for the person you are becoming.',
  'Motivation gets you started. Habit keeps you going.',
  'The hardest part is starting. You already started.',
  'Show up today. That is the whole secret.',
  'Champions train when nobody is watching.',
  'Every tick is a vote for the person you want to be.',
  'You are one habit away from a different life.',
];

/// Quote for a given day — stable for the whole day, rotates daily.
String quoteForDay([DateTime? now]) {
  final d = now ?? DateTime.now();
  final dayOfYear =
      d.difference(DateTime(d.year, 1, 1)).inDays;
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
