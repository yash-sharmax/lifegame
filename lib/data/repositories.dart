/// All Supabase access lives in this file (plus [SupabaseService]).
///
/// Screens must never call Supabase directly. Repositories degrade
/// gracefully when Supabase is unconfigured: every method throws
/// [SupabaseNotConfigured], which the UI turns into a friendly notice.
///
/// For widget tests, screens accept optional repository instances; tests
/// pass in-memory fakes that subclass these classes.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../logic/xp.dart';
import 'models.dart';
import 'supabase_service.dart';

SupabaseClient _requireClient() {
  final client = SupabaseService.clientOrNull;
  if (client == null) throw SupabaseNotConfigured();
  return client;
}

String _requireUserId(SupabaseClient client) {
  final user = client.auth.currentUser;
  if (user == null) throw const AuthException('Not signed in.');
  return user.id;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class AuthRepository {
  AuthRepository({this._client});

  final SupabaseClient? _client;
  SupabaseClient get _c => _client ?? _requireClient();

  User? get currentUser => _client == null
      ? SupabaseService.clientOrNull?.auth.currentUser
      : _client.auth.currentUser;

  Stream<AuthState> get onAuthStateChange =>
      _c.auth.onAuthStateChange;

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    await _c.auth.signInWithPassword(email: email, password: password);
  }

  Future<bool> signUp({
    required String email,
    required String password,
    required String username,
    required String displayName,
  }) async {
    final res = await _c.auth.signUp(
      email: email,
      password: password,
      data: {'username': username, 'display_name': displayName},
    );
    // A session right away means email confirmation is off — the user is
    // in. Otherwise they must confirm via email first.
    return res.session != null;
  }

  Future<void> signInWithGoogle() async {
    await _c.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: AppConfig.googleRedirectUrl.isEmpty
          ? null
          : AppConfig.googleRedirectUrl,
    );
  }

  Future<void> sendPasswordReset(String email) async {
    await _c.auth.resetPasswordForEmail(email);
  }

  Future<void> updatePassword(String newPassword) async {
    await _c.auth.updateUser(UserAttributes(password: newPassword));
  }

  Future<void> signOut() async {
    await _c.auth.signOut();
  }
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

class ProfileRepository {
  ProfileRepository({this._client});

  final SupabaseClient? _client;
  SupabaseClient get _c => _client ?? _requireClient();

  Future<Profile?> fetchMyProfile() async {
    final userId = _requireUserId(_c);
    return fetchProfile(userId);
  }

  Future<Profile?> fetchProfile(String userId) async {
    final row = await _c
        .from('profiles')
        .select()
        .eq('id', userId)
        .maybeSingle();
    if (row == null) return null;
    return Profile.fromJson(row);
  }

  Future<bool> isUsernameTaken(String username) async {
    final row = await _c
        .from('profiles')
        .select('id')
        .eq('username', username.toLowerCase())
        .maybeSingle();
    return row != null;
  }

  Future<Profile> createProfile({
    required String username,
    required String displayName,
  }) async {
    final userId = _requireUserId(_c);
    final row = await _c
        .from('profiles')
        .insert({
          'id': userId,
          'username': username.toLowerCase(),
          'display_name': displayName,
        })
        .select()
        .single();
    return Profile.fromJson(row);
  }

  Future<Profile> updateProfile({
    required String displayName,
    required String bio,
  }) async {
    final userId = _requireUserId(_c);
    final row = await _c
        .from('profiles')
        .update({'display_name': displayName, 'bio': bio})
        .eq('id', userId)
        .select()
        .single();
    return Profile.fromJson(row);
  }

  Future<void> applyXpAndStreak({
    required int xpDelta,
    required int currentStreak,
    required int longestStreak,
    required String? lastActiveDate,
  }) async {
    final userId = _requireUserId(_c);
    final profile = await fetchProfile(userId);
    if (profile == null) return;
    await _c
        .from('profiles')
        .update({
          'xp': (profile.xp + xpDelta).clamp(0, 100000000),
          'current_streak': currentStreak,
          'longest_streak': longestStreak,
          'last_active_date': lastActiveDate,
        })
        .eq('id', userId);
  }

  Future<List<LeaderboardEntry>> fetchGlobalLeaderboard({
    int limit = 50,
  }) async {
    final rows = await _c
        .from('profiles')
        .select()
        .order('xp', ascending: false)
        .limit(limit);
    final profiles = (rows as List)
        .map((e) => Profile.fromJson(e as Map<String, dynamic>))
        .toList();
    return [
      for (var i = 0; i < profiles.length; i++)
        LeaderboardEntry(profile: profiles[i], rank: i + 1),
    ];
  }

  Future<List<LeaderboardEntry>> fetchFriendsLeaderboard() async {
    final userId = _requireUserId(_c);
    final social = SocialRepository(client: _client);
    final following = await social.followingIds();
    final ids = {...following, userId}.toList();
    final rows = await _c
        .from('profiles')
        .select()
        .inFilter('id', ids)
        .order('xp', ascending: false);
    final profiles = (rows as List)
        .map((e) => Profile.fromJson(e as Map<String, dynamic>))
        .toList();
    return [
      for (var i = 0; i < profiles.length; i++)
        LeaderboardEntry(profile: profiles[i], rank: i + 1),
    ];
  }

  /// 1-based global rank by XP.
  Future<int> fetchGlobalRank() async {
    final me = await fetchMyProfile();
    if (me == null) return 0;
    final res = await _c
        .from('profiles')
        .select('id')
        .gt('xp', me.xp)
        .count(CountOption.exact);
    final ahead = res.count;
    return ahead + 1;
  }

  Future<List<Profile>> searchProfiles(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final like = '%$q%';
    final rows = await _c
        .from('profiles')
        .select()
        .or('username.ilike.$like,display_name.ilike.$like')
        .order('xp', ascending: false)
        .limit(20);
    return (rows as List)
        .map((e) => Profile.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Habits + logs + XP orchestration
// ---------------------------------------------------------------------------

class ToggleResult {
  const ToggleResult({
    required this.xpDelta,
    required this.bonusGranted,
    required this.allDone,
  });

  final int xpDelta;
  final bool bonusGranted;
  final bool allDone;
}

class HabitRepository {
  HabitRepository({this._client});

  final SupabaseClient? _client;
  SupabaseClient get _c => _client ?? _requireClient();

  Future<List<Habit>> listMyHabits() async {
    final userId = _requireUserId(_c);
    final rows = await _c
        .from('habits')
        .select()
        .eq('user_id', userId)
        .eq('archived', false)
        .order('created_at', ascending: true);
    return (rows as List)
        .map((e) => Habit.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Habit> addHabit({
    required String title,
    required int color,
  }) async {
    final userId = _requireUserId(_c);
    final row = await _c
        .from('habits')
        .insert({'user_id': userId, 'title': title, 'color': color})
        .select()
        .single();
    return Habit.fromJson(row);
  }

  Future<void> updateHabit(Habit habit, {String? title, int? color}) async {
    final updates = <String, Object>{};
    if (title != null) updates['title'] = title;
    if (color != null) updates['color'] = color;
    await _c.from('habits').update(updates).eq('id', habit.id);
  }

  Future<void> archiveHabit(String habitId) async {
    await _c
        .from('habits')
        .update({'archived': true})
        .eq('id', habitId);
  }

  Future<List<HabitLog>> listLogsForDate(String date) async {
    final userId = _requireUserId(_c);
    final rows = await _c
        .from('habit_logs')
        .select()
        .eq('user_id', userId)
        .eq('log_date', date)
        .eq('completed', true);
    return (rows as List)
        .map((e) => HabitLog.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    final userId = _requireUserId(_c);
    final rows = await _c
        .from('habit_logs')
        .select()
        .eq('user_id', userId)
        .eq('completed', true)
        .gte('log_date', start)
        .lte('log_date', end)
        .order('log_date', ascending: true);
    return (rows as List)
        .map((e) => HabitLog.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Distinct dates (newest first) with at least one completed habit.
  Future<List<String>> activeDates({int limit = 370}) async {
    final userId = _requireUserId(_c);
    final rows = await _c
        .from('habit_logs')
        .select('log_date')
        .eq('user_id', userId)
        .eq('completed', true)
        .order('log_date', ascending: false)
        .limit(limit);
    final dates = <String>{};
    for (final row in rows as List) {
      dates.add(row['log_date'] as String);
    }
    return dates.toList();
  }

  Future<bool> dailyBonusGranted(String date) async {
    final userId = _requireUserId(_c);
    final row = await _c
        .from('daily_rewards')
        .select('user_id')
        .eq('user_id', userId)
        .eq('reward_date', date)
        .maybeSingle();
    return row != null;
  }

  /// Tick or untick a habit for [date]. Handles XP, streak and the
  /// all-done bonus. Returns what changed.
  Future<ToggleResult> toggleHabit({
    required Habit habit,
    required String date,
    required bool completed,
  }) async {
    final profiles = ProfileRepository(client: _client);
    final me = await profiles.fetchMyProfile();
    if (me == null) throw const AuthException('Profile not found.');
    final userId = _requireUserId(_c);
    final today = todayKey();

    // What is the current state of this log?
    final existing = await _c
        .from('habit_logs')
        .select()
        .eq('habit_id', habit.id)
        .eq('log_date', date)
        .maybeSingle();
    final alreadyDone = existing != null && existing['completed'] == true;

    var xpDelta = 0;
    var bonusGranted = false;

    if (completed && !alreadyDone) {
      await _c.from('habit_logs').upsert(
        {
          'habit_id': habit.id,
          'user_id': userId,
          'log_date': date,
          'completed': true,
          'xp_earned': xpPerHabit,
        },
        onConflict: 'habit_id,log_date',
      );
      xpDelta += xpPerHabit;

      final newStreak = streakAfterTick(
        currentStreak: me.currentStreak,
        lastActiveDate: me.lastActiveDate,
        today: today,
      );
      final longest = newStreak > me.longestStreak
          ? newStreak
          : me.longestStreak;

      // All of today's habits done? Grant the +50 bonus once per day.
      final habits = await listMyHabits();
      final todaysLogs = await listLogsForDate(date);
      final allDone = habits.isNotEmpty &&
          todaysLogs.length >= habits.length;
      if (allDone && date == today && !await dailyBonusGranted(date)) {
        await _c.from('daily_rewards').insert({
          'user_id': userId,
          'reward_date': date,
          'xp': xpDailyCompleteBonus,
          'kind': 'daily_complete',
        });
        xpDelta += xpDailyCompleteBonus;
        bonusGranted = true;
      }

      await profiles.applyXpAndStreak(
        xpDelta: xpDelta,
        currentStreak: newStreak,
        longestStreak: longest,
        lastActiveDate: date,
      );
      return ToggleResult(
        xpDelta: xpDelta,
        bonusGranted: bonusGranted,
        allDone: allDone,
      );
    }

    if (!completed && alreadyDone) {
      await _c.from('habit_logs').delete().eq('id', existing['id'] as String);
      xpDelta -= xpPerHabit;
      // Recompute the streak from the remaining active dates.
      final dates = await activeDates();
      final newStreak = computeStreak(dates.toSet());
      final newLastActive = dates.isEmpty ? null : dates.first;
      await profiles.applyXpAndStreak(
        xpDelta: xpDelta,
        currentStreak: newStreak,
        longestStreak: me.longestStreak,
        lastActiveDate: newLastActive,
      );
    }
    return ToggleResult(
      xpDelta: xpDelta,
      bonusGranted: bonusGranted,
      allDone: false,
    );
  }
}

// ---------------------------------------------------------------------------
// Weekly + monthly tasks
// ---------------------------------------------------------------------------

class TaskRepository {
  TaskRepository({this._client});

  final SupabaseClient? _client;
  SupabaseClient get _c => _client ?? _requireClient();

  Future<List<WeeklyTask>> listWeeklyTasks(String weekStart) async {
    final userId = _requireUserId(_c);
    final rows = await _c
        .from('weekly_tasks')
        .select()
        .eq('user_id', userId)
        .eq('week_start', weekStart)
        .order('created_at', ascending: true);
    return (rows as List)
        .map((e) => WeeklyTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addWeeklyTask(String title, String weekStart) async {
    final userId = _requireUserId(_c);
    await _c.from('weekly_tasks').insert({
      'user_id': userId,
      'title': title,
      'week_start': weekStart,
    });
  }

  Future<void> toggleWeeklyTask(String id, bool done) async {
    await _c.from('weekly_tasks').update({'done': done}).eq('id', id);
  }

  Future<void> deleteWeeklyTask(String id) async {
    await _c.from('weekly_tasks').delete().eq('id', id);
  }

  Future<List<MonthlyTask>> listMonthlyTasks(String month) async {
    final userId = _requireUserId(_c);
    final rows = await _c
        .from('monthly_tasks')
        .select()
        .eq('user_id', userId)
        .eq('month', month)
        .order('created_at', ascending: true);
    return (rows as List)
        .map((e) => MonthlyTask.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> addMonthlyTask(String title, String month) async {
    final userId = _requireUserId(_c);
    await _c.from('monthly_tasks').insert({
      'user_id': userId,
      'title': title,
      'month': month,
    });
  }

  Future<void> toggleMonthlyTask(String id, bool done) async {
    await _c.from('monthly_tasks').update({'done': done}).eq('id', id);
  }

  Future<void> deleteMonthlyTask(String id) async {
    await _c.from('monthly_tasks').delete().eq('id', id);
  }
}

// ---------------------------------------------------------------------------
// Social: follows, followers
// ---------------------------------------------------------------------------

class SocialRepository {
  SocialRepository({this._client});

  final SupabaseClient? _client;
  SupabaseClient get _c => _client ?? _requireClient();

  Future<void> follow(String followingId) async {
    final userId = _requireUserId(_c);
    await _c.from('follows').insert({
      'follower_id': userId,
      'following_id': followingId,
    });
  }

  Future<void> unfollow(String followingId) async {
    final userId = _requireUserId(_c);
    await _c
        .from('follows')
        .delete()
        .eq('follower_id', userId)
        .eq('following_id', followingId);
  }

  Future<bool> isFollowing(String followingId) async {
    final userId = _requireUserId(_c);
    final row = await _c
        .from('follows')
        .select('follower_id')
        .eq('follower_id', userId)
        .eq('following_id', followingId)
        .maybeSingle();
    return row != null;
  }

  Future<List<String>> followingIds() async {
    final userId = _requireUserId(_c);
    final rows = await _c
        .from('follows')
        .select('following_id')
        .eq('follower_id', userId);
    return (rows as List)
        .map((e) => e['following_id'] as String)
        .toList();
  }

  Future<int> followingCount(String userId) async {
    final res = await _c
        .from('follows')
        .select('follower_id')
        .eq('follower_id', userId)
        .count(CountOption.exact);
    return res.count;
  }

  Future<int> followersCount(String userId) async {
    final res = await _c
        .from('follows')
        .select('follower_id')
        .eq('following_id', userId)
        .count(CountOption.exact);
    return res.count;
  }
}
