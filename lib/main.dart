import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'data/appwrite_service.dart';
import 'data/repositories.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_screen.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/search_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppwriteService.init();
  runApp(const LifeGameApp());
}

class LifeGameApp extends StatelessWidget {
  const LifeGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Life Game — Habit Tracker',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
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
  String? _recoveryUserId;
  String? _recoverySecret;

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
      final repo = widget.authRepo ?? AuthRepository();
      _authSub = repo.onAuthStateChange.listen((change) {
        if (change.event == AuthEvent.signedOut) {
          setState(() {
            _recoveryUserId = null;
            _recoverySecret = null;
          });
        }
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
    final repo = widget.authRepo ?? AuthRepository();
    return StreamBuilder<AuthChange>(
      stream: repo.onAuthStateChange,
      builder: (context, snapshot) {
        final user = repo.currentUser;
        if (user == null) {
          return AuthScreen(authRepo: widget.authRepo);
        }
        final profileRepo = widget.profileRepo ?? ProfileRepository();
        return FutureBuilder(
          future: profileRepo.fetchMyProfile(),
          builder: (context, profileSnapshot) {
            if (profileSnapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
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
              child: IndexedStack(index: _index, children: _screens),
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
                          Icons.sports_esports,
                          color: AppTheme.violet,
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
                  child: IndexedStack(index: _index, children: _screens),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
