import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'data/appwrite_service.dart';
import 'data/reminder_service.dart';
import 'data/repositories.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_screen.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/schedule_screen.dart';
import 'screens/search_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppwriteService.init();
  // Reminders start ticking before the first frame: the in-app banner
  // and (on Android) the exact alarms must not wait for a screen.
  await ReminderService.instance.init();
  runApp(const LifeGameApp());
}

class LifeGameApp extends StatelessWidget {
  const LifeGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Life Game — Habit Tracker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const AuthGate(),
    );
  }
}

/// Decides what the user sees:
/// - Appwrite not configured yet → login screen (with a setup notice).
/// - Password-reset link opened (?userId=...&secret=...) → reset-password
///   screen.
/// - No session → login / signup / forgot password.
/// - Session but no profile row → one-time username setup.
/// - Session + profile → the main app shell.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.authRepo, this.profileRepo});

  final AuthRepository? authRepo;
  final ProfileRepository? profileRepo;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthChange>? _authSub;
  // The latest auth state. Null while the stored session is still
  // being checked — the gate shows a loader then, NOT the login screen.
  // Showing login before the check finishes is what made a reload look
  // like a logout (14 Nov 2026): the first stream yielded "signed out"
  // while the real check was still waiting on the network.
  AuthChange? _authChange;
  String? _recoveryUserId;
  String? _recoverySecret;

  AuthRepository get _auth => widget.authRepo ?? AuthRepository();

  @override
  void initState() {
    super.initState();
    // Appwrite password-reset links land on the app URL with
    // ?userId=<id>&secret=<secret>. Detect it via Uri.base.
    try {
      final params = Uri.base.queryParameters;
      final userId = params['userId'];
      final secret = params['secret'];
      if ((userId ?? '').isNotEmpty && (secret ?? '').isNotEmpty) {
        _recoveryUserId = userId;
        _recoverySecret = secret;
      }
    } catch (_) {
      // Uri.base is unavailable in some environments — ignore.
    }
    if (AppConfig.isConfigured) {
      // Subscribe ONCE: the stream's first event only arrives after
      // the stored session has been checked, so it is authoritative.
      // (Creating a fresh stream on every build raced the check and
      // yielded a stale "signed out".)
      _authSub = _auth.onAuthStateChange.listen((change) {
        if (!mounted) return;
        setState(() {
          _authChange = change;
          if (change.event == AuthEvent.signedOut) {
            _recoveryUserId = null;
            _recoverySecret = null;
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_recoveryUserId != null && _recoverySecret != null) {
      return ResetPasswordScreen(
        authRepo: widget.authRepo,
        recoveryUserId: _recoveryUserId,
        recoverySecret: _recoverySecret,
        onResetDone: () => setState(() {
          _recoveryUserId = null;
          _recoverySecret = null;
        }),
      );
    }
    if (!AppConfig.isConfigured) {
      return AuthScreen(authRepo: widget.authRepo);
    }
    final change = _authChange;
    if (change == null) {
      // Stored session is still being checked — wait, don't flash the
      // login screen. A branded splash, not a bare spinner.
      return const WarriorSplash(message: 'Checking your session…');
    }
    if (change.event == AuthEvent.signedOut) {
      // A real auth failure while checking the session (e.g. network)
      // is shown on the login screen with a retry, instead of silently
      // dropping the user there as if they had never signed in.
      final sessionError = AuthRepository.sessionError;
      return AuthScreen(
        authRepo: widget.authRepo,
        sessionNotice: sessionError,
        onRetrySessionCheck: sessionError == null
            ? null
            : () async {
                await _auth.ensureSession();
                if (mounted) setState(() {});
              },
      );
    }
    final profileRepo = widget.profileRepo ?? ProfileRepository();
    return FutureBuilder(
      future: profileRepo.fetchMyProfile(),
      builder: (context, profileSnapshot) {
        if (profileSnapshot.connectionState == ConnectionState.waiting) {
          return const WarriorSplash(message: 'Loading your war room…');
        }
        if (profileSnapshot.data == null) {
          return ProfileSetupScreen(
            profileRepo: widget.profileRepo,
            authRepo: widget.authRepo,
          );
        }
        return const MainShell();
      },
    );
  }
}

/// Bottom-navigation shell: Home, Dashboard, Leaderboard, Search, Profile.
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  // The latest due reminder (in-app banner). Cleared when dismissed
  // or when the user opens the Schedule screen from it.
  ReminderAlert? _alert;
  StreamSubscription<ReminderAlert>? _alertSub;

  @override
  void initState() {
    super.initState();
    _alertSub = ReminderService.instance.alerts.listen((alert) {
      if (mounted) setState(() => _alert = alert);
    });
    // The service started in main() before any session existed; now
    // that the user is signed in, re-check due reminders and
    // re-schedule the Android alarms for this account.
    unawaited(ReminderService.instance.refresh());
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }

  void _openSchedule() {
    setState(() => _alert = null);
    Navigator.of(context).push(
      WarriorPageRoute(builder: (_) => const ScheduleScreen()),
    );
  }

  Widget _reminderBanner() {
    final alert = _alert;
    if (alert == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openSchedule,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              gradient: AppTheme.heroGradient,
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            child: Row(
              children: [
                const Icon(Icons.alarm, color: AppTheme.ink, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reminder',
                        style: TextStyle(
                          color: AppTheme.ink.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Time for ${alert.reminder.title}',
                        style: const TextStyle(
                          color: AppTheme.ink,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _openSchedule,
                  child: const Text(
                    'View',
                    style: TextStyle(color: AppTheme.ink),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _alert = null),
                  icon: const Icon(Icons.close, color: AppTheme.ink, size: 20),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static const List<Widget> _screens = [
    HomeScreen(),
    DashboardScreen(),
    LeaderboardScreen(),
    SearchScreen(),
    ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // Phones (<600px) keep the familiar bottom-navigation app layout.
    // Computers get a side navigation rail and the screens' own wider,
    // centred layouts — the app uses the desktop screen instead of
    // sitting in a narrow phone-width column.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < kDesktopBreakpoint) {
          return Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  _reminderBanner(),
                  Expanded(
                    child: IndexedStack(index: _index, children: _screens),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.home_outlined),
                  selectedIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: 'Dashboard',
                ),
                NavigationDestination(
                  icon: Icon(Icons.leaderboard_outlined),
                  selectedIcon: Icon(Icons.leaderboard),
                  label: 'Leaderboard',
                ),
                NavigationDestination(
                  icon: Icon(Icons.search_outlined),
                  selectedIcon: Icon(Icons.search),
                  label: 'Search',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outlined),
                  selectedIcon: Icon(Icons.person),
                  label: 'Profile',
                ),
              ],
            ),
          );
        }
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (i) => setState(() => _index = i),
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Column(
                      children: [
                        Icon(
                          Icons.shield,
                          color: AppTheme.ember,
                          size: 30,
                        ),
                        SizedBox(height: 6),
                        Text(
                          'Life Game',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.home_outlined),
                      selectedIcon: Icon(Icons.home),
                      label: Text('Home'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.dashboard_outlined),
                      selectedIcon: Icon(Icons.dashboard),
                      label: Text('Dashboard'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.leaderboard_outlined),
                      selectedIcon: Icon(Icons.leaderboard),
                      label: Text('Leaderboard'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.search_outlined),
                      selectedIcon: Icon(Icons.search),
                      label: Text('Search'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.person_outlined),
                      selectedIcon: Icon(Icons.person),
                      label: Text('Profile'),
                    ),
                  ],
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(
                  child: Column(
                    children: [
                      _reminderBanner(),
                      Expanded(
                        child: IndexedStack(index: _index, children: _screens),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
