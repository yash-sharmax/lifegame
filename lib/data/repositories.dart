/// All Appwrite access lives in this file (plus [AppwriteService]).
///
/// Screens must never call Appwrite directly. Repositories degrade
/// gracefully when Appwrite is unconfigured: every method throws
/// [AppwriteNotConfigured], which the UI turns into a friendly notice.
///
/// For widget tests, screens accept optional repository instances; tests
/// pass in-memory fakes that subclass these classes.
///
/// NOTE: Appwrite has no multi-document transactions. Writes that used
/// to happen in one batch (e.g. tick habit + grant bonus + update
/// profile) are sequential here — a failure midway can leave a partial
/// state (e.g. the log exists but the bonus was not granted).
/// The daily-reward document id (`{uid}_{date}`) makes the bonus
/// idempotent, so retrying a tick can never double-grant it.
/// See APPWRITE.md ("Security model") for the honest write-up.
library;

import 'dart:async';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/enums.dart';
import 'package:appwrite/models.dart' as models;

import '../config.dart';
import '../logic/xp.dart';
import 'appwrite_service.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// Small auth types (so screens never import appwrite directly)
// ---------------------------------------------------------------------------

/// Thrown for auth failures with a user-facing message.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _friendlyAuthError(AppwriteException e) {
  final type = e.type ?? '';
  final message = e.message ?? '';
  if (e.code == 401 || type == 'user_invalid_credentials') {
    return 'Wrong email or password. Try again.';
  }
  if (e.code == 409) {
    if (type.contains('user_already_exists')) {
      return 'An account with this email already exists. Log in instead.';
    }
    return 'That username is already taken. Try another one.';
  }
  if (e.code == 400) {
    if (type.contains('password')) {
      return 'Password is too weak — use at least 8 characters.';
    }
    if (type.contains('email') || type.contains('invalid')) {
      return 'That email address does not look right.';
    }
    if (message.isNotEmpty) return message;
    return 'Something went wrong. Please try again.';
  }
  if (e.code == 429) {
    return 'Too many attempts. Wait a bit, then try again.';
  }
  if (e.code == 0) {
    return 'No network connection. Check your internet and try again.';
  }
  if (message.isNotEmpty) return message;
  return 'Something went wrong. Please try again.';
}

AuthException _wrapAuthError(Object e) {
  if (e is AppwriteException) return AuthException(_friendlyAuthError(e));
  if (e is AuthException) return e;
  return AuthException(e.toString());
}

/// The signed-in user, as the UI needs it.
class AppAuthUser {
  const AppAuthUser({
    required this.uid,
    this.email,
    this.displayName,
    this.photoURL,
  });

  factory AppAuthUser.fromAppwrite(models.User user) => AppAuthUser(
    uid: user.$id,
    email: user.email,
    displayName: user.name.isEmpty ? null : user.name,
  );

  final String uid;
  final String? email;
  final String? displayName;
  final String? photoURL;
}

enum AuthEvent { signedIn, signedOut, passwordRecovery, userChanged }

class AuthChange {
  const AuthChange({required this.event, this.user});

  final AuthEvent event;
  final AppAuthUser? user;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Account _requireAccount(Account? injected) {
  final a = injected ?? AppwriteService.accountOrNull;
  if (a == null) throw AppwriteNotConfigured();
  return a;
}

TablesDB _requireDb(TablesDB? injected) {
  final d = injected ?? AppwriteService.dbOrNull;
  if (d == null) throw AppwriteNotConfigured();
  return d;
}

String get _dbId => AppConfig.databaseId;


/// Merge an Appwrite document into the shape our models expect.
Map<String, dynamic> _docJson(models.Row doc) => {
  'id': doc.$id,
  r'$createdAt': doc.$createdAt,
  ...doc.data,
};

List<String> _ownerPerms(String uid) => [
  Permission.read(Role.user(uid)),
  Permission.update(Role.user(uid)),
  Permission.delete(Role.user(uid)),
];

/// Profile documents: anyone signed in may read them (leaderboard and
/// search need this); only the owner may change them.
List<String> _profilePerms(String uid) => [
  Permission.read(Role.users()),
  Permission.update(Role.user(uid)),
  Permission.delete(Role.user(uid)),
];

/// Username reservation documents: readable by any signed-in user
/// (uniqueness checks), changeable only by the owner.
List<String> _usernamePerms(String uid) => [
  Permission.read(Role.users()),
  Permission.create(Role.user(uid)),
  Permission.update(Role.user(uid)),
  Permission.delete(Role.user(uid)),
];

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class AuthRepository {
  AuthRepository({this._auth, this._db});

  final Account? _auth;
  final TablesDB? _db;

  Account get _a => _requireAccount(_auth);
  TablesDB get _d => _requireDb(_db);

  // Session state is static: screens create fresh repository instances,
  // but the signed-in user is one per app run.
  static AppAuthUser? _cachedUser;
  static bool _sessionLoaded = false;
  static final _changes = StreamController<AuthChange>.broadcast();

  /// The signed-in user if the session was already loaded, else null.
  /// Use [currentUserAsync] when the session may not be loaded yet.
  static AppAuthUser? get cachedUser => _cachedUser;

  AppAuthUser? get currentUser => _cachedUser;

  /// Loads the session once (from the stored Appwrite session cookie).
  /// Safe to call repeatedly; later calls are no-ops until sign-out.
  Future<void> ensureSession() async {
    if (_sessionLoaded) return;
    _sessionLoaded = true;
    try {
      final user = await _a.get();
      _cachedUser = AppAuthUser.fromAppwrite(user);
    } on AppwriteException catch (e) {
      if (e.code == 401) {
        _cachedUser = null;
        return;
      }
      // Transient error (e.g. network): let a later call retry.
      _sessionLoaded = false;
      _cachedUser = null;
    } catch (_) {
      _sessionLoaded = false;
      _cachedUser = null;
    }
  }

  Future<AppAuthUser?> currentUserAsync() async {
    await ensureSession();
    return _cachedUser;
  }

  /// Emits the current session state first, then live sign-in/out events.
  Stream<AuthChange> get onAuthStateChange async* {
    await ensureSession();
    yield AuthChange(
      event: _cachedUser == null ? AuthEvent.signedOut : AuthEvent.signedIn,
      user: _cachedUser,
    );
    yield* _changes.stream;
  }

  void _setUser(AppAuthUser? user) {
    _cachedUser = user;
    _sessionLoaded = true;
    _changes.add(
      AuthChange(
        event: user == null ? AuthEvent.signedOut : AuthEvent.signedIn,
        user: user,
      ),
    );
  }

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    try {
      await _a.createEmailPasswordSession(email: email, password: password);
      final user = await _a.get();
      _setUser(AppAuthUser.fromAppwrite(user));
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  /// Creates the auth account AND the profile + username documents.
  /// Returns true when the user is signed in right away (Appwrite signs
  /// in immediately after email+password signup; email verification is
  /// not enforced).
  ///
  /// If the username document is taken in a race, the auth account
  /// already exists — the user just lands on the one-time username
  /// setup screen on next login (see [ProfileRepository.createProfile]).
  Future<bool> signUp({
    required String email,
    required String password,
    required String username,
    required String displayName,
  }) async {
    final auth = _a;
    final db = _d;
    final lower = username.toLowerCase();
    try {
      final name = displayName.isEmpty ? lower : displayName;
      final user = await auth.create(
        userId: ID.unique(),
        email: email,
        password: password,
        name: name,
      );
      await auth.createEmailPasswordSession(email: email, password: password);
      _setUser(AppAuthUser.fromAppwrite(user));
      final profile = Profile(
        id: user.$id,
        username: lower,
        displayName: name,
      );
      await db.createRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: user.$id,
        data: profile.toMap(),
        permissions: _profilePerms(user.$id),
      );
      try {
        await db.createRow(
          databaseId: _dbId,
          tableId: 'usernames',
          rowId: lower,
          data: {
            'username': lower,
            'ownerUid': user.$id,
          },
          permissions: _usernamePerms(user.$id),
        );
      } on AppwriteException catch (e) {
        if (e.code == 409) {
          throw const AuthException(
            'That username is already taken. Try another one.',
          );
        }
        rethrow;
      }
      return true;
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> signInWithGoogle() async {
    try {
      await _a.createOAuth2Session(
        provider: OAuthProvider.google,
        success: AppConfig.appUrl,
        failure: AppConfig.appUrl,
      );
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _a.createRecovery(
        email: email,
        url: AppConfig.resetContinueUrl,
      );
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  /// The `userId` + `secret` from the recovery link
  /// (`?userId=...&secret=...` on the reset continue URL).
  Future<void> confirmPasswordReset({
    required String userId,
    required String secret,
    required String newPassword,
  }) async {
    try {
      await _a.updateRecovery(
        userId: userId,
        secret: secret,
        password: newPassword,
      );
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> updatePassword(String newPassword) async {
    try {
      await _a.updatePassword(password: newPassword);
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> signOut() async {
    try {
      await _a.deleteSession(sessionId: 'current');
    } catch (_) {
      // Even if the server-side logout fails, drop the local session.
    }
    _cachedUser = null;
    _sessionLoaded = false;
    _changes.add(
      const AuthChange(event: AuthEvent.signedOut),
    );
  }
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

class ProfileRepository {
  ProfileRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  Future<Profile?> fetchMyProfile() async {
    final userId = _requireUserId();
    return fetchProfile(userId);
  }

  Future<Profile?> fetchProfile(String userId) async {
    try {
      final doc = await _d.getRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: userId,
      );
      return Profile.fromJson(_docJson(doc));
    } on AppwriteException catch (e) {
      if (e.code == 404) return null;
      rethrow;
    }
  }

  Future<bool> isUsernameTaken(String username) async {
    try {
      await _d.getRow(
        databaseId: _dbId,
        tableId: 'usernames',
        rowId: username.toLowerCase(),
      );
      return true;
    } on AppwriteException catch (e) {
      if (e.code == 404) return false;
      rethrow;
    }
  }

  Future<Profile> createProfile({
    required String username,
    required String displayName,
  }) async {
    final userId = _requireUserId();
    final lower = username.toLowerCase();
    final name = displayName.isEmpty ? lower : displayName;
    final profile = Profile(
      id: userId,
      username: lower,
      displayName: name,
    );
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: userId,
        data: profile.toMap(),
        permissions: _profilePerms(userId),
      );
    } on AppwriteException catch (e) {
      if (e.code == 409) {
        // Profile already exists (e.g. double-submit): return it.
        final existing = await fetchProfile(userId);
        if (existing != null) return existing;
      }
      rethrow;
    }
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'usernames',
        rowId: lower,
        data: {
          'username': lower,
          'ownerUid': userId,
        },
        permissions: _usernamePerms(userId),
      );
    } on AppwriteException catch (e) {
      if (e.code == 409) {
        throw const AuthException(
          'That username is already taken. Try another one.',
        );
      }
      rethrow;
    }
    return profile;
  }

  Future<Profile> updateProfile({
    required String displayName,
    required String bio,
  }) async {
    final userId = _requireUserId();
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'users',
      rowId: userId,
      data: {
        'displayName': displayName,
        'bio': bio,
      },
    );
    final updated = await fetchProfile(userId);
    if (updated == null) throw const AuthException('Profile not found.');
    return updated;
  }

  Future<void> applyXpAndStreak({
    required int xpDelta,
    required int currentStreak,
    required int longestStreak,
    required String? lastActiveDate,
  }) async {
    final userId = _requireUserId();
    final profile = await fetchProfile(userId);
    if (profile == null) return;
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'users',
      rowId: userId,
      data: {
        'xp': (profile.xp + xpDelta).clamp(0, 100000000),
        'currentStreak': currentStreak,
        'longestStreak': longestStreak,
        'lastActiveDate': lastActiveDate,
      },
    );
  }

  Future<List<LeaderboardEntry>> fetchGlobalLeaderboard({
    int limit = 50,
  }) async {
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'users',
      queries: [Query.orderDesc('xp'), Query.limit(limit)],
    );
    final profiles = list.rows
        .map((doc) => Profile.fromJson(_docJson(doc)))
        .toList();
    return [
      for (var i = 0; i < profiles.length; i++)
        LeaderboardEntry(profile: profiles[i], rank: i + 1),
    ];
  }

  Future<List<LeaderboardEntry>> fetchFriendsLeaderboard() async {
    final userId = _requireUserId();
    final social = SocialRepository(db: _db);
    final following = await social.followingIds();
    final ids = {...following, userId}.toList();
    final profiles = <Profile>[];
    for (final id in ids) {
      final profile = await fetchProfile(id);
      if (profile != null) profiles.add(profile);
    }
    profiles.sort((a, b) => b.xp.compareTo(a.xp));
    return [
      for (var i = 0; i < profiles.length; i++)
        LeaderboardEntry(profile: profiles[i], rank: i + 1),
    ];
  }

  /// 1-based global rank by XP.
  Future<int> fetchGlobalRank() async {
    final me = await fetchMyProfile();
    if (me == null) return 0;
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'users',
      queries: [Query.greaterThan('xp', me.xp), Query.limit(1)],
    );
    return list.total + 1;
  }

  Future<List<Profile>> searchProfiles(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    // Username prefix search. Appwrite has no LIKE/ILIKE; only username
    // prefixes match (display names are not searched — see APPWRITE.md).
    // Usernames are stored lowercase.
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'usernames',
      queries: [Query.startsWith('username', q), Query.limit(20)],
    );
    final profiles = <Profile>[];
    for (final doc in list.rows) {
      final ownerUid = doc.data['ownerUid'] as String?;
      if (ownerUid == null) continue;
      final profile = await fetchProfile(ownerUid);
      if (profile != null) profiles.add(profile);
    }
    return profiles;
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

String _logDocId(String habitId, String date) => '${habitId}_$date';

class HabitRepository {
  HabitRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  Future<List<Habit>> listMyHabits() async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'habits',
      queries: [
        Query.equal('ownerUid', userId),
        Query.equal('archived', false),
        Query.orderAsc(r'$createdAt'),
      ],
    );
    return list.rows
        .map((doc) => Habit.fromJson(_docJson(doc)))
        .toList();
  }

  Future<Habit> addHabit({
    required String title,
    required int color,
  }) async {
    final userId = _requireUserId();
    final doc = await _d.createRow(
      databaseId: _dbId,
      tableId: 'habits',
      rowId: ID.unique(),
      data: {
        'ownerUid': userId,
        'title': title,
        'color': color,
        'archived': false,
      },
      permissions: _ownerPerms(userId),
    );
    return Habit(id: doc.$id, userId: userId, title: title, color: color);
  }

  Future<void> updateHabit(Habit habit, {String? title, int? color}) async {
    final updates = <String, Object>{};
    if (title != null) updates['title'] = title;
    if (color != null) updates['color'] = color;
    if (updates.isEmpty) return;
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'habits',
      rowId: habit.id,
      data: updates,
    );
  }

  Future<void> archiveHabit(String habitId) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'habits',
      rowId: habitId,
      data: {'archived': true},
    );
  }

  Future<Map<String, dynamic>?> _getLogOrNull(String logId) async {
    try {
      final doc = await _d.getRow(
        databaseId: _dbId,
        tableId: 'habit_logs',
        rowId: logId,
      );
      return _docJson(doc);
    } on AppwriteException catch (e) {
      if (e.code == 404) return null;
      rethrow;
    }
  }

  Future<List<HabitLog>> listLogsForDate(String date) async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'habit_logs',
      queries: [
        Query.equal('ownerUid', userId),
        Query.equal('date', date),
        Query.equal('completed', true),
      ],
    );
    return list.rows
        .map((doc) => HabitLog.fromJson(_docJson(doc)))
        .toList();
  }

  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'habit_logs',
      queries: [
        Query.equal('ownerUid', userId),
        Query.equal('completed', true),
        Query.greaterThanEqual('date', start),
        Query.lessThanEqual('date', end),
        Query.orderAsc('date'),
      ],
    );
    return list.rows
        .map((doc) => HabitLog.fromJson(_docJson(doc)))
        .toList();
  }

  /// Distinct dates (newest first) with at least one completed habit.
  Future<List<String>> activeDates({int limit = 370}) async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'habit_logs',
      queries: [
        Query.equal('ownerUid', userId),
        Query.equal('completed', true),
        Query.orderDesc('date'),
        Query.limit(limit),
      ],
    );
    final dates = <String>{};
    for (final doc in list.rows) {
      final date = doc.data['date'] as String?;
      if (date != null) dates.add(date);
    }
    return dates.toList();
  }

  Future<bool> dailyBonusGranted(String date) async {
    final userId = _requireUserId();
    try {
      await _d.getRow(
        databaseId: _dbId,
        tableId: 'daily_rewards',
        rowId: '${userId}_$date',
      );
      return true;
    } on AppwriteException catch (e) {
      if (e.code == 404) return false;
      rethrow;
    }
  }

  /// Tick or untick a habit for [date]. Handles XP, streak and the
  /// all-done bonus. Returns what changed.
  Future<ToggleResult> toggleHabit({
    required Habit habit,
    required String date,
    required bool completed,
  }) async {
    final profiles = ProfileRepository(db: _db);
    final me = await profiles.fetchMyProfile();
    if (me == null) throw const AuthException('Profile not found.');
    final userId = _requireUserId();
    final today = todayKey();
    final logId = _logDocId(habit.id, date);

    final existing = await _getLogOrNull(logId);
    final alreadyDone =
        existing != null && (existing['completed'] as bool? ?? false);

    var xpDelta = 0;
    var bonusGranted = false;

    if (completed && !alreadyDone) {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'habit_logs',
        rowId: logId,
        data: {
          'ownerUid': userId,
          'habitId': habit.id,
          'date': date,
          'completed': true,
          'xpEarned': xpPerHabit,
        },
        permissions: _ownerPerms(userId),
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
      // The reward document id ({uid}_{date}) makes it idempotent: a
      // 409 means it was already granted (e.g. a retried tick).
      final habits = await listMyHabits();
      final todaysLogs = await listLogsForDate(date);
      final allDone = habits.isNotEmpty &&
          todaysLogs.length >= habits.length;
      if (allDone && date == today && !await dailyBonusGranted(date)) {
        try {
          await _d.createRow(
            databaseId: _dbId,
            tableId: 'daily_rewards',
            rowId: '${userId}_$date',
            data: {
              'ownerUid': userId,
              'date': date,
              'xp': xpDailyCompleteBonus,
              'kind': 'daily_complete',
            },
            permissions: _ownerPerms(userId),
          );
          xpDelta += xpDailyCompleteBonus;
          bonusGranted = true;
        } on AppwriteException catch (e) {
          if (e.code != 409) rethrow;
        }
      }
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: userId,
        data: {
          'xp': (me.xp + xpDelta).clamp(0, 100000000),
          'currentStreak': newStreak,
          'longestStreak': longest,
          'lastActiveDate': date,
        },
      );
      return ToggleResult(
        xpDelta: xpDelta,
        bonusGranted: bonusGranted,
        allDone: allDone,
      );
    }

    if (!completed && alreadyDone) {
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'habit_logs',
        rowId: logId,
      );
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
  TaskRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  Future<List<WeeklyTask>> listWeeklyTasks(String weekStart) async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'weekly_tasks',
      queries: [
        Query.equal('ownerUid', userId),
        Query.equal('weekStart', weekStart),
        Query.orderAsc(r'$createdAt'),
      ],
    );
    return list.rows
        .map((doc) => WeeklyTask.fromJson(_docJson(doc)))
        .toList();
  }

  Future<void> addWeeklyTask(String title, String weekStart) async {
    final userId = _requireUserId();
    await _d.createRow(
      databaseId: _dbId,
      tableId: 'weekly_tasks',
      rowId: ID.unique(),
      data: {
        'ownerUid': userId,
        'title': title,
        'weekStart': weekStart,
        'done': false,
      },
      permissions: _ownerPerms(userId),
    );
  }

  Future<void> toggleWeeklyTask(String id, bool done) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'weekly_tasks',
      rowId: id,
      data: {'done': done},
    );
  }

  Future<void> deleteWeeklyTask(String id) async {
    await _d.deleteRow(
      databaseId: _dbId,
      tableId: 'weekly_tasks',
      rowId: id,
    );
  }

  Future<List<MonthlyTask>> listMonthlyTasks(String month) async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'monthly_tasks',
      queries: [
        Query.equal('ownerUid', userId),
        Query.equal('month', month),
        Query.orderAsc(r'$createdAt'),
      ],
    );
    return list.rows
        .map((doc) => MonthlyTask.fromJson(_docJson(doc)))
        .toList();
  }

  Future<void> addMonthlyTask(String title, String month) async {
    final userId = _requireUserId();
    await _d.createRow(
      databaseId: _dbId,
      tableId: 'monthly_tasks',
      rowId: ID.unique(),
      data: {
        'ownerUid': userId,
        'title': title,
        'month': month,
        'done': false,
      },
      permissions: _ownerPerms(userId),
    );
  }

  Future<void> toggleMonthlyTask(String id, bool done) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'monthly_tasks',
      rowId: id,
      data: {'done': done},
    );
  }

  Future<void> deleteMonthlyTask(String id) async {
    await _d.deleteRow(
      databaseId: _dbId,
      tableId: 'monthly_tasks',
      rowId: id,
    );
  }
}

// ---------------------------------------------------------------------------
// Social: follows, followers
// ---------------------------------------------------------------------------

class SocialRepository {
  SocialRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  String _followDocId(String followerId, String followingId) =>
      '${followerId}_$followingId';

  Future<void> follow(String followingId) async {
    final userId = _requireUserId();
    await _d.createRow(
      databaseId: _dbId,
      tableId: 'follows',
      rowId: _followDocId(userId, followingId),
      data: {
        'followerUid': userId,
        'followingUid': followingId,
      },
      permissions: [
        Permission.read(Role.users()),
        Permission.update(Role.user(userId)),
        Permission.delete(Role.user(userId)),
      ],
    );
  }

  Future<void> unfollow(String followingId) async {
    final userId = _requireUserId();
    await _d.deleteRow(
      databaseId: _dbId,
      tableId: 'follows',
      rowId: _followDocId(userId, followingId),
    );
  }

  Future<bool> isFollowing(String followingId) async {
    final userId = _requireUserId();
    try {
      await _d.getRow(
        databaseId: _dbId,
        tableId: 'follows',
        rowId: _followDocId(userId, followingId),
      );
      return true;
    } on AppwriteException catch (e) {
      if (e.code == 404) return false;
      rethrow;
    }
  }

  Future<List<String>> followingIds() async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'follows',
      queries: [Query.equal('followerUid', userId)],
    );
    return list.rows
        .map((doc) => doc.data['followingUid'] as String)
        .toList();
  }

  Future<int> followingCount(String userId) async {
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'follows',
      queries: [Query.equal('followerUid', userId), Query.limit(1)],
    );
    return list.total;
  }

  Future<int> followersCount(String userId) async {
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'follows',
      queries: [Query.equal('followingUid', userId), Query.limit(1)],
    );
    return list.total;
  }
}
