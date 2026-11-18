/// All Appwrite access lives in this file (plus [AppwriteService]).
///
/// Screens must never call Appwrite directly. Repositories degrade
/// gracefully when Appwrite is unconfigured: every method throws
/// [AppwriteNotConfigured], which the UI turns into a friendly notice.
///
/// For widget tests, screens accept optional repository instances; tests
/// pass in-memory fakes that subclass these classes.
///
/// Appwrite has no multi-document transactions, so writes that used to
/// happen in one batch (e.g. tick habit + update profile) are sequential
/// here. Every XP-affecting write runs through [_writeQueue], which
/// serialises them: without it, two toggles fired in quick succession
/// read the same stale XP/log state and their writes land out of order,
/// leaving the server holding a different state than the UI shows
/// (found by a live test, 14 Nov 2026). Toggles also verify their
/// writes afterwards and throw when the stored state does not match
/// the intended one, so the UI can reload the true state instead of
/// silently showing a wrong one. Toggles are idempotent by design:
/// the log document id (`{habitId}_{date}`) means a retried tick can
/// never double-grant XP, and unticking deletes the log, so re-ticking
/// after an untick grants XP again exactly once.
/// See APPWRITE.md ("Security model") for the honest write-up.
library;

import 'dart:async';

import 'package:appwrite/appwrite.dart';
import 'package:appwrite/enums.dart';
import 'package:appwrite/models.dart' as models;
// The SDK does not export HttpMethod (needed for DELETE /account in
// deleteAccount below), so it is imported from the SDK's internal
// enums file. Pinned to appwrite ^28.3.0 in pubspec.yaml.
// ignore: implementation_imports
import 'package:appwrite/src/enums.dart';

import '../config.dart';
import '../logic/xp.dart';
import 'appwrite_service.dart';
import 'local_store.dart';
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

/// Serialises all XP-affecting writes (habit/task toggles, habit and
/// task deletes). Without this, two toggles fired in quick succession
/// read the same stale profile/log state and their sequential writes
/// land out of order — the stored state then matches neither toggle.
/// The queue never stalls on an error: a failed item still lets the
/// next one run.
class _WriteQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (_) {});
    return result;
  }
}

final _writeQueue = _WriteQueue();

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
  // The in-flight session check, shared by every caller. Without this,
  // a second caller sees `_sessionLoaded == true` while the first
  // check is still waiting on the network and concludes — wrongly —
  // that there is no session (the reload logout bug, 14 Nov 2026).
  static Future<void>? _sessionLoad;
  // Friendly description of the last session-check failure for a reason
  // OTHER than "no session" (401). Null when the check succeeded or
  // simply found no session. The auth gate shows this instead of
  // silently dropping the user on the login screen.
  static String? _sessionError;
  static final _changes = StreamController<AuthChange>.broadcast();

  /// The signed-in user if the session was already loaded, else null.
  /// Use [currentUserAsync] when the session may not be loaded yet.
  static AppAuthUser? get cachedUser => _cachedUser;

  /// Last non-401 session-check failure, if any (see [_sessionError]).
  static String? get sessionError => _sessionError;

  /// Test-only: seeds the cached signed-in user so repository tests can
  /// run against a fake TablesDB without a live Appwrite session.
  static void debugSetCachedUserForTest(AppAuthUser? user) {
    _cachedUser = user;
    _sessionLoaded = user != null;
    _sessionError = null;
    _sessionLoad = null;
  }

  /// Test-only: seeds a session-check failure for auth-gate tests.
  static void debugSetSessionErrorForTest(String? message) {
    _sessionError = message;
  }

  AppAuthUser? get currentUser => _cachedUser;

  /// Loads the session once (from the stored Appwrite session, which the
  /// SDK persists on web in localStorage). Concurrent callers share the
  /// same in-flight check and all see its true result — a caller never
  /// gets a stale "signed out" while the check is still running.
  /// Safe to call repeatedly; later calls are no-ops until sign-out.
  /// A transient failure leaves the session unloaded (and records
  /// [sessionError]) so the next call retries instead of silently
  /// treating the user as signed out.
  Future<void> ensureSession() {
    if (_sessionLoaded) return Future.value();
    return _sessionLoad ??= _loadSession();
  }

  Future<void> _loadSession() async {
    try {
      final user = await _a.get();
      final isNew = _cachedUser?.uid != user.$id;
      _cachedUser = AppAuthUser.fromAppwrite(user);
      _sessionLoaded = true;
      _sessionError = null;
      // Listeners that already yielded "signed out" (e.g. the auth gate
      // while this check was in flight) must hear that a session
      // actually exists — otherwise they stay stuck on the login screen.
      if (isNew) {
        _changes.add(AuthChange(event: AuthEvent.signedIn, user: _cachedUser));
      }
    } on AppwriteException catch (e) {
      if (e.code == 401) {
        // No valid session — a normal signed-out state, not an error.
        _cachedUser = null;
        _sessionLoaded = true;
        _sessionError = null;
      } else {
        _sessionLoaded = false;
        _sessionError = _friendlyAuthError(e);
        _cachedUser = null;
      }
    } on AppwriteNotConfigured {
      _sessionLoaded = false;
      _sessionError = null;
      _cachedUser = null;
    } catch (e) {
      _sessionLoaded = false;
      _sessionError = e.toString();
      _cachedUser = null;
    } finally {
      _sessionLoad = null;
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

  Future<void> signIn({required String email, required String password}) async {
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
      final profile = Profile(id: user.$id, username: lower, displayName: name);
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
          data: {'username': lower, 'ownerUid': user.$id},
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
      await _a.createRecovery(email: email, url: AppConfig.resetContinueUrl);
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
    final uid = _cachedUser?.uid;
    try {
      await _a.deleteSession(sessionId: 'current');
    } catch (_) {
      // Even if the server-side logout fails, drop the local session.
    }
    // v2.3.0 local data (reminders + challenges) is per-account: clear
    // this account's rows so another account on the same device never
    // inherits them.
    if (uid != null) {
      try {
        final store = await LocalStore.getInstance();
        await store.clearForUser(uid);
      } catch (_) {}
    }
    _cachedUser = null;
    _sessionLoaded = false;
    _sessionError = null;
    _changes.add(const AuthChange(event: AuthEvent.signedOut));
  }

  /// Permanently deletes the signed-in account and everything in it:
  /// all rows across every table (habits, logs, tasks, follows, the
  /// username reservation and the profile row) and then the Appwrite
  /// account itself.
  ///
  /// The data is deleted first — deleting the account first would kill
  /// the session the data deletes need. If the account delete then
  /// fails, the user is left with an (empty) account and can retry; the
  /// local session is only cleared on full success.
  Future<void> deleteAccount() async {
    if (_cachedUser == null) throw const AuthException('Not signed in.');
    final uid = _cachedUser!.uid;
    await AccountRepository(db: _db).deleteAllMyData();
    try {
      final store = await LocalStore.getInstance();
      await store.clearForUser(uid);
    } catch (_) {}
    try {
      // The Dart SDK has no Account.delete() for DELETE /account, so
      // call the endpoint directly through the client's low-level call.
      await _a.client.call(
        HttpMethod.delete,
        path: '/account',
        headers: {
          'X-Appwrite-Project': AppConfig.projectId,
          'accept': 'application/json',
        },
      );
    } catch (e) {
      throw _wrapAuthError(e);
    }
    _cachedUser = null;
    _sessionLoaded = false;
    _sessionError = null;
    _changes.add(const AuthChange(event: AuthEvent.signedOut));
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
    final profile = Profile(id: userId, username: lower, displayName: name);
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
        data: {'username': lower, 'ownerUid': userId},
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
      data: {'displayName': displayName, 'bio': bio},
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
  const ToggleResult({required this.xpDelta, required this.allDone});

  final int xpDelta;
  final bool allDone;
}

String _logDocId(String habitId, String date) => '${habitId}_$date';

class HabitRepository {
  HabitRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  /// Broadcast whenever habits (or their logs) change — add, update,
  /// archive, delete or toggle. Screens live in an IndexedStack and
  /// load once, so without this a habit added on Home never appears
  /// on Profile until the app restarts (found by a live test,
  /// 14 Nov 2026). Screens subscribe in initState and reload.
  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get onChanged => _changes.stream;
  static void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Test-only hook to simulate a habit change from a fake repository.
  static void notifyChangedForTest() => _notifyChanged();

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
    return list.rows.map((doc) => Habit.fromJson(_docJson(doc))).toList();
  }

  Future<Habit> addHabit({required String title, required int color}) async {
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
    _notifyChanged();
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
    _notifyChanged();
  }

  Future<void> archiveHabit(String habitId) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'habits',
      rowId: habitId,
      data: {'archived': true},
    );
    _notifyChanged();
  }

  /// All logs ever recorded for one habit (any date), paginated.
  Future<List<HabitLog>> _listLogsForHabit(String habitId) async {
    final userId = _requireUserId();
    final all = <HabitLog>[];
    const page = 100;
    var offset = 0;
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'habit_logs',
        queries: [
          Query.equal('ownerUid', userId),
          Query.equal('habitId', habitId),
          Query.limit(page),
          Query.offset(offset),
        ],
      );
      all.addAll(list.rows.map((doc) => HabitLog.fromJson(_docJson(doc))));
      if (list.rows.length < page) break;
      offset += page;
    }
    return all;
  }

  /// Deletes a habit for good: archives the habit row, removes ALL its
  /// logs, and adjusts XP/streak so the numbers stay consistent — a
  /// habit that is done today loses 1 XP for today (the untick rule,
  /// never below 0), and the streak is recomputed from the remaining
  /// logs. The longest streak never decreases (it is a historical best).
  Future<void> deleteHabit(String habitId) async {
    return _writeQueue.run(() async {
      final profiles = ProfileRepository(db: _db);
      final logs = await _listLogsForHabit(habitId);
      final doneToday = logs.any((l) => l.logDate == todayKey() && l.completed);
      for (final log in logs) {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'habit_logs',
          rowId: log.id,
        );
      }
      final me = await profiles.fetchMyProfile();
      if (me != null) {
        final dates = await activeDates();
        final newStreak = computeStreak(dates.toSet());
        final newLastActive = dates.isEmpty ? null : dates.first;
        await profiles.applyXpAndStreak(
          xpDelta: doneToday ? -xpPerUntick : 0,
          currentStreak: newStreak,
          longestStreak: me.longestStreak,
          lastActiveDate: newLastActive,
        );
      }
      await archiveHabit(habitId);
    });
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
    return list.rows.map((doc) => HabitLog.fromJson(_docJson(doc))).toList();
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
    return list.rows.map((doc) => HabitLog.fromJson(_docJson(doc))).toList();
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

  /// Tick or untick a habit for [date]. Handles XP and streak.
  /// +2 XP on completing, -1 XP on unticking (never below 0, enforced
  /// by the clamp in [ProfileRepository.applyXpAndStreak]). No bonus.
  /// Untick deletes the log, so the day no longer counts toward the
  /// streak when its last completion is undone (streak is recomputed
  /// from the remaining logs). Returns what changed.
  ///
  /// Serialised through [_writeQueue]: two toggles fired in quick
  /// succession must run one after the other, so the second reads the
  /// first's result instead of the same stale state. After the writes,
  /// the stored log + XP + streak are re-read and compared with the
  /// intended state — a mismatch throws, so the UI reloads the true
  /// server state instead of showing a toggle that never persisted.
  Future<ToggleResult> toggleHabit({
    required Habit habit,
    required String date,
    required bool completed,
  }) async {
    return _writeQueue.run(() async {
      final profiles = ProfileRepository(db: _db);
      final me = await profiles.fetchMyProfile();
      if (me == null) throw const AuthException('Profile not found.');
      final userId = _requireUserId();
      final today = todayKey();
      final logId = _logDocId(habit.id, date);

      final existing = await _getLogOrNull(logId);
      final alreadyDone =
          existing != null && (existing['completed'] as bool? ?? false);

      final xpDelta = xpDeltaForToggle(
        completing: completed,
        wasDone: alreadyDone,
      );

      int newStreak = me.currentStreak;
      String? newLastActive = me.lastActiveDate;
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
            'xpEarned': xpPerTask,
          },
          permissions: _ownerPerms(userId),
        );

        newStreak = streakAfterTick(
          currentStreak: me.currentStreak,
          lastActiveDate: me.lastActiveDate,
          today: today,
        );
        final longest = newStreak > me.longestStreak
            ? newStreak
            : me.longestStreak;
        newLastActive = date;

        final habits = await listMyHabits();
        final todaysLogs = await listLogsForDate(date);
        final allDone = habits.isNotEmpty && todaysLogs.length >= habits.length;
        await profiles.applyXpAndStreak(
          xpDelta: xpDelta,
          currentStreak: newStreak,
          longestStreak: longest,
          lastActiveDate: newLastActive,
        );
        await _verifyToggle(
          logId: logId,
          expectDone: true,
          expectXp: (me.xp + xpDelta).clamp(0, 100000000),
          expectStreak: newStreak,
        );
        _notifyChanged();
        return ToggleResult(xpDelta: xpDelta, allDone: allDone);
      }

      if (!completed && alreadyDone) {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'habit_logs',
          rowId: logId,
        );
        // Recompute the streak from the remaining active dates.
        final dates = await activeDates();
        newStreak = computeStreak(dates.toSet());
        newLastActive = dates.isEmpty ? null : dates.first;
        await profiles.applyXpAndStreak(
          xpDelta: xpDelta,
          currentStreak: newStreak,
          longestStreak: me.longestStreak,
          lastActiveDate: newLastActive,
        );
        await _verifyToggle(
          logId: logId,
          expectDone: false,
          expectXp: (me.xp + xpDelta).clamp(0, 100000000),
          expectStreak: newStreak,
        );
      }
      _notifyChanged();
      return ToggleResult(xpDelta: xpDelta, allDone: false);
    });
  }

  /// Re-reads the stored state after a toggle and throws when it does
  /// not match the intended one. A partial write (log saved but XP
  /// not, or the reverse) must never look like a success.
  Future<void> _verifyToggle({
    required String logId,
    required bool expectDone,
    required int expectXp,
    required int expectStreak,
  }) async {
    final log = await _getLogOrNull(logId);
    final done = log != null && (log['completed'] as bool? ?? false);
    if (done != expectDone) {
      throw StateError('Habit toggle did not save properly. Please try again.');
    }
    final profile = await ProfileRepository(db: _db).fetchMyProfile();
    if (profile == null) throw const AuthException('Profile not found.');
    if (profile.xp != expectXp || profile.currentStreak != expectStreak) {
      throw StateError('Habit toggle did not save properly. Please try again.');
    }
  }
}

// ---------------------------------------------------------------------------
// Weekly + monthly tasks
// ---------------------------------------------------------------------------

class TaskRepository {
  TaskRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  /// Broadcast whenever weekly/monthly tasks change, so screens that
  /// load once (IndexedStack) refresh after a change made elsewhere.
  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get onChanged => _changes.stream;
  static void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Test-only hook to simulate a task change from a fake repository.
  static void notifyChangedForTest() => _notifyChanged();

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
    return list.rows.map((doc) => WeeklyTask.fromJson(_docJson(doc))).toList();
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
    _notifyChanged();
  }

  /// Applies an XP delta to my profile, clamped at 0, leaving streak
  /// fields untouched. Weekly/monthly tasks grant XP only — the streak
  /// stays habit-driven (it is computed from habit logs).
  Future<void> _adjustXp(int delta) async {
    if (delta == 0) return;
    final profiles = ProfileRepository(db: _db);
    final me = await profiles.fetchMyProfile();
    if (me == null) return;
    await profiles.applyXpAndStreak(
      xpDelta: delta,
      currentStreak: me.currentStreak,
      longestStreak: me.longestStreak,
      lastActiveDate: me.lastActiveDate,
    );
  }

  /// Reads the current `done` value of a task row; null when the row
  /// does not exist.
  Future<bool?> _taskDone(String tableId, String id) async {
    try {
      final doc = await _d.getRow(
        databaseId: _dbId,
        tableId: tableId,
        rowId: id,
      );
      return doc.data['done'] as bool? ?? false;
    } on AppwriteException catch (e) {
      if (e.code == 404) return null;
      rethrow;
    }
  }

  /// Toggles a weekly task: +2 XP on completing, -1 XP on unticking
  /// (never below 0). Reads the current state first so toggling to
  /// the same state grants nothing. Serialised with the other XP
  /// writes so two quick toggles cannot read the same stale state.
  Future<void> toggleWeeklyTask(String id, bool done) async {
    return _writeQueue.run(() async {
      final wasDone = await _taskDone('weekly_tasks', id);
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'weekly_tasks',
        rowId: id,
        data: {'done': done},
      );
      if (wasDone != null) {
        await _adjustXp(xpDeltaForToggle(completing: done, wasDone: wasDone));
      }
      _notifyChanged();
    });
  }

  /// Deletes a weekly task. A task that was done loses 1 XP
  /// (never below 0) — deleting must not leave phantom XP behind.
  Future<void> deleteWeeklyTask(String id) async {
    return _writeQueue.run(() async {
      final wasDone = await _taskDone('weekly_tasks', id);
      await _d.deleteRow(databaseId: _dbId, tableId: 'weekly_tasks', rowId: id);
      if (wasDone == true) {
        await _adjustXp(-xpPerUntick);
      }
      _notifyChanged();
    });
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
    return list.rows.map((doc) => MonthlyTask.fromJson(_docJson(doc))).toList();
  }

  Future<void> addMonthlyTask(String title, String month) async {
    final userId = _requireUserId();
    await _d.createRow(
      databaseId: _dbId,
      tableId: 'monthly_tasks',
      rowId: ID.unique(),
      data: {'ownerUid': userId, 'title': title, 'month': month, 'done': false},
      permissions: _ownerPerms(userId),
    );
    _notifyChanged();
  }

  /// Toggles a monthly task: same +2 / -1 XP rule as weekly tasks.
  Future<void> toggleMonthlyTask(String id, bool done) async {
    return _writeQueue.run(() async {
      final wasDone = await _taskDone('monthly_tasks', id);
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'monthly_tasks',
        rowId: id,
        data: {'done': done},
      );
      if (wasDone != null) {
        await _adjustXp(xpDeltaForToggle(completing: done, wasDone: wasDone));
      }
      _notifyChanged();
    });
  }

  /// Deletes a monthly task. A task that was done loses 1 XP
  /// (never below 0) — deleting must not leave phantom XP behind.
  Future<void> deleteMonthlyTask(String id) async {
    return _writeQueue.run(() async {
      final wasDone = await _taskDone('monthly_tasks', id);
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'monthly_tasks',
        rowId: id,
      );
      if (wasDone == true) {
        await _adjustXp(-xpPerUntick);
      }
      _notifyChanged();
    });
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
      data: {'followerUid': userId, 'followingUid': followingId},
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
    return list.rows.map((doc) => doc.data['followingUid'] as String).toList();
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

// ---------------------------------------------------------------------------
// Feedback: messages the user sends from Profile → Support.
// ---------------------------------------------------------------------------

class FeedbackRepository {
  FeedbackRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  /// Saves a feedback message to the `feedback` table (the table must
  /// exist — see scripts/setup_appwrite.mjs; without it this throws
  /// and the UI shows a friendly error instead of crashing).
  Future<FeedbackEntry> submitFeedback(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const AuthException('Write something first.');
    }
    final userId = _requireUserId();
    final doc = await _d.createRow(
      databaseId: _dbId,
      tableId: 'feedback',
      rowId: ID.unique(),
      data: {
        'userId': userId,
        'text': trimmed,
        'createdAt': DateTime.now().toIso8601String(),
      },
      permissions: _ownerPerms(userId),
    );
    return FeedbackEntry.fromJson(_docJson(doc));
  }

  /// My feedback, newest first.
  Future<List<FeedbackEntry>> listMyFeedback({int limit = 10}) async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'feedback',
      queries: [
        Query.equal('userId', userId),
        Query.orderDesc(r'$createdAt'),
        Query.limit(limit),
      ],
    );
    return list.rows
        .map((doc) => FeedbackEntry.fromJson(_docJson(doc)))
        .toList();
  }
}

// ---------------------------------------------------------------------------
// Account deletion: removes ALL of a user's data across every table.
// ---------------------------------------------------------------------------

class AccountRepository {
  AccountRepository({this._db});

  final TablesDB? _db;

  TablesDB get _d => _requireDb(_db);

  String _requireUserId() {
    final user = AuthRepository.cachedUser;
    if (user == null) throw const AuthException('Not signed in.');
    return user.uid;
  }

  /// Deletes every row in [tableId] where [field] == [value], paging
  /// 100 at a time. Rows that are already gone are ignored.
  Future<void> _deleteAllRows(
    String tableId,
    String field,
    String value,
  ) async {
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: tableId,
        queries: [Query.equal(field, value), Query.limit(100)],
      );
      if (list.rows.isEmpty) return;
      for (final row in list.rows) {
        await _deleteRowOrNull(tableId, row.$id);
      }
    }
  }

  Future<void> _deleteRowOrNull(String tableId, String rowId) async {
    try {
      await _d.deleteRow(databaseId: _dbId, tableId: tableId, rowId: rowId);
    } on AppwriteException catch (e) {
      if (e.code != 404) rethrow;
    }
  }

  /// Deletes everything the signed-in user owns: habits (including
  /// archived ones), habit logs, daily rewards, weekly + monthly tasks,
  /// follows in both directions, the username reservation and the
  /// profile row. Idempotent — calling it twice is safe.
  /// Serialised through the write queue so it cannot race an in-flight
  /// toggle that is writing XP for the same user.
  Future<void> deleteAllMyData() async {
    return _writeQueue.run(() async {
      final userId = _requireUserId();
      final profiles = ProfileRepository(db: _db);
      final profile = await profiles.fetchMyProfile();

      await _deleteAllRows('habits', 'ownerUid', userId);
      await _deleteAllRows('habit_logs', 'ownerUid', userId);
      await _deleteAllRows('daily_rewards', 'ownerUid', userId);
      await _deleteAllRows('weekly_tasks', 'ownerUid', userId);
      await _deleteAllRows('monthly_tasks', 'ownerUid', userId);
      await _deleteAllRows('follows', 'followerUid', userId);
      await _deleteAllRows('follows', 'followingUid', userId);
      if (profile != null && profile.username.isNotEmpty) {
        await _deleteRowOrNull('usernames', profile.username.toLowerCase());
      }
      await _deleteRowOrNull('users', userId);
    });
  }
}
