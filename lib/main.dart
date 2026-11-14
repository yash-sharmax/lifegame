import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'data/firebase_service.dart';
import 'data/repositories.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_screen.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/search_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseService.init();
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
/// - Firebase not configured yet → login screen (with a setup notice).
/// - Password-reset link opened (?mode=resetPassword&oobCode=...) →
///   reset-password screen.
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
  String? _resetCode;

  @override
  void initState() {
    super.initState();
    // Firebase password-reset links land on the app URL with
    // ?mode=resetPassword&oobCode=<code>. Detect it via Uri.base.
    try {
      final params = Uri.base.queryParameters;
      if (params['mode'] == 'resetPassword' &&
          (params['oobCode'] ?? '').isNotEmpty) {
        _resetCode = params['oobCode'];
      }
    } catch (_) {
      // Uri.base is unavailable in some environments — ignore.
    }
    if (AppConfig.isConfigured) {
      final repo = widget.authRepo ?? AuthRepository();
      _authSub = repo.onAuthStateChange.listen((change) {
        if (change.event == AuthEvent.signedOut) {
          setState(() => _resetCode = null);
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
    if (_resetCode != null) {
      return ResetPasswordScreen(
        authRepo: widget.authRepo,
        resetCode: _resetCode,
        onResetDone: () => setState(() => _resetCode = null),
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
            if (profileSnapshot.connectionState ==
                ConnectionState.waiting) {
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
}
