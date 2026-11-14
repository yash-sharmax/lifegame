/// Rotating motivational lines — one per day.
///
/// The list is bundled in the app (no network call). [lineForDay] picks
/// deterministically from the date, so the line is the SAME all day and
/// changes the next day. 36 lines: a mix of English and Hinglish, short
/// and punchy.
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
  'Aaj ka kaam, aaj hi. Kal par mat chhodo.',
  'Chhota kadam, bada badlav.',
  'Roz thoda-thoda, phir dekho kamaal.',
  'Mehnat aaj ki, pehchan kal ki.',
  'Haar mat maano, bas tick karte jao.',
  'Khud se vaada, khud hi nibhana.',
  'Aaj jeeta, to kal bhi jeetega.',
  'Sapne bade, shuruaat chhoti.',
  'Rukna nahi, jhukna nahi — bas karte jana.',
  'Kal ka tum, aaj ke tum se behtar hoga.',
  'Ek din me nahi, har din me farak hai.',
  'Aalas ko harao, aadat ko jitao.',
  'Shuruaat karo, rasta khud banega.',
  'Jeet wahi, jo roz ladta hai.',
  'Aaj ka ek tick, kal ki jeet.',
  'Bada socho, chhota shuru karo.',
  'Apne liye karo, dikhawe ke liye nahi.',
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
