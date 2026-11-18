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
import '../logic/subtasks.dart';
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

  /// Broadcast whenever the profile itself changes (XP / streak
  /// corrected by the derived-XP sync) — screens that show XP reload.
  /// Habit/task changes have their own streams; this one is only for
  /// profile-level corrections made without a habit or task change.
  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get onChanged => _changes.stream;
  static void _notifyChanged() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Test-only hook to simulate a profile change from a fake.
  static void notifyChangedForTest() => _notifyChanged();

  // The derived-XP sync runs once per app session (see
  // [syncDerivedXpOnce]). A failed sync is retried next launch.
  static bool _derivedXpSynced = false;

  /// Test-only: lets a test run the once-per-session sync again.
  static void debugResetDerivedXpSyncForTest() {
    _derivedXpSynced = false;
  }

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
    await writeXpAndStreak(
      current: profile,
      xpDelta: xpDelta,
      currentStreak: currentStreak,
      longestStreak: longestStreak,
      lastActiveDate: lastActiveDate,
    );
  }

  /// Writes XP + streak for [current] without re-fetching the profile.
  /// The caller already holds the profile (e.g. a toggle just read it),
  /// so this is one update instead of a read + an update.
  Future<void> writeXpAndStreak({
    required Profile current,
    required int xpDelta,
    required int currentStreak,
    required int longestStreak,
    required String? lastActiveDate,
  }) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'users',
      rowId: current.id,
      data: {
        'xp': (current.xp + xpDelta).clamp(0, 100000000),
        'currentStreak': currentStreak,
        'longestStreak': longestStreak,
        'lastActiveDate': lastActiveDate,
      },
    );
  }

  /// Counts rows in [tableId] matching [queries] without fetching them:
  /// limit 1, read the filtered total. Appwrite returns the full
  /// filtered count in `total` even when only one row is returned.
  Future<int> _countRows(String tableId, List<String> queries) async {
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: tableId,
      queries: [...queries, Query.limit(1)],
    );
    return list.total;
  }

  /// Recomputes my XP from the source of truth and writes it back.
  ///
  /// XP is DERIVED (18 Nov 2026): 2 XP per completed habit log (any
  /// date) + 2 XP per done weekly/monthly task — never an accumulated
  /// counter, never a bonus, never a penalty. This heals drift from
  /// the old rules (the -1 untick, the +1 first-completion bonus, the
  /// removed +50 daily bonus): whatever the stored XP was, it becomes
  /// exactly 2 × what is actually completed. The streak is recomputed
  /// from the active dates the same way; the longest streak never
  /// decreases (it is a historical best). Serialised through the
  /// write queue so it cannot race an in-flight toggle.
  Future<void> recomputeDerivedXp() async {
    return _writeQueue.run(_recomputeDerivedXpNow);
  }

  /// The derived-XP recompute itself, WITHOUT the queue. Only call from
  /// inside a [_writeQueue] job (same library — [HabitRepository]
  /// uses it so a toggle reconciles XP + streak from the logs in the
  /// same serialised step as the log write). Calling it directly would
  /// let it race an in-flight toggle.
  Future<void> _recomputeDerivedXpNow() async {
    final userId = _requireUserId();
    final me = await fetchProfile(userId);
    if (me == null) return;
    final habitLogs = await _countRows('habit_logs', [
      Query.equal('ownerUid', userId),
      Query.equal('completed', true),
    ]);
    final weeklyDone = await _countRows('weekly_tasks', [
      Query.equal('ownerUid', userId),
      Query.equal('done', true),
    ]);
    final monthlyDone = await _countRows('monthly_tasks', [
      Query.equal('ownerUid', userId),
      Query.equal('done', true),
    ]);
    final derivedXp = xpPerTask * (habitLogs + weeklyDone + monthlyDone);
    final dates = await HabitRepository(db: _db).activeDates();
    final newStreak = computeStreak(dates.toSet());
    final newLastActive = dates.isEmpty ? null : dates.first;
    final longest = newStreak > me.longestStreak ? newStreak : me.longestStreak;
    if (derivedXp == me.xp &&
        newStreak == me.currentStreak &&
        newLastActive == me.lastActiveDate &&
        longest == me.longestStreak) {
      return;
    }
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'users',
      rowId: userId,
      data: {
        'xp': derivedXp,
        'currentStreak': newStreak,
        'longestStreak': longest,
        'lastActiveDate': newLastActive,
      },
    );
    _notifyChanged();
  }

  /// Runs the derived-XP sync once per app session, in the
  /// background. Best-effort: a failure (e.g. no network, or no
  /// signed-in user in a test) must never break the app — the toggle
  /// paths keep XP in sync with full-reversal deltas, so a missed
  /// sync only leaves old drift unhealed until the next launch.
  Future<void> syncDerivedXpOnce() async {
    if (_derivedXpSynced) return;
    _derivedXpSynced = true;
    try {
      await recomputeDerivedXp();
    } catch (_) {
      // Best-effort (see above).
    }
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
    final habits = list.rows
        .map((doc) => Habit.fromJson(_docJson(doc)))
        .toList();
    // Overlay on-device notes (the fallback while the live `habits`
    // table has no `notes` attribute — see updateHabit): a locally
    // stored note wins, including an empty one (the user cleared it).
    final localNotes = await _localNotesMap(userId);
    if (localNotes.isEmpty) return habits;
    return habits
        .map(
          (h) => localNotes.containsKey(h.id)
              ? h.copyWith(notes: localNotes[h.id]!)
              : h,
        )
        .toList();
  }

  /// On-device notes for [userId], keyed by habit id. Best-effort:
  /// in an environment without working SharedPreferences (e.g. a
  /// widget test) this returns an empty map instead of throwing.
  Future<Map<String, String>> _localNotesMap(String userId) async {
    try {
      final store = await LocalStore.getInstance();
      final all = store.loadHabitNotes();
      return {
        for (final entry in all.entries)
          if (entry.key.startsWith('$userId|'))
            entry.key.substring(userId.length + 1): entry.value,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveLocalNote(String habitId, String notes) async {
    try {
      final store = await LocalStore.getInstance();
      await store.saveHabitNote(_requireUserId(), habitId, notes);
    } catch (_) {
      // Best-effort only (see _localNotesMap).
    }
  }

  Future<void> _deleteLocalNote(String habitId) async {
    try {
      final store = await LocalStore.getInstance();
      await store.deleteHabitNote(_requireUserId(), habitId);
    } catch (_) {
      // Best-effort only (see _localNotesMap).
    }
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

  /// Whether the live `habits` table has the `notes` attribute. It does
  /// not (18 Nov 2026) — the attribute is defined in
  /// scripts/setup_appwrite.mjs for a future re-run. Until then notes
  /// fall back to on-device storage (LocalStore). Once a 400 is seen,
  /// this session stops trying Appwrite for notes.
  static bool _notesColumnAvailable = true;

  Future<void> updateHabit(
    Habit habit, {
    String? title,
    int? color,
    String? notes,
  }) async {
    final updates = <String, Object>{};
    if (title != null) updates['title'] = title;
    if (color != null) updates['color'] = color;
    if (notes != null) {
      if (_notesColumnAvailable) {
        try {
          await _d.updateRow(
            databaseId: _dbId,
            tableId: 'habits',
            rowId: habit.id,
            data: {'notes': notes},
          );
          // The server now holds the note — drop any local fallback.
          await _deleteLocalNote(habit.id);
        } on AppwriteException catch (e) {
          if (e.code == 400) {
            // No `notes` attribute on the live table yet.
            _notesColumnAvailable = false;
            await _saveLocalNote(habit.id, notes);
          } else {
            rethrow;
          }
        }
      } else {
        await _saveLocalNote(habit.id, notes);
      }
    }
    if (updates.isEmpty) {
      _notifyChanged();
      return;
    }
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
  /// logs, and adjusts XP/streak so the numbers stay consistent — every
  /// completed log the habit contributed is reversed in full (+2 each,
  /// the derived-XP rule), and the streak is recomputed from the
  /// remaining logs. The longest streak never decreases (it is a
  /// historical best).
  Future<void> deleteHabit(String habitId) async {
    return _writeQueue.run(() async {
      final profiles = ProfileRepository(db: _db);
      final logs = await _listLogsForHabit(habitId);
      final completedCount = logs.where((l) => l.completed).length;
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
          xpDelta: -xpPerTask * completedCount,
          currentStreak: newStreak,
          longestStreak: me.longestStreak,
          lastActiveDate: newLastActive,
        );
      }
      // The habit's sub-tasks and their logs go with it.
      await deleteSubtasksForHabit(habitId);
      await _deleteLocalNote(habitId);
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

  /// Every completed habit log, newest first — the XP ledger on the
  /// Dashboard is derived from this (each log = +2 XP). Paginated: a
  /// long-term user has more than one page of logs.
  Future<List<HabitLog>> listAllCompletedLogs() async {
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
          Query.equal('completed', true),
          Query.orderDesc('date'),
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

  /// Desired end-state per habit log, keyed by log document id
  /// (`{habitId}_{date}`). A tap records the state the UI shows; the
  /// sync worker applies the LATEST recorded state, so a burst of
  /// rapid taps collapses into a single server write and the last tap
  /// always wins. Intermediate flips are never written one by one.
  final Map<String, bool> _desiredLogState = {};

  /// Callers waiting for the sync of a log id to land (one completer
  /// per tap). All waiters complete together when the final desired
  /// state is applied (or fail together when it cannot be saved).
  final Map<String, List<Completer<ToggleResult>>> _logSyncWaiters = {};

  /// Log ids with a sync currently scheduled or running.
  final Set<String> _logSyncActive = {};

  /// Tick or untick a habit for [date]. Handles XP and streak.
  /// +2 XP while ticked, 0 while blank (the full reversal — unticking
  /// takes back exactly the +2 the tick granted; repeated tick/untick
  /// nets 0 and cannot farm XP). Untick deletes the log, so the day no
  /// longer counts toward the streak when its last completion is
  /// undone (streak is recomputed from the remaining logs).
  ///
  /// Fast by design (18 Nov 2026, "tick must not wait for the server"):
  /// the UI paints optimistically and never waits for this call. The
  /// server write is coalesced: rapid taps only update the desired
  /// state and the sync worker writes the FINAL state once (see
  /// [_syncLogToDesired]). The write itself sets the intended state
  /// directly — it never decides from a read of the log, because a
  /// stale read turned one untick in a rapid burst into a silent
  /// no-op and the server kept DONE/2 XP while the UI showed
  /// undone/0 XP (live test, 18 Nov 2026). After the write, the
  /// stored log is re-read (with retries) and XP + streak are
  /// reconciled from the derived rule, so the server always ends in
  /// the same state as the screen.
  Future<ToggleResult> toggleHabit({
    required Habit habit,
    required String date,
    required bool completed,
  }) async {
    final logId = _logDocId(habit.id, date);
    _desiredLogState[logId] = completed;
    final completer = Completer<ToggleResult>();
    (_logSyncWaiters[logId] ??= []).add(completer);
    // First tap for this log: schedule the sync. Later taps for the
    // same log just update the desired state and piggyback on it.
    // (Set.add returns true only when the id was absent — atomic in
    // Dart's single-threaded event loop, so exactly one sync runs.)
    if (_logSyncActive.add(logId)) {
      unawaited(_syncLogToDesired(habit: habit, date: date, logId: logId));
    }
    return completer.future;
  }

  /// Applies the latest desired state for one log, looping while new
  /// taps arrive mid-sync. The write + verify + derived reconcile run
  /// inside the serialised [_writeQueue], so they cannot race another
  /// XP write.
  Future<void> _syncLogToDesired({
    required Habit habit,
    required String date,
    required String logId,
  }) async {
    var failures = 0;
    try {
      while (true) {
        final desired = _desiredLogState[logId];
        if (desired == null) return;
        ToggleResult result;
        try {
          result = await _writeQueue.run(() async {
            // Re-read the desire at execution time: a tap may have
            // changed it while this job waited in the queue.
            final current = _desiredLogState[logId] ?? desired;
            await _applyLogState(
              habit: habit,
              date: date,
              logId: logId,
              done: current,
            );
            await _verifyLogWithRetry(logId: logId, expectDone: current);
            // Reconcile XP + streak from the server (derived rule) in
            // the same serialised step — never an incremental delta
            // computed from a possibly stale read.
            await ProfileRepository(db: _db)._recomputeDerivedXpNow();
            _notifyChanged();
            // The UI paints XP optimistically and never reads this
            // delta; the derived recompute is the authority.
            return const ToggleResult(xpDelta: 0, allDone: false);
          });
          failures = 0;
        } catch (e) {
          // Transient failure (network blip, read lag): retry the same
          // desire a couple of times before giving up. The waiters
          // stay pending — their UI already shows the desired state.
          failures++;
          if (failures >= 3) {
            // Persistent failure: give up. Complete the waiters that
            // arrived before this point with the error (their UI rolls
            // back) and drop the desire. This block is synchronous, so
            // a tap landing after it schedules its own sync via the
            // finally clause below instead of being stranded.
            final waiters = _logSyncWaiters.remove(logId);
            _desiredLogState.remove(logId);
            if (waiters != null) {
              for (final w in waiters) {
                if (!w.isCompleted) w.completeError(e);
              }
            }
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        // No newer desire arrived while we worked: done.
        if (_desiredLogState[logId] == desired) {
          _desiredLogState.remove(logId);
          final waiters = _logSyncWaiters.remove(logId);
          if (waiters != null) {
            for (final w in waiters) {
              if (!w.isCompleted) w.complete(result);
            }
          }
          return;
        }
        // A newer desire arrived: loop and apply it instead.
      }
    } finally {
      // A tap may have landed after the final check above: re-schedule
      // if a desire is still pending. These statements run with no
      // await between them, so no tap can slip in unnoticed — either
      // it arrived before the remove (and the check below sees it) or
      // after it (and schedules its own sync).
      _logSyncActive.remove(logId);
      if (_desiredLogState.containsKey(logId) && _logSyncActive.add(logId)) {
        unawaited(_syncLogToDesired(habit: habit, date: date, logId: logId));
      }
    }
  }

  /// Writes the intended log state, idempotently: a tick creates the
  /// log (or marks an existing one done), an untick deletes it (or
  /// does nothing when it is already gone). The outcome never depends
  /// on a prior read, so a stale read cannot turn a toggle into a
  /// silent no-op.
  Future<void> _applyLogState({
    required Habit habit,
    required String date,
    required String logId,
    required bool done,
  }) async {
    final userId = _requireUserId();
    if (done) {
      try {
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
      } on AppwriteException catch (e) {
        if (e.code == 409) {
          // The log already exists (an earlier tick landed): make sure
          // it is marked done.
          await _d.updateRow(
            databaseId: _dbId,
            tableId: 'habit_logs',
            rowId: logId,
            data: {'completed': true, 'xpEarned': xpPerTask},
          );
        } else {
          rethrow;
        }
      }
    } else {
      try {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'habit_logs',
          rowId: logId,
        );
      } on AppwriteException catch (e) {
        if (e.code == 404) {
          // Already gone — the desired state holds.
        } else {
          rethrow;
        }
      }
    }
  }

  /// Re-reads the stored log after a toggle and throws when it does
  /// not match the intended one. Retries a few times first: reads can
  /// lag a just-completed write by a moment under rapid toggling, and
  /// a stale read must not look like a failed write. A persistent
  /// mismatch throws, so the UI rolls back instead of showing a toggle
  /// that never persisted.
  Future<void> _verifyLogWithRetry({
    required String logId,
    required bool expectDone,
  }) async {
    const attempts = 6;
    for (var i = 0; i < attempts; i++) {
      final log = await _getLogOrNull(logId);
      final done = log != null && (log['completed'] as bool? ?? false);
      if (done == expectDone) return;
      if (i < attempts - 1) {
        await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
      }
    }
    throw StateError('Habit toggle did not save properly. Please try again.');
  }

  // -------------------------------------------------------------------------
  // Sub-tasks (v2.8.0, 18 Nov 2026)
  //
  // A habit can be broken into sub-tasks: DAILY ones recur every day,
  // TODAY ones apply to a single day. The habit's done state (+2 XP)
  // is DERIVED from them: a habit with sub-tasks due is done exactly
  // when ALL of them are done; a habit with no sub-tasks due is done
  // when its own tick is on (see logic/subtasks.dart). There is no XP
  // per sub-task — XP stays +2 per habit.
  //
  // Storage mirrors the notes pattern: the `habit_subtasks` and
  // `subtask_logs` tables are being created in the console; until a
  // 404/400 proves one missing, every sub-task op tries Appwrite
  // first and falls back to on-device storage (LocalStore). List
  // methods never throw — a missing table or an unconfigured backend
  // just yields an empty list, so screens degrade to "no sub-tasks"
  // instead of failing. Write methods rethrow real failures (so the
  // UI rolls back) but fall back to local storage on 404/400.
  // -------------------------------------------------------------------------

  /// Whether the live database has the sub-task tables. Once a
  /// missing table is seen, this session stops trying Appwrite for
  /// sub-tasks.
  static bool _subtasksTablesAvailable = true;

  /// Test-only: lets a test re-enable the Appwrite path after a
  /// fallback was triggered.
  static void resetSubtaskTablesForTest() {
    _subtasksTablesAvailable = true;
  }

  String _subtaskLogDocId(String subtaskId, String date) =>
      '${subtaskId}_$date';

  /// All sub-tasks of one habit (any kind, including archived).
  /// Never throws (see the section header).
  Future<List<HabitSubtask>> listSubtasksForHabit(String habitId) async {
    if (_subtasksTablesAvailable) {
      try {
        final list = await _d.listRows(
          databaseId: _dbId,
          tableId: 'habit_subtasks',
          queries: [
            Query.equal('habitId', habitId),
            Query.orderAsc(r'$createdAt'),
          ],
        );
        return list.rows
            .map((doc) => HabitSubtask.fromJson(_docJson(doc)))
            .toList();
      } on AppwriteException catch (e) {
        if (e.code == 404 || e.code == 400) {
          _subtasksTablesAvailable = false;
        }
        // Any failure degrades to the local list below.
      } on AppwriteNotConfigured {
        // No backend (e.g. widget test) — local fallback below.
      } catch (_) {
        // Best-effort list (see the section header).
      }
    }
    return _localSubtasksForHabit(habitId);
  }

  /// Sub-tasks of several habits, grouped by habit id. Habits with
  /// none get an empty list. Never throws (see the section header).
  Future<Map<String, List<HabitSubtask>>> listSubtasksByHabit(
    Iterable<String> habitIds,
  ) async {
    final ids = habitIds.toSet();
    final result = {for (final id in ids) id: <HabitSubtask>[]};
    if (ids.isEmpty) return result;
    if (_subtasksTablesAvailable) {
      try {
        // One query per habit: the table has no ownerUid, so the
        // indexed habitId query is the only selective one. Habit
        // counts are small (a handful per user).
        for (final id in ids) {
          final list = await _d.listRows(
            databaseId: _dbId,
            tableId: 'habit_subtasks',
            queries: [
              Query.equal('habitId', id),
              Query.orderAsc(r'$createdAt'),
            ],
          );
          result[id] = list.rows
              .map((doc) => HabitSubtask.fromJson(_docJson(doc)))
              .toList();
        }
        return result;
      } on AppwriteException catch (e) {
        if (e.code == 404 || e.code == 400) {
          _subtasksTablesAvailable = false;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      } catch (_) {
        // Best-effort list (see the section header).
      }
    }
    return _localSubtasksByHabit(ids);
  }

  /// On-device sub-tasks of one habit for the current user.
  /// Best-effort: returns an empty list when SharedPreferences is
  /// unavailable (e.g. a widget test).
  Future<List<HabitSubtask>> _localSubtasksForHabit(String habitId) async {
    try {
      final userId = _requireUserId();
      final store = await LocalStore.getInstance();
      return store
          .loadSubtaskMaps()
          .where(
            (m) =>
                LocalStore.subtaskOwnerId(m) == userId &&
                (m['habitId'] as String? ?? '') == habitId,
          )
          .map(HabitSubtask.fromJson)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<Map<String, List<HabitSubtask>>> _localSubtasksByHabit(
    Set<String> habitIds,
  ) async {
    final result = {for (final id in habitIds) id: <HabitSubtask>[]};
    try {
      final userId = _requireUserId();
      final store = await LocalStore.getInstance();
      for (final map in store.loadSubtaskMaps()) {
        if (LocalStore.subtaskOwnerId(map) != userId) continue;
        final habitId = map['habitId'] as String? ?? '';
        if (!habitIds.contains(habitId)) continue;
        result[habitId]!.add(HabitSubtask.fromJson(map));
      }
    } catch (_) {
      // Best-effort (see _localSubtasksForHabit).
    }
    return result;
  }

  /// Sub-task ids completed on [date] (any habit). Never throws.
  Future<Set<String>> completedSubtaskIdsForDate(String date) async {
    final byDate = await completedSubtaskIdsInRange(date, date);
    return byDate[date] ?? <String>{};
  }

  /// Sub-task ids completed per date in [start]..[end] (inclusive).
  /// Never throws.
  Future<Map<String, Set<String>>> completedSubtaskIdsInRange(
    String start,
    String end,
  ) async {
    final result = <String, Set<String>>{};
    if (_subtasksTablesAvailable) {
      try {
        final list = await _d.listRows(
          databaseId: _dbId,
          tableId: 'subtask_logs',
          queries: [
            Query.equal('completed', true),
            Query.greaterThanEqual('date', start),
            Query.lessThanEqual('date', end),
            Query.limit(100),
          ],
        );
        for (final doc in list.rows) {
          final data = doc.data;
          final d = data['date'] as String?;
          final subId = data['subtaskId'] as String?;
          if (d != null && subId != null) {
            (result[d] ??= <String>{}).add(subId);
          }
        }
        return result;
      } on AppwriteException catch (e) {
        if (e.code == 404 || e.code == 400) {
          _subtasksTablesAvailable = false;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      } catch (_) {
        // Best-effort list (see the section header).
      }
    }
    try {
      final store = await LocalStore.getInstance();
      for (final log in store.loadSubtaskLogs()) {
        if (!log.completed) continue;
        if (log.date.compareTo(start) < 0 || log.date.compareTo(end) > 0) {
          continue;
        }
        (result[log.date] ??= <String>{}).add(log.subtaskId);
      }
    } catch (_) {
      // Best-effort (see _localSubtasksForHabit).
    }
    return result;
  }

  /// Adds a sub-task to a habit. [kind] is 'daily' or 'today'
  /// ([HabitSubtask.kindDaily] / [HabitSubtask.kindToday]); the date
  /// is today (creation date for daily, the one day for today).
  /// Adding an undone sub-task can un-complete a habit that was fully
  /// done, so the habit's done state for today is recomputed after
  /// the add.
  Future<HabitSubtask> addSubtask({
    required Habit habit,
    required String title,
    required String kind,
  }) async {
    final userId = _requireUserId();
    final date = todayKey();
    final id = ID.unique();
    if (_subtasksTablesAvailable) {
      try {
        final doc = await _d.createRow(
          databaseId: _dbId,
          tableId: 'habit_subtasks',
          rowId: id,
          data: {
            'habitId': habit.id,
            'title': title,
            'kind': kind,
            'date': date,
            'archived': false,
          },
          permissions: _ownerPerms(userId),
        );
        final subtask = HabitSubtask.fromJson(_docJson(doc));
        // Serialised with the other XP writes (see the section
        // header): the recompute must not race a concurrent toggle.
        await _writeQueue.run(
          () => _recomputeHabitDone(habit: habit, date: date),
        );
        _notifyChanged();
        return subtask;
      } on AppwriteException catch (e) {
        if (e.code == 404 || e.code == 400) {
          _subtasksTablesAvailable = false;
        } else {
          rethrow;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      }
    }
    final subtask = HabitSubtask(
      id: id,
      habitId: habit.id,
      title: title,
      kind: kind,
      date: date,
    );
    await _saveLocalSubtask(subtask);
    await _writeQueue.run(
      () => _recomputeHabitDone(habit: habit, date: date),
    );
    _notifyChanged();
    return subtask;
  }

  Future<void> _saveLocalSubtask(HabitSubtask subtask) async {
    try {
      final userId = _requireUserId();
      final store = await LocalStore.getInstance();
      final maps = store.loadSubtaskMaps();
      final index = maps.indexWhere((m) => m['id'] == subtask.id);
      final map = subtask.toJson(userId);
      if (index >= 0) {
        maps[index] = map;
      } else {
        maps.add(map);
      }
      await store.saveSubtaskMaps(maps);
    } catch (_) {
      // Best-effort only: a failed local save must not break the
      // habit flow (the Appwrite path is the real one).
    }
  }

  Future<void> _deleteLocalSubtask(String subtaskId) async {
    try {
      final store = await LocalStore.getInstance();
      final maps = store.loadSubtaskMaps();
      maps.removeWhere((m) => m['id'] == subtaskId);
      await store.saveSubtaskMaps(maps);
      final logs = store.loadSubtaskLogs()
          .where((l) => l.subtaskId != subtaskId)
          .toList();
      await store.saveSubtaskLogs(logs);
    } catch (_) {
      // Best-effort only (see _saveLocalSubtask).
    }
  }

  /// Deletes a sub-task and all its logs. Removing the only undone
  /// sub-task can complete the habit, so the habit's done state for
  /// today is recomputed after the delete.
  Future<void> deleteSubtask(HabitSubtask subtask) async {
    final habit = Habit(
      id: subtask.habitId,
      userId: '',
      title: '',
    );
    if (_subtasksTablesAvailable) {
      try {
        await _deleteSubtaskRows(subtask.id);
        await _writeQueue.run(
          () => _recomputeHabitDone(habit: habit, date: todayKey()),
        );
        _notifyChanged();
        return;
      } on AppwriteException catch (e) {
        if (e.code == 404 || e.code == 400) {
          _subtasksTablesAvailable = false;
        } else {
          rethrow;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      }
    }
    await _deleteLocalSubtask(subtask.id);
    await _writeQueue.run(
      () => _recomputeHabitDone(habit: habit, date: todayKey()),
    );
    _notifyChanged();
  }

  /// Deletes one sub-task row plus every log row for it (Appwrite).
  /// Missing rows are fine (404 is ignored).
  Future<void> _deleteSubtaskRows(String subtaskId) async {
    try {
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'habit_subtasks',
        rowId: subtaskId,
      );
    } on AppwriteException catch (e) {
      if (e.code != 404) rethrow;
    }
    final logs = await _d.listRows(
      databaseId: _dbId,
      tableId: 'subtask_logs',
      queries: [Query.equal('subtaskId', subtaskId), Query.limit(100)],
    );
    for (final doc in logs.rows) {
      try {
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'subtask_logs',
          rowId: doc.$id,
        );
      } on AppwriteException catch (e) {
        if (e.code != 404) rethrow;
      }
    }
  }

  /// Deletes every sub-task of a habit plus their logs (used when a
  /// habit is deleted, and by account deletion). Best-effort on the
  /// local fallback (a failure there never blocks the habit delete).
  Future<void> deleteSubtasksForHabit(String habitId) async {
    final subtasks = await listSubtasksForHabit(habitId);
    for (final sub in subtasks) {
      if (_subtasksTablesAvailable) {
        try {
          await _deleteSubtaskRows(sub.id);
        } on AppwriteException catch (e) {
          if (e.code == 404 || e.code == 400) {
            _subtasksTablesAvailable = false;
            await _deleteLocalSubtask(sub.id);
          } else {
            rethrow;
          }
        } on AppwriteNotConfigured {
          await _deleteLocalSubtask(sub.id);
        }
      } else {
        await _deleteLocalSubtask(sub.id);
      }
    }
  }

  /// Desired end-state per sub-task log, keyed by log document id
  /// (`{subtaskId}_{date}`) — the same coalescing trick as the habit
  /// toggle (see [_desiredLogState]): rapid taps collapse into a
  /// single server write and the last tap always wins.
  final Map<String, bool> _desiredSubtaskState = {};
  final Map<String, List<Completer<void>>> _subtaskSyncWaiters = {};
  final Set<String> _subtaskSyncActive = {};

  /// Tick or untick one sub-task for [date]. Writes the sub-task log,
  /// then recomputes the habit's done state from ALL its due
  /// sub-tasks (so the +2 XP follows the work, with the full reversal
  /// when the last done sub-task is unticked). The UI paints
  /// optimistically and never waits for this call.
  Future<void> toggleSubtask({
    required HabitSubtask subtask,
    required String date,
    required bool completed,
  }) async {
    final logId = _subtaskLogDocId(subtask.id, date);
    _desiredSubtaskState[logId] = completed;
    final completer = Completer<void>();
    (_subtaskSyncWaiters[logId] ??= []).add(completer);
    if (_subtaskSyncActive.add(logId)) {
      unawaited(_syncSubtaskToDesired(subtask: subtask, date: date, logId: logId));
    }
    return completer.future;
  }

  /// Applies the latest desired state for one sub-task log, looping
  /// while new taps arrive mid-sync (mirrors [_syncLogToDesired]).
  Future<void> _syncSubtaskToDesired({
    required HabitSubtask subtask,
    required String date,
    required String logId,
  }) async {
    var failures = 0;
    try {
      while (true) {
        final desired = _desiredSubtaskState[logId];
        if (desired == null) return;
        try {
          await _writeQueue.run(() async {
            final current = _desiredSubtaskState[logId] ?? desired;
            await _writeSubtaskLog(
              subtask: subtask,
              date: date,
              done: current,
            );
            final habit = Habit(
              id: subtask.habitId,
              userId: '',
              title: '',
            );
            await _recomputeHabitDone(habit: habit, date: date);
            _notifyChanged();
          });
          failures = 0;
        } catch (e) {
          failures++;
          if (failures >= 3) {
            final waiters = _subtaskSyncWaiters.remove(logId);
            _desiredSubtaskState.remove(logId);
            if (waiters != null) {
              for (final w in waiters) {
                if (!w.isCompleted) w.completeError(e);
              }
            }
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        if (_desiredSubtaskState[logId] == desired) {
          _desiredSubtaskState.remove(logId);
          final waiters = _subtaskSyncWaiters.remove(logId);
          if (waiters != null) {
            for (final w in waiters) {
              if (!w.isCompleted) w.complete();
            }
          }
          return;
        }
      }
    } finally {
      _subtaskSyncActive.remove(logId);
      if (_desiredSubtaskState.containsKey(logId) &&
          _subtaskSyncActive.add(logId)) {
        unawaited(_syncSubtaskToDesired(subtask: subtask, date: date, logId: logId));
      }
    }
  }

  /// Writes the intended sub-task log state, idempotently: a tick
  /// creates the log (or marks an existing one done), an untick
  /// deletes it (or does nothing when it is already gone). Falls back
  /// to on-device storage when the table is missing.
  Future<void> _writeSubtaskLog({
    required HabitSubtask subtask,
    required String date,
    required bool done,
  }) async {
    final logId = _subtaskLogDocId(subtask.id, date);
    if (_subtasksTablesAvailable) {
      try {
        if (done) {
          try {
            await _d.createRow(
              databaseId: _dbId,
              tableId: 'subtask_logs',
              rowId: logId,
              data: {
                'subtaskId': subtask.id,
                'date': date,
                'completed': true,
              },
              permissions: _ownerPerms(_requireUserId()),
            );
          } on AppwriteException catch (e) {
            if (e.code == 409) {
              await _d.updateRow(
                databaseId: _dbId,
                tableId: 'subtask_logs',
                rowId: logId,
                data: {'completed': true},
              );
            } else {
              rethrow;
            }
          }
        } else {
          try {
            await _d.deleteRow(
              databaseId: _dbId,
              tableId: 'subtask_logs',
              rowId: logId,
            );
          } on AppwriteException catch (e) {
            if (e.code != 404) rethrow;
          }
        }
        return;
      } on AppwriteException catch (e) {
        if (e.code == 404 || e.code == 400) {
          _subtasksTablesAvailable = false;
        } else {
          rethrow;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      }
    }
    // On-device fallback.
    try {
      final store = await LocalStore.getInstance();
      final logs = store.loadSubtaskLogs();
      final index = logs.indexWhere((l) => l.id == logId);
      if (done) {
        final log = SubtaskLog(id: logId, subtaskId: subtask.id, date: date);
        if (index >= 0) {
          logs[index] = log;
        } else {
          logs.add(log);
        }
      } else {
        if (index >= 0) logs.removeAt(index);
      }
      await store.saveSubtaskLogs(logs);
    } catch (_) {
      // Best-effort only (see _saveLocalSubtask).
    }
  }

  /// Recomputes one habit's done state for [date] from its due
  /// sub-tasks and writes the habit log to match: all due sub-tasks
  /// done → habit log done (+2 XP); otherwise → habit log gone (0
  /// XP). A habit with NO sub-tasks due is left untouched (its own
  /// tick rules it — see [toggleHabit]). Runs inside the caller's
  /// [_writeQueue] job, so it cannot race another XP write. The
  /// derived-XP recompute is the authority for the profile numbers.
  Future<void> _recomputeHabitDone({
    required Habit habit,
    required String date,
  }) async {
    final subtasks = await listSubtasksForHabit(habit.id);
    final due = dueSubtasks(subtasks, date);
    if (due.isEmpty) return;
    final doneIds = await completedSubtaskIdsForDate(date);
    final allDone = due.every((s) => doneIds.contains(s.id));
    final logId = _logDocId(habit.id, date);
    await _applyLogState(
      habit: habit,
      date: date,
      logId: logId,
      done: allDone,
    );
    await _verifyLogWithRetry(logId: logId, expectDone: allDone);
    await ProfileRepository(db: _db)._recomputeDerivedXpNow();
  }

  /// Sets a habit's done state for [date] — the single entry point
  /// every screen's habit toggle must use (Home, Schedule,
  /// Challenge detail).
  ///
  /// - Habit with sub-tasks due today → ticks/unticks ALL its due
  ///   sub-tasks (the habit's done state is derived from them, so
  ///   the main check means "do the whole habit").
  /// - Habit with no sub-tasks → flips the habit log directly (the
  ///   existing [toggleHabit] path).
  Future<ToggleResult> setHabitDone({
    required Habit habit,
    required String date,
    required bool done,
  }) async {
    final subtasks = await listSubtasksForHabit(habit.id);
    final due = dueSubtasks(subtasks, date);
    if (due.isEmpty) {
      return toggleHabit(habit: habit, date: date, completed: done);
    }
    // Toggle every due sub-task (serialised through the same queue
    // by toggleSubtask); the last one leaves the habit log in the
    // derived state. Await them in order so the caller knows when
    // the server matches the screen.
    final completedBefore = await completedSubtaskIdsForDate(date);
    final wasDone = due.every((s) => completedBefore.contains(s.id));
    for (final sub in due) {
      await toggleSubtask(subtask: sub, date: date, completed: done);
    }
    // The XP delta is the DERIVED change: +2 when the habit becomes
    // done, -2 when it stops being done, 0 when nothing changed
    // (it was already in the desired state).
    return ToggleResult(
      xpDelta: (done ? xpPerTask : 0) - (wasDone ? xpPerTask : 0),
      allDone: done,
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

  /// Every done weekly task, newest week first — the XP ledger on the
  /// Dashboard is derived from this (each done task = +2 XP).
  /// (listWeeklyTasks only covers one week; the ledger needs all.)
  Future<List<WeeklyTask>> listAllDoneWeeklyTasks() async {
    final userId = _requireUserId();
    final all = <WeeklyTask>[];
    const page = 100;
    var offset = 0;
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'weekly_tasks',
        queries: [
          Query.equal('ownerUid', userId),
          Query.equal('done', true),
          Query.orderDesc('weekStart'),
          Query.limit(page),
          Query.offset(offset),
        ],
      );
      all.addAll(
        list.rows.map((doc) => WeeklyTask.fromJson(_docJson(doc))),
      );
      if (list.rows.length < page) break;
      offset += page;
    }
    return all;
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

  /// Toggles a weekly task: +2 XP on completing, -2 XP on unticking
  /// (the full reversal — a done task is worth +2, a blank one 0).
  /// Reads the current state first so toggling to the same state
  /// grants nothing. Serialised with the other XP writes so two quick
  /// toggles cannot read the same stale state.
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

  /// Deletes a weekly task. A task that was done loses its full +2 XP
  /// — deleting must not leave phantom XP behind.
  Future<void> deleteWeeklyTask(String id) async {
    return _writeQueue.run(() async {
      final wasDone = await _taskDone('weekly_tasks', id);
      await _d.deleteRow(databaseId: _dbId, tableId: 'weekly_tasks', rowId: id);
      if (wasDone == true) {
        await _adjustXp(-xpPerTask);
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

  /// Every done monthly task, newest month first — the XP ledger on the
  /// Dashboard is derived from this (each done task = +2 XP).
  Future<List<MonthlyTask>> listAllDoneMonthlyTasks() async {
    final userId = _requireUserId();
    final all = <MonthlyTask>[];
    const page = 100;
    var offset = 0;
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'monthly_tasks',
        queries: [
          Query.equal('ownerUid', userId),
          Query.equal('done', true),
          Query.orderDesc('month'),
          Query.limit(page),
          Query.offset(offset),
        ],
      );
      all.addAll(
        list.rows.map((doc) => MonthlyTask.fromJson(_docJson(doc))),
      );
      if (list.rows.length < page) break;
      offset += page;
    }
    return all;
  }

  /// Toggles a monthly task: same +2 / -2 XP rule as weekly tasks.
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

  /// Deletes a monthly task. A task that was done loses its full +2 XP
  /// — deleting must not leave phantom XP behind.
  Future<void> deleteMonthlyTask(String id) async {
    return _writeQueue.run(() async {
      final wasDone = await _taskDone('monthly_tasks', id);
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: 'monthly_tasks',
        rowId: id,
      );
      if (wasDone == true) {
        await _adjustXp(-xpPerTask);
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
    // Paginated (was: first page only — a user with >25 follows lost
    // the rest from the Friends leaderboard and the Following list).
    final userId = _requireUserId();
    final ids = <String>[];
    const page = 100;
    var offset = 0;
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'follows',
        queries: [
          Query.equal('followerUid', userId),
          Query.limit(page),
          Query.offset(offset),
        ],
      );
      ids.addAll(
        list.rows.map((doc) => doc.data['followingUid'] as String),
      );
      if (list.rows.length < page) break;
      offset += page;
    }
    return ids;
  }

  /// Ids of the users following me.
  Future<List<String>> followersIds() async {
    final userId = _requireUserId();
    final ids = <String>[];
    const page = 100;
    var offset = 0;
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'follows',
        queries: [
          Query.equal('followingUid', userId),
          Query.limit(page),
          Query.offset(offset),
        ],
      );
      ids.addAll(list.rows.map((doc) => doc.data['followerUid'] as String));
      if (list.rows.length < page) break;
      offset += page;
    }
    return ids;
  }

  /// Public profiles of my followers (or the people I follow), sorted
  /// by display name. Used by the Followers / Following lists on
  /// Profile (18 Nov 2026).
  Future<List<Profile>> followProfiles({required bool followers}) async {
    final ids = followers ? await followersIds() : await followingIds();
    final profiles = <Profile>[];
    final profilesRepo = ProfileRepository(db: _db);
    for (final id in ids) {
      final profile = await profilesRepo.fetchProfile(id);
      if (profile != null) profiles.add(profile);
    }
    profiles.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return profiles;
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

      // Sub-tasks have no ownerUid, so they are deleted per habit
      // (before the habits themselves go).
      final habits = await HabitRepository(db: _db).listMyHabits();
      for (final habit in habits) {
        await HabitRepository(db: _db).deleteSubtasksForHabit(habit.id);
      }
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
