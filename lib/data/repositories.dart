/// All Firebase access lives in this file (plus [FirebaseService]).
///
/// Screens must never call Firebase directly. Repositories degrade
/// gracefully when Firebase is unconfigured: every method throws
/// [FirebaseNotConfigured], which the UI turns into a friendly notice.
///
/// For widget tests, screens accept optional repository instances; tests
/// pass in-memory fakes that subclass these classes.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../config.dart';
import '../logic/xp.dart';
import 'firebase_service.dart';
import 'models.dart';

// ---------------------------------------------------------------------------
// Small auth types (so screens never import firebase_auth directly)
// ---------------------------------------------------------------------------

/// Thrown for auth failures with a user-facing message.
class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _friendlyAuthError(FirebaseAuthException e) {
  return switch (e.code) {
    'user-not-found' ||
    'wrong-password' ||
    'invalid-credential' => 'Wrong email or password. Try again.',
    'email-already-in-use' =>
      'An account with this email already exists. Log in instead.',
    'weak-password' => 'Password is too weak — use at least 6 characters.',
    'invalid-email' => 'That email address does not look right.',
    'user-disabled' => 'This account has been disabled.',
    'too-many-requests' =>
      'Too many attempts. Wait a bit, then try again.',
    'network-request-failed' =>
      'No network connection. Check your internet and try again.',
    'requires-recent-login' =>
      'Please log in again, then try this once more.',
    _ => e.message ?? 'Something went wrong. Please try again.',
  };
}

AuthException _wrapAuthError(Object e) {
  if (e is FirebaseAuthException) return AuthException(_friendlyAuthError(e));
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

  factory AppAuthUser.fromFirebase(User user) => AppAuthUser(
    uid: user.uid,
    email: user.email,
    displayName: user.displayName,
    photoURL: user.photoURL,
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

FirebaseAuth _requireAuth(FirebaseAuth? injected) {
  final auth = injected ?? FirebaseService.authOrNull;
  if (auth == null) throw FirebaseNotConfigured();
  return auth;
}

FirebaseFirestore _requireDb(FirebaseFirestore? injected) {
  final db = injected ?? FirebaseService.dbOrNull;
  if (db == null) throw FirebaseNotConfigured();
  return db;
}

String _requireUserId(FirebaseAuth auth) {
  final user = auth.currentUser;
  if (user == null) throw const AuthException('Not signed in.');
  return user.uid;
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

class AuthRepository {
  AuthRepository({this._auth, this._db});

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _db;

  FirebaseAuth get _a => _requireAuth(_auth);
  FirebaseFirestore get _d => _requireDb(_db);

  AppAuthUser? get currentUser {
    final user = _auth?.currentUser ?? FirebaseService.authOrNull?.currentUser;
    return user == null ? null : AppAuthUser.fromFirebase(user);
  }

  Stream<AuthChange> get onAuthStateChange {
    final auth = _a;
    return auth.authStateChanges().map(
      (user) => AuthChange(
        event: user == null ? AuthEvent.signedOut : AuthEvent.signedIn,
        user: user == null ? null : AppAuthUser.fromFirebase(user),
      ),
    );
  }

  Future<void> signIn({
    required String email,
    required String password,
  }) async {
    try {
      await _a.signInWithEmailAndPassword(email: email, password: password);
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  /// Creates the auth account AND the profile + username documents.
  /// Returns true when the user is signed in right away (Firebase signs
  /// in immediately after email+password signup; email verification is
  /// not enforced).
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
      final cred = await auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final user = cred.user;
      if (user == null) return false;
      final name = displayName.isEmpty ? lower : displayName;
      await user.updateDisplayName(name);
      final profile = Profile(
        id: user.uid,
        username: lower,
        displayName: name,
      );
      final batch = db.batch();
      batch.set(db.collection('users').doc(user.uid), profile.toMap());
      batch.set(db.collection('usernames').doc(lower), {
        'username': lower,
        'ownerUid': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      await batch.commit();
      return true;
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> signInWithGoogle() async {
    try {
      await _a.signInWithProvider(GoogleAuthProvider());
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> sendPasswordReset(String email) async {
    try {
      await _a.sendPasswordResetEmail(
        email: email,
        actionCodeSettings: ActionCodeSettings(
          url: AppConfig.resetContinueUrl,
          handleCodeInApp: true,
        ),
      );
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  /// The `oobCode` from the reset link (?mode=resetPassword&oobCode=...).
  Future<String> verifyResetCode(String code) async {
    try {
      return await _a.verifyPasswordResetCode(code);
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> confirmPasswordReset({
    required String code,
    required String newPassword,
  }) async {
    try {
      await _a.confirmPasswordReset(code: code, newPassword: newPassword);
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> updatePassword(String newPassword) async {
    try {
      final user = _a.currentUser;
      if (user == null) throw const AuthException('Not signed in.');
      await user.updatePassword(newPassword);
    } catch (e) {
      throw _wrapAuthError(e);
    }
  }

  Future<void> signOut() async {
    await _a.signOut();
  }
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

class ProfileRepository {
  ProfileRepository({this._auth, this._db});

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _db;

  FirebaseAuth get _a => _requireAuth(_auth);
  FirebaseFirestore get _d => _requireDb(_db);

  Future<Profile?> fetchMyProfile() async {
    final userId = _requireUserId(_a);
    return fetchProfile(userId);
  }

  Future<Profile?> fetchProfile(String userId) async {
    final doc = await _d.collection('users').doc(userId).get();
    if (!doc.exists || doc.data() == null) return null;
    return Profile.fromJson({'id': doc.id, ...doc.data()!});
  }

  Future<bool> isUsernameTaken(String username) async {
    final doc = await _d
        .collection('usernames')
        .doc(username.toLowerCase())
        .get();
    return doc.exists;
  }

  Future<Profile> createProfile({
    required String username,
    required String displayName,
  }) async {
    final userId = _requireUserId(_a);
    final lower = username.toLowerCase();
    final name = displayName.isEmpty ? lower : displayName;
    final profile = Profile(
      id: userId,
      username: lower,
      displayName: name,
    );
    final batch = _d.batch();
    batch.set(_d.collection('users').doc(userId), profile.toMap());
    batch.set(_d.collection('usernames').doc(lower), {
      'username': lower,
      'ownerUid': userId,
      'createdAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
    return profile;
  }

  Future<Profile> updateProfile({
    required String displayName,
    required String bio,
  }) async {
    final userId = _requireUserId(_a);
    await _d.collection('users').doc(userId).update({
      'displayName': displayName,
      'bio': bio,
    });
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
    final userId = _requireUserId(_a);
    final profile = await fetchProfile(userId);
    if (profile == null) return;
    await _d.collection('users').doc(userId).update({
      'xp': (profile.xp + xpDelta).clamp(0, 100000000),
      'currentStreak': currentStreak,
      'longestStreak': longestStreak,
      'lastActiveDate': lastActiveDate,
    });
  }

  Future<List<LeaderboardEntry>> fetchGlobalLeaderboard({
    int limit = 50,
  }) async {
    final snap = await _d
        .collection('users')
        .orderBy('xp', descending: true)
        .limit(limit)
        .get();
    final profiles = snap.docs
        .map((doc) => Profile.fromJson({'id': doc.id, ...doc.data()}))
        .toList();
    return [
      for (var i = 0; i < profiles.length; i++)
        LeaderboardEntry(profile: profiles[i], rank: i + 1),
    ];
  }

  Future<List<LeaderboardEntry>> fetchFriendsLeaderboard() async {
    final userId = _requireUserId(_a);
    final social = SocialRepository(auth: _auth, db: _db);
    final following = await social.followingIds();
    final ids = {...following, userId}.toList();
    final profiles = <Profile>[];
    // whereIn caps at 30 ids — fetch in chunks for big friend lists.
    for (var start = 0; start < ids.length; start += 30) {
      final chunk = ids.sublist(
        start,
        (start + 30).clamp(0, ids.length),
      );
      final snap = await _d
          .collection('users')
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      profiles.addAll(
        snap.docs.map(
          (doc) => Profile.fromJson({'id': doc.id, ...doc.data()}),
        ),
      );
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
    final snap = await _d
        .collection('users')
        .where('xp', isGreaterThan: me.xp)
        .count()
        .get();
    return (snap.count ?? 0) + 1;
  }

  Future<List<Profile>> searchProfiles(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    // Username prefix search. Firestore has no LIKE/ILIKE, so only
    // username prefixes match (display names are not searched — see
    // FIREBASE.md). Usernames are stored lowercase.
    final end = '$q\uf8ff';
    final snap = await _d
        .collection('users')
        .where('username', isGreaterThanOrEqualTo: q)
        .where('username', isLessThan: end)
        .orderBy('username')
        .limit(20)
        .get();
    return snap.docs
        .map((doc) => Profile.fromJson({'id': doc.id, ...doc.data()}))
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

String _logDocId(String habitId, String date) => '${habitId}_$date';

class HabitRepository {
  HabitRepository({this._auth, this._db});

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _db;

  FirebaseAuth get _a => _requireAuth(_auth);
  FirebaseFirestore get _d => _requireDb(_db);

  Future<List<Habit>> listMyHabits() async {
    final userId = _requireUserId(_a);
    final snap = await _d
        .collection('habits')
        .where('ownerUid', isEqualTo: userId)
        .where('archived', isEqualTo: false)
        .orderBy('createdAt')
        .get();
    return snap.docs
        .map((doc) => Habit.fromJson({'id': doc.id, ...doc.data()}))
        .toList();
  }

  Future<Habit> addHabit({
    required String title,
    required int color,
  }) async {
    final userId = _requireUserId(_a);
    final ref = _d.collection('habits').doc();
    await ref.set({
      'ownerUid': userId,
      'title': title,
      'color': color,
      'archived': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
    return Habit(id: ref.id, userId: userId, title: title, color: color);
  }

  Future<void> updateHabit(Habit habit, {String? title, int? color}) async {
    final updates = <String, Object>{};
    if (title != null) updates['title'] = title;
    if (color != null) updates['color'] = color;
    if (updates.isEmpty) return;
    await _d.collection('habits').doc(habit.id).update(updates);
  }

  Future<void> archiveHabit(String habitId) async {
    await _d.collection('habits').doc(habitId).update({'archived': true});
  }

  Future<List<HabitLog>> listLogsForDate(String date) async {
    final userId = _requireUserId(_a);
    final snap = await _d
        .collection('habit_logs')
        .where('ownerUid', isEqualTo: userId)
        .where('date', isEqualTo: date)
        .where('completed', isEqualTo: true)
        .get();
    return snap.docs
        .map((doc) => HabitLog.fromJson({'id': doc.id, ...doc.data()}))
        .toList();
  }

  Future<List<HabitLog>> listLogsInRange(String start, String end) async {
    final userId = _requireUserId(_a);
    final snap = await _d
        .collection('habit_logs')
        .where('ownerUid', isEqualTo: userId)
        .where('completed', isEqualTo: true)
        .where('date', isGreaterThanOrEqualTo: start)
        .where('date', isLessThanOrEqualTo: end)
        .orderBy('date')
        .get();
    return snap.docs
        .map((doc) => HabitLog.fromJson({'id': doc.id, ...doc.data()}))
        .toList();
  }

  /// Distinct dates (newest first) with at least one completed habit.
  Future<List<String>> activeDates({int limit = 370}) async {
    final userId = _requireUserId(_a);
    final snap = await _d
        .collection('habit_logs')
        .where('ownerUid', isEqualTo: userId)
        .where('completed', isEqualTo: true)
        .orderBy('date', descending: true)
        .limit(limit)
        .get();
    final dates = <String>{};
    for (final doc in snap.docs) {
      final date = doc.data()['date'] as String?;
      if (date != null) dates.add(date);
    }
    return dates.toList();
  }

  Future<bool> dailyBonusGranted(String date) async {
    final userId = _requireUserId(_a);
    final doc = await _d
        .collection('daily_rewards')
        .doc('${userId}_$date')
        .get();
    return doc.exists;
  }

  /// Tick or untick a habit for [date]. Handles XP, streak and the
  /// all-done bonus. Returns what changed.
  Future<ToggleResult> toggleHabit({
    required Habit habit,
    required String date,
    required bool completed,
  }) async {
    final profiles = ProfileRepository(auth: _auth, db: _db);
    final me = await profiles.fetchMyProfile();
    if (me == null) throw const AuthException('Profile not found.');
    final userId = _requireUserId(_a);
    final today = todayKey();
    final logRef = _d
        .collection('habit_logs')
        .doc(_logDocId(habit.id, date));

    final existing = await logRef.get();
    final alreadyDone =
        existing.exists &&
        (existing.data()?['completed'] as bool? ?? false);

    var xpDelta = 0;
    var bonusGranted = false;

    if (completed && !alreadyDone) {
      await logRef.set({
        'ownerUid': userId,
        'habitId': habit.id,
        'date': date,
        'completed': true,
        'xpEarned': xpPerHabit,
        'createdAt': FieldValue.serverTimestamp(),
      });
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
      final batch = _d.batch();
      if (allDone && date == today && !await dailyBonusGranted(date)) {
        batch.set(_d.collection('daily_rewards').doc('${userId}_$date'), {
          'ownerUid': userId,
          'date': date,
          'xp': xpDailyCompleteBonus,
          'kind': 'daily_complete',
          'createdAt': FieldValue.serverTimestamp(),
        });
        xpDelta += xpDailyCompleteBonus;
        bonusGranted = true;
      }
      batch.update(_d.collection('users').doc(userId), {
        'xp': (me.xp + xpDelta).clamp(0, 100000000),
        'currentStreak': newStreak,
        'longestStreak': longest,
        'lastActiveDate': date,
      });
      await batch.commit();
      return ToggleResult(
        xpDelta: xpDelta,
        bonusGranted: bonusGranted,
        allDone: allDone,
      );
    }

    if (!completed && alreadyDone) {
      await logRef.delete();
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
  TaskRepository({this._auth, this._db});

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _db;

  FirebaseAuth get _a => _requireAuth(_auth);
  FirebaseFirestore get _d => _requireDb(_db);

  Future<List<WeeklyTask>> listWeeklyTasks(String weekStart) async {
    final userId = _requireUserId(_a);
    final snap = await _d
        .collection('weekly_tasks')
        .where('ownerUid', isEqualTo: userId)
        .where('weekStart', isEqualTo: weekStart)
        .orderBy('createdAt')
        .get();
    return snap.docs
        .map((doc) => WeeklyTask.fromJson({'id': doc.id, ...doc.data()}))
        .toList();
  }

  Future<void> addWeeklyTask(String title, String weekStart) async {
    final userId = _requireUserId(_a);
    await _d.collection('weekly_tasks').add({
      'ownerUid': userId,
      'title': title,
      'weekStart': weekStart,
      'done': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> toggleWeeklyTask(String id, bool done) async {
    await _d.collection('weekly_tasks').doc(id).update({'done': done});
  }

  Future<void> deleteWeeklyTask(String id) async {
    await _d.collection('weekly_tasks').doc(id).delete();
  }

  Future<List<MonthlyTask>> listMonthlyTasks(String month) async {
    final userId = _requireUserId(_a);
    final snap = await _d
        .collection('monthly_tasks')
        .where('ownerUid', isEqualTo: userId)
        .where('month', isEqualTo: month)
        .orderBy('createdAt')
        .get();
    return snap.docs
        .map((doc) => MonthlyTask.fromJson({'id': doc.id, ...doc.data()}))
        .toList();
  }

  Future<void> addMonthlyTask(String title, String month) async {
    final userId = _requireUserId(_a);
    await _d.collection('monthly_tasks').add({
      'ownerUid': userId,
      'title': title,
      'month': month,
      'done': false,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> toggleMonthlyTask(String id, bool done) async {
    await _d.collection('monthly_tasks').doc(id).update({'done': done});
  }

  Future<void> deleteMonthlyTask(String id) async {
    await _d.collection('monthly_tasks').doc(id).delete();
  }
}

// ---------------------------------------------------------------------------
// Social: follows, followers
// ---------------------------------------------------------------------------

class SocialRepository {
  SocialRepository({this._auth, this._db});

  final FirebaseAuth? _auth;
  final FirebaseFirestore? _db;

  FirebaseAuth get _a => _requireAuth(_auth);
  FirebaseFirestore get _d => _requireDb(_db);

  String _followDocId(String followerId, String followingId) =>
      '${followerId}_$followingId';

  Future<void> follow(String followingId) async {
    final userId = _requireUserId(_a);
    await _d
        .collection('follows')
        .doc(_followDocId(userId, followingId))
        .set({
          'followerUid': userId,
          'followingUid': followingId,
          'createdAt': FieldValue.serverTimestamp(),
        });
  }

  Future<void> unfollow(String followingId) async {
    final userId = _requireUserId(_a);
    await _d
        .collection('follows')
        .doc(_followDocId(userId, followingId))
        .delete();
  }

  Future<bool> isFollowing(String followingId) async {
    final userId = _requireUserId(_a);
    final doc = await _d
        .collection('follows')
        .doc(_followDocId(userId, followingId))
        .get();
    return doc.exists;
  }

  Future<List<String>> followingIds() async {
    final userId = _requireUserId(_a);
    final snap = await _d
        .collection('follows')
        .where('followerUid', isEqualTo: userId)
        .get();
    return snap.docs
        .map((doc) => doc.data()['followingUid'] as String)
        .toList();
  }

  Future<int> followingCount(String userId) async {
    final snap = await _d
        .collection('follows')
        .where('followerUid', isEqualTo: userId)
        .count()
        .get();
    return snap.count ?? 0;
  }

  Future<int> followersCount(String userId) async {
    final snap = await _d
        .collection('follows')
        .where('followingUid', isEqualTo: userId)
        .count()
        .get();
    return snap.count ?? 0;
  }
}
