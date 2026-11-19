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
import 'dart:io';

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

/// True when [e] is a network failure (no connectivity, DNS, timeout)
/// rather than a real server error. Network failures are the ones the
/// app must survive silently (offline mode); other errors are real and
/// should still surface. Lives here so both the repositories and
/// [SyncService] can use it without a circular import.
bool isNetworkError(Object e) {
  if (e is AppwriteException) {
    // The Appwrite SDK reports transport failures as code 0.
    if (e.code == 0) return true;
    final message = (e.message ?? '').toLowerCase();
    return message.contains('failed host lookup') ||
        message.contains('network is unreachable') ||
        message.contains('connection') ||
        message.contains('socket') ||
        message.contains('timed out') ||
        message.contains('timeout');
  }
  if (e is SocketException) return true;
  if (e is TimeoutException) return true;
  final message = e.toString().toLowerCase();
  return message.contains('failed host lookup') ||
      message.contains('network is unreachable') ||
      message.contains('socketexception');
}

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
  /// Creates the auth account, signs in, and creates the profile row
  /// + the username reservation. [visibility] is the account choice
  /// from the signup screen ('public' or 'private', v2.9.0); it is
  /// stored on the profile row. If the `visibility` / `discoverable`
  /// attributes are not on the live table yet, the profile is created
  /// without them (the choice is kept in the local cache and pushed
  /// by the next profile update) — signup never fails for that.
  ///
  /// If the username document is taken in a race, the auth account
  /// already exists — the user just lands on the one-time username
  /// setup screen on next login (see [ProfileRepository.createProfile]).
  Future<bool> signUp({
    required String email,
    required String password,
    required String username,
    required String displayName,
    String visibility = 'public',
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
        visibility: visibility,
      );
      await _createProfileRow(db, user.$id, profile);
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

  /// Creates the profile row, retrying without the v2.9.0 attributes
  /// (`visibility`, `discoverable`) when the live table does not have
  /// them yet (AppwriteException 400). The choice is kept in the
  /// local profile cache either way.
  static Future<void> _createProfileRow(
    TablesDB db,
    String userId,
    Profile profile,
  ) async {
    try {
      await db.createRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: userId,
        data: profile.toMap(),
        permissions: _profilePerms(userId),
      );
    } on AppwriteException catch (e) {
      if (e.code == 400) {
        final data = Map<String, dynamic>.from(profile.toMap())
          ..remove('visibility')
          ..remove('discoverable');
        await db.createRow(
          databaseId: _dbId,
          tableId: 'users',
          rowId: userId,
          data: data,
          permissions: _profilePerms(userId),
        );
      } else {
        rethrow;
      }
    }
    // Keep the choice locally even when the server row lacks it.
    try {
      final store = await LocalStore.getInstance();
      await store.saveCachedProfile(profile);
    } catch (_) {}
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

  /// Loads one profile. v2.9.0 offline-first: my own profile falls
  /// back to the on-device cache when the network fails (so the app
  /// still opens with my name, XP and streak); other users' profiles
  /// return null offline (the Leaderboard just shows fewer entries).
  /// A successful fetch of my own profile refreshes the cache.
  Future<Profile?> fetchProfile(String userId) async {
    try {
      final doc = await _d.getRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: userId,
      );
      final data = _docJson(doc);
      var profile = Profile.fromJson(data);
      final me = AuthRepository.cachedUser;
      if (me != null && userId == me.uid) {
        // If the live row was written before the v2.9.0 attributes
        // existed, the server cannot tell us the choice — keep the
        // locally cached one instead of defaulting to public.
        if (!data.containsKey('visibility') ||
            !data.containsKey('discoverable')) {
          try {
            final store = await LocalStore.getInstance();
            final cached = store.loadCachedProfile(userId);
            if (cached != null) {
              profile = profile.copyWith(
                visibility: data.containsKey('visibility')
                    ? null
                    : cached.visibility,
                discoverable: data.containsKey('discoverable')
                    ? null
                    : cached.discoverable,
              );
            }
          } catch (_) {}
        }
        try {
          final store = await LocalStore.getInstance();
          await store.saveCachedProfile(profile);
        } catch (_) {}
      }
      return profile;
    } on AppwriteException catch (e) {
      if (e.code == 404) return null;
      if (isNetworkError(e)) return _cachedProfileOrNull(userId);
      rethrow;
    } on AppwriteNotConfigured {
      return _cachedProfileOrNull(userId);
    }
  }

  Future<Profile?> _cachedProfileOrNull(String userId) async {
    try {
      final store = await LocalStore.getInstance();
      return store.loadCachedProfile(userId);
    } catch (_) {
      return null;
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
    String visibility = 'public',
  }) async {
    final userId = _requireUserId();
    final lower = username.toLowerCase();
    final name = displayName.isEmpty ? lower : displayName;
    final profile = Profile(
      id: userId,
      username: lower,
      displayName: name,
      visibility: visibility,
    );
    try {
      await AuthRepository._createProfileRow(_d, userId, profile);
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

  /// Updates my display name / bio and, optionally, the v2.9.0
  /// account settings: [visibility] ('public' / 'private') and
  /// [discoverable] (whether I appear in the Leaderboard + Search).
  /// Offline: the change applies to the local cache immediately and
  /// is queued in the outbox for the background sync — the caller
  /// still gets the updated profile back, never an error.
  Future<Profile> updateProfile({
    required String displayName,
    required String bio,
    String? visibility,
    bool? discoverable,
    String? publicKey,
  }) async {
    final userId = _requireUserId();
    final data = <String, dynamic>{
      'displayName': displayName,
      'bio': bio,
    };
    if (visibility != null) data['visibility'] = visibility;
    if (discoverable != null) data['discoverable'] = discoverable;
    // v2.11.0: RSA public key for E2EE messages. Null-safe on the
    // live table — see the 400 fallback below.
    if (publicKey != null) data['publicKey'] = publicKey;
    try {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: userId,
        data: data,
      );
    } on AppwriteException catch (e) {
      if (e.code == 400 &&
          (visibility != null ||
              discoverable != null ||
              publicKey != null)) {
        // The v2.9.0 / v2.11.0 attributes are not on the live table
        // yet — retry with just the name/bio so the edit still lands.
        await _d.updateRow(
          databaseId: _dbId,
          tableId: 'users',
          rowId: userId,
          data: {'displayName': displayName, 'bio': bio},
        );
      } else if (isNetworkError(e)) {
        // Offline: cache + queue, return the updated profile.
        final cached = await _cachedProfileOrNull(userId);
        final updated =
            (cached ??
                    Profile(
                      id: userId,
                      username: '',
                      displayName: displayName,
                      bio: bio,
                    ))
                .copyWith(
                  displayName: displayName,
                  bio: bio,
                  visibility: visibility,
                  discoverable: discoverable,
                  publicKey: publicKey,
                );
        try {
          final store = await LocalStore.getInstance();
          await store.saveCachedProfile(updated);
          await store.enqueueOutboxOp({
            'kind': 'profile_update',
            'ownerUid': userId,
            'data': data,
          });
        } catch (_) {}
        _notifyChanged();
        return updated;
      } else {
        rethrow;
      }
    }
    final updated = await fetchProfile(userId);
    if (updated == null) throw const AuthException('Profile not found.');
    // When the 400 fallback above dropped the settings, keep them in
    // the local cache so the UI still shows the choice.
    if (visibility != null || discoverable != null || publicKey != null) {
      final withSettings = updated.copyWith(
        visibility: visibility,
        discoverable: discoverable,
        publicKey: publicKey,
      );
      try {
        final store = await LocalStore.getInstance();
        await store.saveCachedProfile(withSettings);
      } catch (_) {}
      return withSettings;
    }
    return updated;
  }

  /// Replays a queued profile update (server-only, no local writes —
  /// used by [SyncService]). A 400 means the v2.9.0 attributes are
  /// not on the live table yet; the name/bio part is still written.
  Future<void> replayProfileUpdate(Map<String, dynamic> data) async {
    final userId = _requireUserId();
    try {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'users',
        rowId: userId,
        data: data,
      );
    } on AppwriteException catch (e) {
      if (e.code == 400) {
        final core = Map<String, dynamic>.from(data)
          ..remove('visibility')
          ..remove('discoverable');
        if (core.isNotEmpty) {
          await _d.updateRow(
            databaseId: _dbId,
            tableId: 'users',
            rowId: userId,
            data: core,
          );
        }
      } else {
        rethrow;
      }
    }
  }

  /// Another user's habits (v2.9.0): the habit list on a visited
  /// profile. Public accounts show them; private accounts only to
  /// mutual friends (the caller gates that — see
  /// [SocialRepository.isMutual]).
  Future<List<Habit>> listHabitsForUser(String userId) async {
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'habits',
      queries: [
        Query.equal('ownerUid', userId),
        Query.equal('archived', false),
        Query.orderAsc(r'$createdAt'),
        Query.limit(100),
      ],
    );
    return list.rows.map((doc) => Habit.fromJson(_docJson(doc))).toList();
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
    // v2.9.0: hidden accounts (discoverable == false) never appear in
    // discovery. Filtered client-side, NOT with Query.equal — rows
    // written before the attribute existed have null, which means
    // "shown" and would be excluded by a server-side equality filter.
    final profiles = list.rows
        .map((doc) => Profile.fromJson(_docJson(doc)))
        .where((p) => p.discoverable)
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
      // v2.9.0: hidden accounts never appear in Search (same
      // client-side filter as the Leaderboard — null = shown).
      if (profile != null && profile.discoverable) profiles.add(profile);
    }
    return profiles;
  }
}

// ---------------------------------------------------------------------------
// Habits + logs + XP orchestration
// ---------------------------------------------------------------------------

/// Recomputes XP + streak from the LOCAL caches (habit logs +
/// weekly/monthly tasks) and writes them into the cached profile.
/// The offline twin of [ProfileRepository._recomputeDerivedXpNow]
/// (same rule: 2 XP per completed habit log / done task, no bonus, no
/// penalty). Shared by [HabitRepository] and [TaskRepository] — the
/// local caches are the source of truth while offline, so every local
/// log/task change runs this.
Future<void> recomputeLocalDerivedXpForUser() async {
  try {
    final user = AuthRepository.cachedUser;
    if (user == null) return;
    final userId = user.uid;
    final store = await LocalStore.getInstance();
    final logs = store.loadCachedHabitLogs(userId);
    final completed = logs.where((l) => l.completed).length;
    final tasks = store.loadCachedTasks(userId);
    final weeklyDone = tasks.weekly.where((t) => t.done).length;
    final monthlyDone = tasks.monthly.where((t) => t.done).length;
    final xp = xpPerTask * (completed + weeklyDone + monthlyDone);
    final dates = logs.where((l) => l.completed).map((l) => l.logDate).toSet();
    final streak = computeStreak(dates);
    final lastActive = dates.isEmpty
        ? null
        : dates.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    final cached = store.loadCachedProfile(userId);
    if (cached == null) return;
    final longest = streak > cached.longestStreak
        ? streak
        : cached.longestStreak;
    await store.saveCachedProfile(
      cached.copyWith(
        xp: xp,
        currentStreak: streak,
        longestStreak: longest,
        lastActiveDate: lastActive,
      ),
    );
  } catch (_) {}
}

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

  // -- v2.9.0 offline-first helpers ----------------------------------------

  /// The on-device store, or null when SharedPreferences is
  /// unavailable (e.g. a widget test). Every local write is
  /// best-effort: it must never break the server path.
  Future<LocalStore?> _localStore() async {
    try {
      return await LocalStore.getInstance();
    } catch (_) {
      return null;
    }
  }

  /// Merges server-fetched logs into the on-device cache (upsert by
  /// id) so later offline reads see them.
  Future<void> _mergeCachedLogs(List<HabitLog> logs) async {
    if (logs.isEmpty) return;
    final store = await _localStore();
    if (store == null) return;
    try {
      final userId = _requireUserId();
      final cached = store.loadCachedHabitLogs(userId);
      final byId = {for (final l in cached) l.id: l};
      for (final log in logs) {
        byId[log.id] = log;
      }
      await store.saveCachedHabitLogs(userId, byId.values.toList());
    } catch (_) {}
  }

  /// Recomputes XP + streak from the LOCAL caches (habit logs +
  /// weekly/monthly tasks) and writes them into the cached profile —
  /// the offline twin of [ProfileRepository._recomputeDerivedXpNow].
  /// The rule is identical (2 XP per completed habit log / done task,
  /// no bonus, no penalty); the streak is recomputed from the local
  /// active dates. Runs after every local log/task change so a reload
  /// offline shows the right numbers.
  Future<void> _recomputeLocalDerivedXp() async {
    await recomputeLocalDerivedXpForUser();
  }

  /// Queues one pending server write in the outbox (best-effort).
  Future<void> _enqueueOp(Map<String, dynamic> op) async {
    try {
      final store = await LocalStore.getInstance();
      await store.enqueueOutboxOp(op);
    } catch (_) {}
  }

  Future<List<Habit>> listMyHabits() async {
    final userId = _requireUserId();
    try {
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
      final withNotes = localNotes.isEmpty
          ? habits
          : habits
                .map(
                  (h) => localNotes.containsKey(h.id)
                      ? h.copyWith(notes: localNotes[h.id]!)
                      : h,
                )
                .toList();
      // Refresh the offline cache (best-effort).
      try {
        final store = await LocalStore.getInstance();
        await store.saveCachedHabits(userId, withNotes);
      } catch (_) {}
      return withNotes;
    } on Object catch (e) {
      // v2.9.0: no network → the cached habits, never a blank screen.
      if (isNetworkError(e)) {
        final store = await _localStore();
        return store?.loadCachedHabits(userId) ?? <Habit>[];
      }
      rethrow;
    }
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

  /// Adds a habit. v2.9.0 offline-first: the id is generated locally
  /// (so the same id is used by the later server create — idempotent)
  /// and the habit is in the local cache immediately. The server
  /// create runs best-effort; offline it is queued in the outbox and
  /// this still returns the habit (never an error).
  Future<Habit> addHabit({required String title, required int color}) async {
    final userId = _requireUserId();
    final id = ID.unique();
    final habit = Habit(id: id, userId: userId, title: title, color: color);
    final store = await _localStore();
    try {
      await store?.upsertCachedHabit(habit);
    } catch (_) {}
    await _enqueueOp({
      'kind': 'habit_add',
      'ownerUid': userId,
      'id': id,
      'title': title,
      'color': color,
    });
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'habits',
        rowId: id,
        data: {
          'ownerUid': userId,
          'title': title,
          'color': color,
          'archived': false,
        },
        permissions: _ownerPerms(userId),
      );
      // Landed on the server — the outbox op is no longer needed.
      try {
        final ops = store?.loadOutbox() ?? <Map<String, dynamic>>[];
        ops.removeWhere((o) => o['kind'] == 'habit_add' && o['id'] == id);
        await store?.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) {
        // A real server error (e.g. 400): drop the local habit + op.
        try {
          await store?.removeCachedHabit(userId, id);
          final ops = store?.loadOutbox() ?? <Map<String, dynamic>>[];
          ops.removeWhere((o) => o['kind'] == 'habit_add' && o['id'] == id);
          await store?.saveOutbox(ops);
        } catch (_) {}
        rethrow;
      }
      // Offline: the habit is local + queued; the sync replays it.
    }
    _notifyChanged();
    return habit;
  }

  /// Whether the live `habits` table has the `notes` attribute. It does
  /// not (18 Nov 2026) — the attribute is defined in
  /// scripts/setup_appwrite.mjs for a future re-run. Until then notes
  /// fall back to on-device storage (LocalStore). Once a 400 is seen,
  /// this session stops trying Appwrite for notes.
  static bool _notesColumnAvailable = true;

  /// Updates a habit. v2.9.0 offline-first: the change applies to the
  /// local cache immediately and is queued in the outbox; the server
  /// update is best-effort (offline it is replayed by the sync).
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
          } else if (isNetworkError(e)) {
            // Offline: the note is local (and queued below).
            await _saveLocalNote(habit.id, notes);
          } else {
            rethrow;
          }
        }
      } else {
        await _saveLocalNote(habit.id, notes);
      }
    }
    // Local cache first (the source of truth while offline).
    final updatedHabit = habit.copyWith(
      title: title,
      color: color,
      notes: notes,
    );
    final store = await _localStore();
    try {
      await store?.upsertCachedHabit(updatedHabit);
    } catch (_) {}
    final op = <String, dynamic>{
      'kind': 'habit_update',
      'ownerUid': _requireUserId(),
      'id': habit.id,
    };
    if (title != null) op['title'] = title;
    if (color != null) op['color'] = color;
    if (notes != null) op['notes'] = notes;
    await _enqueueOp(op);
    if (updates.isEmpty) {
      _notifyChanged();
      return;
    }
    try {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'habits',
        rowId: habit.id,
        data: updates,
      );
      // Landed — drop the op.
      try {
        final ops = store?.loadOutbox() ?? <Map<String, dynamic>>[];
        ops.removeWhere(
          (o) => o['kind'] == 'habit_update' && o['id'] == habit.id,
        );
        await store?.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
      // Offline: local + queued; the sync replays it.
    }
    _notifyChanged();
  }

  /// Archives a habit. v2.9.0 offline-first: local cache + outbox,
  /// server best-effort.
  Future<void> archiveHabit(String habitId) async {
    final userId = _requireUserId();
    final store = await _localStore();
    try {
      await store?.removeCachedHabit(userId, habitId);
    } catch (_) {}
    await _enqueueOp({
      'kind': 'habit_archive',
      'ownerUid': userId,
      'id': habitId,
    });
    try {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'habits',
        rowId: habitId,
        data: {'archived': true},
      );
      try {
        final ops = store?.loadOutbox() ?? <Map<String, dynamic>>[];
        ops.removeWhere(
          (o) => o['kind'] == 'habit_archive' && o['id'] == habitId,
        );
        await store?.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
    }
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
  /// historical best). v2.9.0 offline-first: the local cache is
  /// cleared and the local XP recomputed immediately; the server
  /// delete is best-effort (queued in the outbox when offline).
  Future<void> deleteHabit(String habitId) async {
    final userId = _requireUserId();
    // Local first (the source of truth while offline).
    final store = await _localStore();
    try {
      await store?.removeCachedHabit(userId, habitId);
      final logs = store?.loadCachedHabitLogs(userId) ?? <HabitLog>[];
      logs.removeWhere((l) => l.habitId == habitId);
      await store?.saveCachedHabitLogs(userId, logs);
      await _recomputeLocalDerivedXp();
    } catch (_) {}
    await _enqueueOp({
      'kind': 'habit_delete',
      'ownerUid': userId,
      'id': habitId,
    });
    try {
      await _writeQueue.run(() => _deleteHabitOnServer(habitId));
      // Landed — drop the op.
      try {
        final ops = store?.loadOutbox() ?? <Map<String, dynamic>>[];
        ops.removeWhere(
          (o) => o['kind'] == 'habit_delete' && o['id'] == habitId,
        );
        await store?.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
      // Offline: local + queued; the sync replays the server delete.
      // (The local sub-tasks are already dropped with the habit.)
      try {
        await deleteSubtasksForHabit(habitId);
      } catch (_) {}
    }
    _notifyChanged();
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
    try {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'habit_logs',
        queries: [
          Query.equal('ownerUid', userId),
          Query.equal('date', date),
          Query.equal('completed', true),
        ],
      );
      final logs = list.rows
          .map((doc) => HabitLog.fromJson(_docJson(doc)))
          .toList();
      await _mergeCachedLogs(logs);
      return logs;
    } on Object catch (e) {
      // v2.9.0: no network → the cached logs for that date.
      if (isNetworkError(e)) {
        final store = await _localStore();
        final cached = store?.loadCachedHabitLogs(userId) ?? <HabitLog>[];
        return cached
            .where((l) => l.logDate == date && l.completed)
            .toList();
      }
      rethrow;
    }
  }

  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    final userId = _requireUserId();
    try {
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
      final logs = list.rows
          .map((doc) => HabitLog.fromJson(_docJson(doc)))
          .toList();
      await _mergeCachedLogs(logs);
      return logs;
    } on Object catch (e) {
      // v2.9.0: no network → the cached logs in that range.
      if (isNetworkError(e)) {
        final store = await _localStore();
        final cached = store?.loadCachedHabitLogs(userId) ?? <HabitLog>[];
        return cached
            .where(
              (l) =>
                  l.completed &&
                  l.logDate.compareTo(start) >= 0 &&
                  l.logDate.compareTo(end) <= 0,
            )
            .toList();
      }
      rethrow;
    }
  }

  /// Every completed habit log, newest first — the XP ledger on the
  /// Dashboard is derived from this (each log = +2 XP). Paginated: a
  /// long-term user has more than one page of logs. v2.9.0: a
  /// successful fetch refreshes the offline cache; offline, the
  /// cached logs are returned.
  Future<List<HabitLog>> listAllCompletedLogs() async {
    final userId = _requireUserId();
    try {
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
      // This is the full completed-log list — replace the cache with
      // it (a merge would keep stale logs for habits since deleted).
      final store = await _localStore();
      if (store != null) {
        try {
          await store.saveCachedHabitLogs(userId, all);
        } catch (_) {}
      }
      return all;
    } on Object catch (e) {
      if (isNetworkError(e)) {
        final store = await _localStore();
        final cached = store?.loadCachedHabitLogs(userId) ?? <HabitLog>[];
        cached.sort((a, b) => b.logDate.compareTo(a.logDate));
        return cached.where((l) => l.completed).toList();
      }
      rethrow;
    }
  }

  /// Distinct dates (newest first) with at least one completed habit.
  /// v2.9.0: offline, derived from the cached logs.
  Future<List<String>> activeDates({int limit = 370}) async {
    final userId = _requireUserId();
    try {
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
    } on Object catch (e) {
      if (isNetworkError(e)) {
        final store = await _localStore();
        final cached = store?.loadCachedHabitLogs(userId) ?? <HabitLog>[];
        final dates = cached
            .where((l) => l.completed)
            .map((l) => l.logDate)
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
        return dates.take(limit).toList();
      }
      rethrow;
    }
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
    // v2.9.0 offline-first: the local cache is the source of truth.
    // Apply the toggle locally RIGHT NOW (so the screen and every
    // reload show the right state even with no network) and queue
    // the server write in the outbox. The sync worker below still
    // pushes it to the server when online.
    try {
      final store = await LocalStore.getInstance();
      await store.applyCachedLog(
        ownerId: _requireUserId(),
        habitId: habit.id,
        date: date,
        done: completed,
      );
      await _recomputeLocalDerivedXp();
      await store.enqueueOutboxOp({
        'kind': 'log',
        'ownerUid': _requireUserId(),
        'habitId': habit.id,
        'date': date,
        'done': completed,
      });
    } catch (_) {}
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
          var applied = desired;
          result = await _writeQueue.run(() async {
            // Re-read the desire at execution time: a tap may have
            // changed it while this job waited in the queue.
            final current = _desiredLogState[logId] ?? desired;
            applied = current;
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
          // The server now holds this state — drop the matching
          // outbox op (if a newer tap replaced it, the content
          // differs and it stays queued).
          try {
            final store = await LocalStore.getInstance();
            final ops = store.loadOutbox();
            ops.removeWhere(
              (o) =>
                  o['kind'] == 'log' &&
                  o['habitId'] == habit.id &&
                  o['date'] == date &&
                  o['done'] == applied,
            );
            await store.saveOutbox(ops);
          } catch (_) {}
        } catch (e) {
          // Transient failure (network blip, read lag): retry the same
          // desire a couple of times before giving up. The waiters
          // stay pending — their UI already shows the desired state.
          failures++;
          if (failures >= 3) {
            // Persistent failure: give up on the server write. The
            // waiters that arrived before this point are completed —
            // with SUCCESS when it is a network failure (v2.9.0
            // offline: the local cache already holds the desired
            // state and the outbox op replays it when the network
            // returns, so the UI must NOT roll back), with the error
            // for a real server failure (their UI rolls back). This
            // block is synchronous, so a tap landing after it
            // schedules its own sync via the finally clause below
            // instead of being stranded.
            final waiters = _logSyncWaiters.remove(logId);
            _desiredLogState.remove(logId);
            if (waiters != null) {
              if (isNetworkError(e)) {
                for (final w in waiters) {
                  if (!w.isCompleted) {
                    w.complete(
                      const ToggleResult(xpDelta: 0, allDone: false),
                    );
                  }
                }
              } else {
                for (final w in waiters) {
                  if (!w.isCompleted) w.completeError(e);
                }
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

  // -- v2.9.0 outbox replay (server-only; used by SyncService) ---------
  // These never touch the local cache or the outbox — the caller
  // (SyncService) removes the op after a successful replay. They
  // throw on network failure so the sync stops and keeps the op
  // queued.

  /// Replays a queued log toggle: the server write + verify +
  /// derived-XP reconcile, in the serialised write queue.
  Future<void> replayLogOp({
    required String habitId,
    required String date,
    required bool done,
  }) async {
    final habit = Habit(id: habitId, userId: _requireUserId(), title: '');
    final logId = _logDocId(habitId, date);
    return _writeQueue.run(() async {
      await _applyLogState(
        habit: habit,
        date: date,
        logId: logId,
        done: done,
      );
      await _verifyLogWithRetry(logId: logId, expectDone: done);
      await ProfileRepository(db: _db)._recomputeDerivedXpNow();
    });
  }

  /// Replays a queued habit add (the id was generated locally, so
  /// this is idempotent — a 409 means it already landed).
  Future<void> replayHabitAdd({
    required String id,
    required String title,
    required int color,
  }) async {
    final userId = _requireUserId();
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'habits',
        rowId: id,
        data: {
          'ownerUid': userId,
          'title': title,
          'color': color,
          'archived': false,
        },
        permissions: _ownerPerms(userId),
      );
    } on AppwriteException catch (e) {
      if (e.code != 409) rethrow;
    }
  }

  /// Replays a queued habit update.
  Future<void> replayHabitUpdate({
    required String id,
    String? title,
    int? color,
    String? notes,
  }) async {
    final updates = <String, Object>{};
    if (title != null) updates['title'] = title;
    if (color != null) updates['color'] = color;
    if (updates.isNotEmpty) {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: 'habits',
        rowId: id,
        data: updates,
      );
    }
    if (notes != null && _notesColumnAvailable) {
      try {
        await _d.updateRow(
          databaseId: _dbId,
          tableId: 'habits',
          rowId: id,
          data: {'notes': notes},
        );
      } on AppwriteException catch (e) {
        if (e.code == 400) {
          _notesColumnAvailable = false;
          await _saveLocalNote(id, notes);
        } else {
          rethrow;
        }
      }
    }
  }

  /// Replays a queued habit archive.
  Future<void> replayHabitArchive(String habitId) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'habits',
      rowId: habitId,
      data: {'archived': true},
    );
  }

  /// Replays a queued habit delete (the server side only — the local
  /// cache was already cleared when the user deleted it).
  Future<void> replayHabitDelete(String habitId) async {
    return _writeQueue.run(() => _deleteHabitOnServer(habitId));
  }

  /// The server side of a habit delete (logs + XP + sub-tasks +
  /// archive). Shared by [deleteHabit] and [replayHabitDelete].
  Future<void> _deleteHabitOnServer(String habitId) async {
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
    await deleteSubtasksForHabit(habitId);
    await _deleteLocalNote(habitId);
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'habits',
      rowId: habitId,
      data: {'archived': true},
    );
  }

  /// Replays a queued sub-task log toggle (server-only; throws on a
  /// network failure so the sync keeps it queued). Idempotent: a 409
  /// on create means it already landed, a 404 on delete means it is
  /// already gone.
  Future<void> replaySubtaskLog({
    required String subtaskId,
    required String date,
    required bool done,
  }) async {
    final logId = _subtaskLogDocId(subtaskId, date);
    if (done) {
      try {
        await _d.createRow(
          databaseId: _dbId,
          tableId: 'subtask_logs',
          rowId: logId,
          data: {
            'subtaskId': subtaskId,
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
  }

  /// Replays a queued sub-task add (server-only; 409 = already there).
  Future<void> replaySubtaskAdd({
    required String id,
    required String habitId,
    required String title,
    required String kind,
    required String date,
  }) async {
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'habit_subtasks',
        rowId: id,
        data: {
          'habitId': habitId,
          'title': title,
          'kind': kind,
          'date': date,
          'archived': false,
        },
        permissions: _ownerPerms(_requireUserId()),
      );
    } on AppwriteException catch (e) {
      if (e.code != 409) rethrow;
    }
  }

  /// Replays a queued sub-task delete (server-only).
  Future<void> replaySubtaskDelete(String subtaskId) async {
    await _deleteSubtaskRows(subtaskId);
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
        } else if (isNetworkError(e)) {
          // v2.9.0 offline: queue the replay, store locally below.
          await _enqueueOp({
            'kind': 'subtask_add',
            'ownerUid': userId,
            'id': id,
            'habitId': habit.id,
            'title': title,
            'subtaskKind': kind,
            'date': date,
          });
        } else {
          rethrow;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      } on Object catch (e) {
        if (!isNetworkError(e)) rethrow;
        await _enqueueOp({
          'kind': 'subtask_add',
          'ownerUid': userId,
          'id': id,
          'habitId': habit.id,
          'title': title,
          'subtaskKind': kind,
          'date': date,
        });
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
        } else if (isNetworkError(e)) {
          // v2.9.0 offline: queue the replay, delete locally below.
          await _enqueueOp({
            'kind': 'subtask_delete',
            'ownerUid': _requireUserId(),
            'id': subtask.id,
          });
        } else {
          rethrow;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      } on Object catch (e) {
        if (!isNetworkError(e)) rethrow;
        await _enqueueOp({
          'kind': 'subtask_delete',
          'ownerUid': _requireUserId(),
          'id': subtask.id,
        });
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
            // Persistent failure. v2.9.0 offline: a network failure
            // means the sub-task log is already stored locally (see
            // _writeSubtaskLog) and queued for the sync — so the
            // toggle SUCCEEDS from the user's view and the UI must
            // NOT roll back. A real server failure still errors.
            final waiters = _subtaskSyncWaiters.remove(logId);
            _desiredSubtaskState.remove(logId);
            if (waiters != null) {
              for (final w in waiters) {
                if (!w.isCompleted) {
                  if (isNetworkError(e)) {
                    w.complete();
                  } else {
                    w.completeError(e);
                  }
                }
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
  /// to on-device storage when the table is missing. v2.9.0: a
  /// network failure also falls back to on-device storage (and queues
  /// a replay op) — the habit's done state is derived from the local
  /// logs, so the toggle still works offline.
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
        } else if (isNetworkError(e)) {
          // Offline: queue the replay, then store locally below.
          await _enqueueOp({
            'kind': 'subtask_log',
            'ownerUid': _requireUserId(),
            'subtaskId': subtask.id,
            'date': date,
            'done': done,
          });
        } else {
          rethrow;
        }
      } on AppwriteNotConfigured {
        // Local fallback below.
      } on Object catch (e) {
        if (!isNetworkError(e)) rethrow;
        await _enqueueOp({
          'kind': 'subtask_log',
          'ownerUid': _requireUserId(),
          'subtaskId': subtask.id,
          'date': date,
          'done': done,
        });
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
    try {
      await _applyLogState(
        habit: habit,
        date: date,
        logId: logId,
        done: allDone,
      );
      await _verifyLogWithRetry(logId: logId, expectDone: allDone);
      await ProfileRepository(db: _db)._recomputeDerivedXpNow();
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
      // v2.9.0 offline: the habit log + XP are derived locally (the
      // sub-task logs above already came from local storage), and the
      // server write is queued for the background sync.
      try {
        final store = await LocalStore.getInstance();
        await store.applyCachedLog(
          ownerId: _requireUserId(),
          habitId: habit.id,
          date: date,
          done: allDone,
        );
        await _recomputeLocalDerivedXp();
        await store.enqueueOutboxOp({
          'kind': 'log',
          'ownerUid': _requireUserId(),
          'habitId': habit.id,
          'date': date,
          'done': allDone,
        });
      } catch (_) {}
    }
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
    try {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'weekly_tasks',
        queries: [
          Query.equal('ownerUid', userId),
          Query.equal('weekStart', weekStart),
          Query.orderAsc(r'$createdAt'),
        ],
      );
      final tasks = list.rows
          .map((doc) => WeeklyTask.fromJson(_docJson(doc)))
          .toList();
      // Refresh the offline cache (best-effort).
      try {
        final store = await LocalStore.getInstance();
        final cached = store.loadCachedTasks(userId);
        final merged = <WeeklyTask>[
          ...cached.weekly.where((t) => t.weekStart != weekStart),
          ...tasks,
        ];
        await store.saveCachedTasks(userId, merged, cached.monthly);
      } catch (_) {}
      return tasks;
    } on Object catch (e) {
      // v2.9.0: no network → the cached tasks for that week.
      if (isNetworkError(e)) {
        try {
          final store = await LocalStore.getInstance();
          return store
              .loadCachedTasks(userId)
              .weekly
              .where((t) => t.weekStart == weekStart)
              .toList();
        } catch (_) {
          return <WeeklyTask>[];
        }
      }
      rethrow;
    }
  }

  /// Adds a weekly task. v2.9.0 offline-first: local id + cache +
  /// outbox, server best-effort.
  Future<void> addWeeklyTask(String title, String weekStart) async {
    final userId = _requireUserId();
    final id = ID.unique();
    final task = WeeklyTask(
      id: id,
      userId: userId,
      title: title,
      weekStart: weekStart,
    );
    try {
      final store = await LocalStore.getInstance();
      final cached = store.loadCachedTasks(userId);
      await store.saveCachedTasks(
        userId,
        [...cached.weekly, task],
        cached.monthly,
      );
      await store.enqueueOutboxOp({
        'kind': 'task_add_weekly',
        'ownerUid': userId,
        'id': id,
        'title': title,
        'key': weekStart,
      });
    } catch (_) {}
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'weekly_tasks',
        rowId: id,
        data: {
          'ownerUid': userId,
          'title': title,
          'weekStart': weekStart,
          'done': false,
        },
        permissions: _ownerPerms(userId),
      );
      try {
        final store = await LocalStore.getInstance();
        final ops = store.loadOutbox();
        ops.removeWhere(
          (o) => o['kind'] == 'task_add_weekly' && o['id'] == id,
        );
        await store.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) {
        try {
          final store = await LocalStore.getInstance();
          final cached = store.loadCachedTasks(userId);
          await store.saveCachedTasks(
            userId,
            cached.weekly.where((t) => t.id != id).toList(),
            cached.monthly,
          );
        } catch (_) {}
        rethrow;
      }
    }
    _notifyChanged();
  }

  /// Every done weekly task, newest week first — the XP ledger on the
  /// Dashboard is derived from this (each done task = +2 XP).
  /// (listWeeklyTasks only covers one week; the ledger needs all.)
  /// v2.9.0: offline, the cached done tasks are returned.
  Future<List<WeeklyTask>> listAllDoneWeeklyTasks() async {
    final userId = _requireUserId();
    try {
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
    } on Object catch (e) {
      if (isNetworkError(e)) {
        try {
          final store = await LocalStore.getInstance();
          final done = store
              .loadCachedTasks(userId)
              .weekly
              .where((t) => t.done)
              .toList()
            ..sort((a, b) => b.weekStart.compareTo(a.weekStart));
          return done;
        } catch (_) {
          return <WeeklyTask>[];
        }
      }
      rethrow;
    }
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

  /// Applies a task toggle to the local cache. Returns the previous
  /// `done` value, or null when the task is not cached. v2.9.0.
  Future<bool?> _applyLocalTaskToggle({
    required bool weekly,
    required String id,
    required bool done,
  }) async {
    try {
      final userId = _requireUserId();
      final store = await LocalStore.getInstance();
      final cached = store.loadCachedTasks(userId);
      if (weekly) {
        final index = cached.weekly.indexWhere((t) => t.id == id);
        if (index < 0) return null;
        final wasDone = cached.weekly[index].done;
        final task = cached.weekly[index];
        cached.weekly[index] = WeeklyTask(
          id: task.id,
          userId: task.userId,
          title: task.title,
          weekStart: task.weekStart,
          done: done,
        );
        await store.saveCachedTasks(userId, cached.weekly, cached.monthly);
        return wasDone;
      }
      final index = cached.monthly.indexWhere((t) => t.id == id);
      if (index < 0) return null;
      final wasDone = cached.monthly[index].done;
      final task = cached.monthly[index];
      cached.monthly[index] = MonthlyTask(
        id: task.id,
        userId: task.userId,
        title: task.title,
        month: task.month,
        done: done,
      );
      await store.saveCachedTasks(userId, cached.weekly, cached.monthly);
      return wasDone;
    } catch (_) {
      return null;
    }
  }

  /// Removes a task from the local cache. v2.9.0.
  Future<bool?> _removeLocalTask({
    required bool weekly,
    required String id,
  }) async {
    try {
      final userId = _requireUserId();
      final store = await LocalStore.getInstance();
      final cached = store.loadCachedTasks(userId);
      if (weekly) {
        final index = cached.weekly.indexWhere((t) => t.id == id);
        if (index < 0) return null;
        final wasDone = cached.weekly[index].done;
        cached.weekly.removeAt(index);
        await store.saveCachedTasks(userId, cached.weekly, cached.monthly);
        return wasDone;
      }
      final index = cached.monthly.indexWhere((t) => t.id == id);
      if (index < 0) return null;
      final wasDone = cached.monthly[index].done;
      cached.monthly.removeAt(index);
      await store.saveCachedTasks(userId, cached.weekly, cached.monthly);
      return wasDone;
    } catch (_) {
      return null;
    }
  }

  /// Toggles a weekly task: +2 XP on completing, -2 XP on unticking
  /// (the full reversal — a done task is worth +2, a blank one 0).
  /// Reads the current state first so toggling to the same state
  /// grants nothing. Serialised with the other XP writes so two quick
  /// toggles cannot read the same stale state. v2.9.0 offline-first:
  /// the local cache + local XP update immediately; the server write
  /// is queued when offline.
  Future<void> toggleWeeklyTask(String id, bool done) async {
    final userId = _requireUserId();
    await _applyLocalTaskToggle(weekly: true, id: id, done: done);
    await recomputeLocalDerivedXpForUser();
    try {
      final store = await LocalStore.getInstance();
      await store.enqueueOutboxOp({
        'kind': 'task_toggle_weekly',
        'ownerUid': userId,
        'id': id,
        'done': done,
      });
    } catch (_) {}
    try {
      await _writeQueue.run(() async {
        final wasDone = await _taskDone('weekly_tasks', id);
        await _d.updateRow(
          databaseId: _dbId,
          tableId: 'weekly_tasks',
          rowId: id,
          data: {'done': done},
        );
        if (wasDone != null) {
          await _adjustXp(
            xpDeltaForToggle(completing: done, wasDone: wasDone),
          );
        }
        _notifyChanged();
      });
      try {
        final store = await LocalStore.getInstance();
        final ops = store.loadOutbox();
        ops.removeWhere(
          (o) => o['kind'] == 'task_toggle_weekly' && o['id'] == id,
        );
        await store.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
      _notifyChanged();
    }
  }

  /// Deletes a weekly task. A task that was done loses its full +2 XP
  /// — deleting must not leave phantom XP behind. v2.9.0 offline-first:
  /// local cache + local XP first, server best-effort.
  Future<void> deleteWeeklyTask(String id) async {
    final userId = _requireUserId();
    await _removeLocalTask(weekly: true, id: id);
    await recomputeLocalDerivedXpForUser();
    try {
      final store = await LocalStore.getInstance();
      await store.enqueueOutboxOp({
        'kind': 'task_delete_weekly',
        'ownerUid': userId,
        'id': id,
      });
    } catch (_) {}
    try {
      await _writeQueue.run(() async {
        final wasDone = await _taskDone('weekly_tasks', id);
        await _d.deleteRow(
          databaseId: _dbId,
          tableId: 'weekly_tasks',
          rowId: id,
        );
        if (wasDone == true) {
          await _adjustXp(-xpPerTask);
        }
        _notifyChanged();
      });
      try {
        final store = await LocalStore.getInstance();
        final ops = store.loadOutbox();
        ops.removeWhere(
          (o) => o['kind'] == 'task_delete_weekly' && o['id'] == id,
        );
        await store.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
      _notifyChanged();
    }
  }

  Future<List<MonthlyTask>> listMonthlyTasks(String month) async {
    final userId = _requireUserId();
    try {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'monthly_tasks',
        queries: [
          Query.equal('ownerUid', userId),
          Query.equal('month', month),
          Query.orderAsc(r'$createdAt'),
        ],
      );
      final tasks = list.rows
          .map((doc) => MonthlyTask.fromJson(_docJson(doc)))
          .toList();
      // Refresh the offline cache (best-effort).
      try {
        final store = await LocalStore.getInstance();
        final cached = store.loadCachedTasks(userId);
        final merged = <MonthlyTask>[
          ...cached.monthly.where((t) => t.month != month),
          ...tasks,
        ];
        await store.saveCachedTasks(userId, cached.weekly, merged);
      } catch (_) {}
      return tasks;
    } on Object catch (e) {
      // v2.9.0: no network → the cached tasks for that month.
      if (isNetworkError(e)) {
        try {
          final store = await LocalStore.getInstance();
          return store
              .loadCachedTasks(userId)
              .monthly
              .where((t) => t.month == month)
              .toList();
        } catch (_) {
          return <MonthlyTask>[];
        }
      }
      rethrow;
    }
  }

  /// Adds a monthly task. v2.9.0 offline-first: local id + cache +
  /// outbox, server best-effort.
  Future<void> addMonthlyTask(String title, String month) async {
    final userId = _requireUserId();
    final id = ID.unique();
    final task = MonthlyTask(
      id: id,
      userId: userId,
      title: title,
      month: month,
    );
    try {
      final store = await LocalStore.getInstance();
      final cached = store.loadCachedTasks(userId);
      await store.saveCachedTasks(
        userId,
        cached.weekly,
        [...cached.monthly, task],
      );
      await store.enqueueOutboxOp({
        'kind': 'task_add_monthly',
        'ownerUid': userId,
        'id': id,
        'title': title,
        'key': month,
      });
    } catch (_) {}
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'monthly_tasks',
        rowId: id,
        data: {'ownerUid': userId, 'title': title, 'month': month, 'done': false},
        permissions: _ownerPerms(userId),
      );
      try {
        final store = await LocalStore.getInstance();
        final ops = store.loadOutbox();
        ops.removeWhere(
          (o) => o['kind'] == 'task_add_monthly' && o['id'] == id,
        );
        await store.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) {
        try {
          final store = await LocalStore.getInstance();
          final cached = store.loadCachedTasks(userId);
          await store.saveCachedTasks(
            userId,
            cached.weekly,
            cached.monthly.where((t) => t.id != id).toList(),
          );
        } catch (_) {}
        rethrow;
      }
    }
    _notifyChanged();
  }

  /// Every done monthly task, newest month first — the XP ledger on the
  /// Dashboard is derived from this (each done task = +2 XP).
  /// v2.9.0: offline, the cached done tasks are returned.
  Future<List<MonthlyTask>> listAllDoneMonthlyTasks() async {
    final userId = _requireUserId();
    try {
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
    } on Object catch (e) {
      if (isNetworkError(e)) {
        try {
          final store = await LocalStore.getInstance();
          final done = store
              .loadCachedTasks(userId)
              .monthly
              .where((t) => t.done)
              .toList()
            ..sort((a, b) => b.month.compareTo(a.month));
          return done;
        } catch (_) {
          return <MonthlyTask>[];
        }
      }
      rethrow;
    }
  }

  /// Toggles a monthly task: same +2 / -2 XP rule as weekly tasks.
  /// v2.9.0 offline-first: local cache + local XP first, server
  /// best-effort (queued when offline).
  Future<void> toggleMonthlyTask(String id, bool done) async {
    final userId = _requireUserId();
    await _applyLocalTaskToggle(weekly: false, id: id, done: done);
    await recomputeLocalDerivedXpForUser();
    try {
      final store = await LocalStore.getInstance();
      await store.enqueueOutboxOp({
        'kind': 'task_toggle_monthly',
        'ownerUid': userId,
        'id': id,
        'done': done,
      });
    } catch (_) {}
    try {
      await _writeQueue.run(() async {
        final wasDone = await _taskDone('monthly_tasks', id);
        await _d.updateRow(
          databaseId: _dbId,
          tableId: 'monthly_tasks',
          rowId: id,
          data: {'done': done},
        );
        if (wasDone != null) {
          await _adjustXp(
            xpDeltaForToggle(completing: done, wasDone: wasDone),
          );
        }
        _notifyChanged();
      });
      try {
        final store = await LocalStore.getInstance();
        final ops = store.loadOutbox();
        ops.removeWhere(
          (o) => o['kind'] == 'task_toggle_monthly' && o['id'] == id,
        );
        await store.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
      _notifyChanged();
    }
  }

  /// Deletes a monthly task. A task that was done loses its full +2 XP
  /// — deleting must not leave phantom XP behind. v2.9.0 offline-first.
  Future<void> deleteMonthlyTask(String id) async {
    final userId = _requireUserId();
    await _removeLocalTask(weekly: false, id: id);
    await recomputeLocalDerivedXpForUser();
    try {
      final store = await LocalStore.getInstance();
      await store.enqueueOutboxOp({
        'kind': 'task_delete_monthly',
        'ownerUid': userId,
        'id': id,
      });
    } catch (_) {}
    try {
      await _writeQueue.run(() async {
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
      try {
        final store = await LocalStore.getInstance();
        final ops = store.loadOutbox();
        ops.removeWhere(
          (o) => o['kind'] == 'task_delete_monthly' && o['id'] == id,
        );
        await store.saveOutbox(ops);
      } catch (_) {}
    } on Object catch (e) {
      if (!isNetworkError(e)) rethrow;
      _notifyChanged();
    }
  }

  // -- v2.9.0 outbox replay (server-only; used by SyncService) ---------

  /// Replays a queued task add (server-only; 409 = already there).
  Future<void> replayTaskAdd({
    required bool weekly,
    required String id,
    required String title,
    required String key,
  }) async {
    final userId = _requireUserId();
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: weekly ? 'weekly_tasks' : 'monthly_tasks',
        rowId: id,
        data: weekly
            ? {
                'ownerUid': userId,
                'title': title,
                'weekStart': key,
                'done': false,
              }
            : {
                'ownerUid': userId,
                'title': title,
                'month': key,
                'done': false,
              },
        permissions: _ownerPerms(userId),
      );
    } on AppwriteException catch (e) {
      if (e.code != 409) rethrow;
    }
  }

  /// Replays a queued task toggle (server-only). The server XP is
  /// healed by the derived-XP recompute the sync runs afterwards.
  Future<void> replayTaskToggle({
    required bool weekly,
    required String id,
    required bool done,
  }) async {
    return _writeQueue.run(() async {
      await _d.updateRow(
        databaseId: _dbId,
        tableId: weekly ? 'weekly_tasks' : 'monthly_tasks',
        rowId: id,
        data: {'done': done},
      );
    });
  }

  /// Replays a queued task delete (server-only; 404 = already gone).
  Future<void> replayTaskDelete({
    required bool weekly,
    required String id,
  }) async {
    try {
      await _d.deleteRow(
        databaseId: _dbId,
        tableId: weekly ? 'weekly_tasks' : 'monthly_tasks',
        rowId: id,
      );
    } on AppwriteException catch (e) {
      if (e.code != 404) rethrow;
    }
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

  /// The follow row for (me → [followingId]) as raw JSON, or null
  /// when not following. Follow rows are created with [ID.unique()] —
  /// a composite id like '${followerId}_$followingId' is 41 chars,
  /// over Appwrite's 36-char document-id limit, so it must be looked
  /// up, not computed.
  Future<Map<String, dynamic>?> _findFollowRow(String followingId) async {
    final userId = _requireUserId();
    final list = await _d.listRows(
      databaseId: _dbId,
      tableId: 'follows',
      queries: [
        Query.equal('followerUid', userId),
        Query.equal('followingUid', followingId),
        Query.limit(1),
      ],
    );
    if (list.rows.isEmpty) return null;
    return _docJson(list.rows.first);
  }

  /// Id of the follow row for (me → [followingId]), or null when not
  /// following.
  Future<String?> _findFollowDocId(String followingId) async {
    final row = await _findFollowRow(followingId);
    return row?['id'] as String?;
  }

  /// The follow status of a row: 'accepted' when the `status`
  /// attribute is missing or null (rows written before v2.9.0, and
  /// the attribute's default), 'pending' for a follow request that
  /// has not been accepted yet.
  static String followStatusOf(Map<String, dynamic> row) {
    return row['status'] as String? ?? 'accepted';
  }

  /// 'none' | 'pending' | 'accepted' — my follow state towards
  /// [followingId]. A pending request is NOT "following".
  Future<String> followStatus(String followingId) async {
    final row = await _findFollowRow(followingId);
    if (row == null) return 'none';
    return followStatusOf(row);
  }

  /// Follows [followingId]. v2.9.0: a follow on a PUBLIC account is
  /// direct (status 'accepted'); a follow on a PRIVATE account is a
  /// REQUEST (status 'pending') — the other user accepts or declines
  /// it in their Notifications. If the `status` attribute is not on
  /// the live table yet, the row is created without it (accepted by
  /// default) and the request model degrades to a direct follow.
  Future<void> follow(String followingId) async {
    final userId = _requireUserId();
    final profiles = ProfileRepository(db: _db);
    final target = await profiles.fetchProfile(followingId);
    final status = (target != null && !target.isPublic)
        ? 'pending'
        : 'accepted';
    final data = <String, dynamic>{
      'followerUid': userId,
      'followingUid': followingId,
      'status': status,
    };
    try {
      await _d.createRow(
        databaseId: _dbId,
        tableId: 'follows',
        rowId: ID.unique(),
        data: data,
        permissions: [
          Permission.read(Role.users()),
          Permission.update(Role.user(userId)),
          Permission.delete(Role.user(userId)),
        ],
      );
    } on AppwriteException catch (e) {
      if (e.code == 400) {
        // The `status` attribute is not on the live table yet.
        await _d.createRow(
          databaseId: _dbId,
          tableId: 'follows',
          rowId: ID.unique(),
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
      } else {
        rethrow;
      }
    }
  }

  Future<void> unfollow(String followingId) async {
    final docId = await _findFollowDocId(followingId);
    if (docId == null) return;
    await _d.deleteRow(
      databaseId: _dbId,
      tableId: 'follows',
      rowId: docId,
    );
  }

  /// True only when the follow is ACCEPTED (a pending request is not
  /// "following" — the button shows "Requested" instead).
  Future<bool> isFollowing(String followingId) async {
    return (await followStatus(followingId)) == 'accepted';
  }

  /// The follow rows where I am the follower, newest first
  /// (paginated). [onlyAccepted] drops pending requests.
  /// The follow rows where [field] == [value] (paginated). [onlyAccepted]
  /// drops pending requests. Order is the server's default (oldest
  /// first) unless [newestFirst] is set — the id lists (followers /
  /// following) keep the old order, only the Notifications entries
  /// (requests + recent followers) need newest first.
  Future<List<Map<String, dynamic>>> _followRowsWhere({
    required String field,
    required String value,
    bool onlyAccepted = false,
    bool newestFirst = false,
  }) async {
    final rows = <Map<String, dynamic>>[];
    const page = 100;
    var offset = 0;
    while (true) {
      final list = await _d.listRows(
        databaseId: _dbId,
        tableId: 'follows',
        queries: [
          Query.equal(field, value),
          if (newestFirst) Query.orderDesc(r'$createdAt'),
          Query.limit(page),
          Query.offset(offset),
        ],
      );
      for (final doc in list.rows) {
        final row = _docJson(doc);
        if (onlyAccepted && followStatusOf(row) != 'accepted') continue;
        rows.add(row);
      }
      if (list.rows.length < page) break;
      offset += page;
    }
    return rows;
  }

  /// Ids of the users [userId] follows (accepted only — a pending
  /// request is not a follow yet).
  Future<List<String>> followingIdsFor(String userId) async {
    final rows = await _followRowsWhere(
      field: 'followerUid',
      value: userId,
      onlyAccepted: true,
    );
    return rows.map((r) => r['followingUid'] as String).toList();
  }

  /// Ids of the users following [userId] (accepted only).
  Future<List<String>> followersIdsFor(String userId) async {
    final rows = await _followRowsWhere(
      field: 'followingUid',
      value: userId,
      onlyAccepted: true,
    );
    return rows.map((r) => r['followerUid'] as String).toList();
  }

  /// Ids of the users I follow (accepted only — a pending request is
  /// not a follow yet).
  Future<List<String>> followingIds() => followingIdsFor(_requireUserId());

  /// Ids of the users following me (accepted only).
  Future<List<String>> followersIds() => followersIdsFor(_requireUserId());

  /// Pending follow REQUESTS to me (v2.9.0): (follow doc id, the
  /// requester's profile), newest first. Accept → 'accepted';
  /// Decline → the row is deleted.
  Future<List<(String, Profile)>> pendingFollowRequests() async {
    final userId = _requireUserId();
    final rows = await _followRowsWhere(
      field: 'followingUid',
      value: userId,
      newestFirst: true,
    );
    final profilesRepo = ProfileRepository(db: _db);
    final requests = <(String, Profile)>[];
    for (final row in rows) {
      if (followStatusOf(row) != 'pending') continue;
      final followerId = row['followerUid'] as String?;
      if (followerId == null) continue;
      final profile = await profilesRepo.fetchProfile(followerId);
      if (profile != null) {
        requests.add(((row['id'] as String?) ?? '', profile));
      }
    }
    return requests;
  }

  /// Recent followers (accepted, newest first, up to [limit]) — the
  /// "X started following you" entries on the Notifications screen.
  Future<List<Profile>> recentFollowers({int limit = 20}) async {
    final userId = _requireUserId();
    final rows = await _followRowsWhere(
      field: 'followingUid',
      value: userId,
      onlyAccepted: true,
      newestFirst: true,
    );
    final profilesRepo = ProfileRepository(db: _db);
    final followers = <Profile>[];
    for (final row in rows.take(limit)) {
      final followerId = row['followerUid'] as String?;
      if (followerId == null) continue;
      final profile = await profilesRepo.fetchProfile(followerId);
      if (profile != null) followers.add(profile);
    }
    return followers;
  }

  /// Accepts a pending follow request (v2.9.0).
  Future<void> acceptFollowRequest(String docId) async {
    await _d.updateRow(
      databaseId: _dbId,
      tableId: 'follows',
      rowId: docId,
      data: {'status': 'accepted'},
    );
  }

  /// Declines a pending follow request (v2.9.0): the row is deleted.
  Future<void> declineFollowRequest(String docId) async {
    await _d.deleteRow(
      databaseId: _dbId,
      tableId: 'follows',
      rowId: docId,
    );
  }

  /// Ids of my mutual friends (v2.9.0): users where BOTH follow each
  /// other, both accepted. A one-sided follow does NOT count.
  Future<List<String>> mutualFriendIds() async {
    final following = await followingIds();
    final followers = await followersIds();
    final followerSet = followers.toSet();
    return following.where((id) => followerSet.contains(id)).toList();
  }

  /// Profiles of my mutual friends, sorted by display name.
  Future<List<Profile>> mutualFriends() async {
    final ids = await mutualFriendIds();
    final profilesRepo = ProfileRepository(db: _db);
    final profiles = <Profile>[];
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

  /// True when [userId] and I follow each other (both accepted) —
  /// the only case a private account's habits are visible to me.
  Future<bool> isMutual(String userId) async {
    final following = await followingIds();
    if (!following.contains(userId)) return false;
    final followers = await followersIds();
    return followers.contains(userId);
  }

  /// Public profiles of [userId]'s followers (or the people they
  /// follow), sorted by display name. [userId] defaults to me, so
  /// the Followers / Following lists on my own Profile work exactly
  /// as before; passing another user's id lists THEIR followers /
  /// following instead (v2.11.1 — the lists on another user's
  /// profile are tappable now). Callers must respect the visibility
  /// rules: only call this for a user whose account may be seen.
  Future<List<Profile>> followProfiles({
    required bool followers,
    String? userId,
  }) async {
    final target = userId ?? _requireUserId();
    final ids = followers
        ? await followersIdsFor(target)
        : await followingIdsFor(target);
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

  /// How many users [userId] follows (accepted only).
  Future<int> followingCount(String userId) async {
    final rows = await _followRowsWhere(
      field: 'followerUid',
      value: userId,
      onlyAccepted: true,
    );
    return rows.length;
  }

  /// How many users follow [userId] (accepted only).
  Future<int> followersCount(String userId) async {
    final rows = await _followRowsWhere(
      field: 'followingUid',
      value: userId,
      onlyAccepted: true,
    );
    return rows.length;
  }

  /// How many follow requests are waiting for me (the bell badge).
  Future<int> pendingRequestCount() async {
    final userId = _requireUserId();
    final rows = await _followRowsWhere(
      field: 'followingUid',
      value: userId,
    );
    return rows.where((r) => followStatusOf(r) == 'pending').length;
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
