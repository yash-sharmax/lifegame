// Challenges (v2.3.0): create, edit during the 3-day setup window,
// lock after it, and compute challenge XP + streak from the existing
// habit logs — there is no second XP system.
//
// Stored locally (see local_store.dart) until the Appwrite `challenges`
// tables exist. Leaderboard is solo for now: habit logs are
// owner-only rows in Appwrite, so one user's client cannot read
// another user's logs. The model already carries memberIds so friends
// can join later (with a shared challenge-XP row) without a schema
// change.
library;

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../logic/challenges.dart';
import '../logic/xp.dart';
import 'local_store.dart';
import 'models.dart';
import 'repositories.dart';

/// One row of a challenge leaderboard: a member's display info plus
/// the XP they earned on the challenge's habits inside the window.
class ChallengeLeaderboardEntry {
  const ChallengeLeaderboardEntry({
    required this.userId,
    required this.displayName,
    required this.xp,
    required this.rank,
  });

  final String userId;
  final String displayName;
  final int xp;
  final int rank;
}

/// Challenge stats computed from the existing habit logs.
class ChallengeStats {
  const ChallengeStats({
    required this.xp,
    required this.streak,
    required this.daysCompleted,
    required this.totalDays,
  });

  /// XP earned on locked habits inside the active window.
  final int xp;

  /// Consecutive days in the window with at least one locked habit done.
  final int streak;

  /// Distinct days in the window with at least one locked habit done.
  final int daysCompleted;

  /// Active days elapsed so far (1 on the first active day).
  final int totalDays;
}

class ChallengeRepository {
  ChallengeRepository({this._prefs, this._store, this.habitRepo, this.profileRepo});

  // The store is acquired lazily inside each method — never in the
  // constructor (see ReminderRepository for why: an un-awaited
  // Future from the constructor surfaces as an unhandled async
  // error in widget tests, where SharedPreferences has no channel).
  final SharedPreferences? _prefs;
  final LocalStore? _store;

  Future<LocalStore> _storeFuture() async {
    if (_store != null) return _store;
    if (_prefs != null) return LocalStore(_prefs);
    return LocalStore.getInstance();
  }

  /// Injected for tests; defaults to the real repositories.
  final HabitRepository? habitRepo;
  final ProfileRepository? profileRepo;

  HabitRepository get _habits => habitRepo ?? HabitRepository();
  ProfileRepository get _profiles => profileRepo ?? ProfileRepository();

  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get onChanged => _changes.stream;
  static void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static void notifyChangedForTest() => _notifyChanged();

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  Future<List<Challenge>> listMyChallenges() async {
    final userId = _requireUserId();
    final store = await _storeFuture();
    final list = store
        .loadChallenges()
        .where((c) => c.ownerId == userId)
        .toList();
    // Newest first.
    list.sort((a, b) => b.createdDate.compareTo(a.createdDate));
    return list;
  }

  Future<Challenge?> getChallenge(String id) async {
    final list = await listMyChallenges();
    for (final c in list) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Creates a challenge. The 3-day setup window starts today; the
  /// active window starts the day after it (see logic/challenges.dart).
  /// At least one habit is required — a challenge over zero habits
  /// can never earn XP.
  Future<Challenge> createChallenge({
    required String name,
    required int durationDays,
    required List<ChallengeHabitEntry> habits,
  }) async {
    final userId = _requireUserId();
    if (name.trim().isEmpty) {
      throw const AuthException('Give your challenge a name.');
    }
    if (habits.isEmpty) {
      throw const AuthException('Pick at least one habit for the challenge.');
    }
    if (durationDays < 1 || durationDays > 365) {
      throw const AuthException('Duration must be between 1 and 365 days.');
    }
    final store = await _storeFuture();
    final challenge = Challenge(
      id: 'ch_${DateTime.now().millisecondsSinceEpoch}',
      ownerId: userId,
      name: name.trim(),
      createdDate: todayKey(),
      durationDays: durationDays,
      habits: habits,
      memberIds: [userId],
    );
    final all = store.loadChallenges()..add(challenge);
    await store.saveChallenges(all);
    _notifyChanged();
    return challenge;
  }

  /// Replaces the challenge's habits. Only allowed inside the 3-day
  /// setup window — after the lock, habits cannot change.
  Future<Challenge> updateHabits(
    Challenge challenge,
    List<ChallengeHabitEntry> habits,
  ) async {
    if (challengeHabitsLocked(createdDate: challenge.createdDate)) {
      throw const AuthException(
        'Habits are locked for this challenge — the 3-day setup window is over.',
      );
    }
    if (habits.isEmpty) {
      throw const AuthException('Pick at least one habit for the challenge.');
    }
    final store = await _storeFuture();
    final all = store.loadChallenges();
    final index = all.indexWhere((c) => c.id == challenge.id);
    if (index < 0) throw const AuthException('Challenge not found.');
    final updated = challenge.copyWith(habits: habits);
    all[index] = updated;
    await store.saveChallenges(all);
    _notifyChanged();
    return updated;
  }

  Future<void> deleteChallenge(String id) async {
    final store = await _storeFuture();
    final all = store.loadChallenges();
    all.removeWhere((c) => c.id == id);
    await store.saveChallenges(all);
    _notifyChanged();
  }

  /// Stats for one challenge, computed from the existing habit logs
  /// inside the active window.
  Future<ChallengeStats> statsFor(Challenge challenge) async {
    final start = challengeStartDate(challenge.createdDate);
    final end = challengeEndDate(
      challenge.createdDate,
      challenge.durationDays,
    );
    final logs = await _habits.listLogsInRange(start, end);
    final xp = challengeXpFromLogs(
      logs: logs,
      habitIds: challenge.habitIds,
      startDate: start,
      endDate: end,
    );
    final streak = challengeStreak(
      logs: logs,
      habitIds: challenge.habitIds,
      startDate: start,
      endDate: end,
    );
    final daysCompleted = logs
        .where(
          (l) =>
              l.completed &&
              challenge.habitIds.contains(l.habitId) &&
              l.logDate.compareTo(start) >= 0 &&
              l.logDate.compareTo(end) <= 0,
        )
        .map((l) => l.logDate)
        .toSet()
        .length;
    final today = todayKey();
    final totalDays = today.compareTo(start) < 0
        ? 0
        : (today.compareTo(end) > 0
              ? challenge.durationDays
              : daysBetweenKeys(start, today) + 1);
    return ChallengeStats(
      xp: xp,
      streak: streak,
      daysCompleted: daysCompleted,
      totalDays: totalDays,
    );
  }

  /// Leaderboard for a challenge: members ranked by challenge XP.
  /// Solo for now — only the owner's logs are readable from this
  /// client (habit logs are owner-only rows), so the board shows the
  /// owner. When friends join later, their rows come from a shared
  /// challenge-XP table instead of their private logs.
  Future<List<ChallengeLeaderboardEntry>> leaderboardFor(
    Challenge challenge,
  ) async {
    final stats = await statsFor(challenge);
    final me = await _profiles.fetchMyProfile();
    final entry = ChallengeLeaderboardEntry(
      userId: challenge.ownerId,
      displayName: me?.displayName ?? 'You',
      xp: stats.xp,
      rank: 1,
    );
    return [entry];
  }
}
