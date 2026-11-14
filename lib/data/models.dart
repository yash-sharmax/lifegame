/// Data models mirroring the Appwrite collections (see APPWRITE.md).
///
/// Field names are camelCase, matching the document attributes.
/// `createdAt` comes from Appwrite's system `$createdAt` field (an ISO
/// string); `fromJson` also accepts a plain `createdAt` string so tests
/// can pass plain maps.
library;

DateTime? _parseDate(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// createdAt from an Appwrite document: system `$createdAt` first.
DateTime? _createdAt(Map<String, dynamic> json) =>
    _parseDate(json[r'$createdAt'] ?? json['createdAt']);

class Profile {
  const Profile({
    required this.id,
    required this.username,
    required this.displayName,
    this.avatarUrl,
    this.bio = '',
    this.xp = 0,
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.lastActiveDate,
    this.createdAt,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    username: json['username'] as String? ?? '',
    displayName: json['displayName'] as String? ?? '',
    avatarUrl: json['avatarUrl'] as String?,
    bio: json['bio'] as String? ?? '',
    xp: (json['xp'] as num?)?.toInt() ?? 0,
    currentStreak: (json['currentStreak'] as num?)?.toInt() ?? 0,
    longestStreak: (json['longestStreak'] as num?)?.toInt() ?? 0,
    lastActiveDate: json['lastActiveDate'] as String?,
    createdAt: _createdAt(json),
  );

  /// The document fields for a brand-new profile (XP starts at 0).
  /// `createdAt` is Appwrite's system `$createdAt` — never sent by us.
  Map<String, dynamic> toMap() => {
    'username': username,
    'displayName': displayName,
    'avatarUrl': avatarUrl,
    'bio': bio,
    'xp': xp,
    'currentStreak': currentStreak,
    'longestStreak': longestStreak,
    'lastActiveDate': lastActiveDate,
  };

  final String id;
  final String username;
  final String displayName;
  final String? avatarUrl;
  final String bio;
  final int xp;
  final int currentStreak;
  final int longestStreak;
  final String? lastActiveDate;
  final DateTime? createdAt;

  String get initials {
    final source = displayName.isNotEmpty ? displayName : username;
    final parts = source
        .trim()
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '?';
    String firstChar(String s) =>
        s.isEmpty ? '' : String.fromCharCode(s.runes.first);
    if (parts.length == 1) {
      final p = parts.first;
      return p.length >= 2
          ? p.substring(0, 2).toUpperCase()
          : p.toUpperCase();
    }
    return (firstChar(parts.first) + firstChar(parts.last)).toUpperCase();
  }

  Profile copyWith({
    int? xp,
    int? currentStreak,
    int? longestStreak,
    String? lastActiveDate,
    String? displayName,
    String? bio,
  }) => Profile(
    id: id,
    username: username,
    displayName: displayName ?? this.displayName,
    avatarUrl: avatarUrl,
    bio: bio ?? this.bio,
    xp: xp ?? this.xp,
    currentStreak: currentStreak ?? this.currentStreak,
    longestStreak: longestStreak ?? this.longestStreak,
    lastActiveDate: lastActiveDate ?? this.lastActiveDate,
    createdAt: createdAt,
  );
}

class Habit {
  const Habit({
    required this.id,
    required this.userId,
    required this.title,
    this.color = 0xFF7C3AED,
    this.archived = false,
    this.createdAt,
  });

  factory Habit.fromJson(Map<String, dynamic> json) => Habit(
    id: json['id'] as String,
    userId: json['ownerUid'] as String,
    title: json['title'] as String,
    color: (json['color'] as num?)?.toInt() ?? 0xFF7C3AED,
    archived: json['archived'] as bool? ?? false,
    createdAt: _createdAt(json),
  );

  /// `createdAt` is Appwrite's system `$createdAt` — never sent by us.
  Map<String, dynamic> toMap(String userId) => {
    'ownerUid': userId,
    'title': title,
    'color': color,
    'archived': archived,
  };

  final String id;
  final String userId;
  final String title;
  final int color;
  final bool archived;
  final DateTime? createdAt;
}

class HabitLog {
  const HabitLog({
    required this.id,
    required this.habitId,
    required this.userId,
    required this.logDate,
    this.completed = true,
    this.xpEarned = 0,
  });

  factory HabitLog.fromJson(Map<String, dynamic> json) => HabitLog(
    id: json['id'] as String,
    habitId: json['habitId'] as String,
    userId: json['ownerUid'] as String,
    logDate: json['date'] as String,
    completed: json['completed'] as bool? ?? true,
    xpEarned: (json['xpEarned'] as num?)?.toInt() ?? 0,
  );

  final String id;
  final String habitId;
  final String userId;
  final String logDate;
  final bool completed;
  final int xpEarned;
}

class WeeklyTask {
  const WeeklyTask({
    required this.id,
    required this.userId,
    required this.title,
    required this.weekStart,
    this.done = false,
  });

  factory WeeklyTask.fromJson(Map<String, dynamic> json) => WeeklyTask(
    id: json['id'] as String,
    userId: json['ownerUid'] as String,
    title: json['title'] as String,
    weekStart: json['weekStart'] as String,
    done: json['done'] as bool? ?? false,
  );

  final String id;
  final String userId;
  final String title;
  final String weekStart;
  final bool done;
}

class MonthlyTask {
  const MonthlyTask({
    required this.id,
    required this.userId,
    required this.title,
    required this.month,
    this.done = false,
  });

  factory MonthlyTask.fromJson(Map<String, dynamic> json) => MonthlyTask(
    id: json['id'] as String,
    userId: json['ownerUid'] as String,
    title: json['title'] as String,
    month: json['month'] as String,
    done: json['done'] as bool? ?? false,
  );

  final String id;
  final String userId;
  final String title;
  final String month;
  final bool done;
}

/// A leaderboard row: a public profile plus its global rank.
class LeaderboardEntry {
  const LeaderboardEntry({required this.profile, required this.rank});

  final Profile profile;
  final int rank;
}
