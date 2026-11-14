import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'data/repositories.dart';
import 'data/supabase_service.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_screen.dart';
import 'screens/leaderboard_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/search_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SupabaseService.init();
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
/// - Supabase not configured yet → login screen (with a setup notice).
/// - No session → login / signup / forgot password.
/// - Session but no profile row → one-time username setup.
/// - Session + profile → the main app shell.
/// Also watches for password-recovery events (reset link clicked) and
/// opens the reset-password screen.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, this.authRepo, this.profileRepo});

  final AuthRepository? authRepo;
  final ProfileRepository? profileRepo;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  StreamSubscription<AuthState>? _authSub;
  bool _recoveryMode = false;

  @override
  void initState() {
    super.initState();
    if (AppConfig.isConfigured) {
      final repo = widget.authRepo ?? AuthRepository();
      _authSub = repo.onAuthStateChange.listen((state) {
        if (state.event == AuthChangeEvent.passwordRecovery) {
          setState(() => _recoveryMode = true);
        } else if (state.event == AuthChangeEvent.signedOut) {
          setState(() => _recoveryMode = false);
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
    if (_recoveryMode) {
      return ResetPasswordScreen(authRepo: widget.authRepo);
    }
    if (!AppConfig.isConfigured) {
      return AuthScreen(authRepo: widget.authRepo);
    }
    final repo = widget.authRepo ?? AuthRepository();
    return StreamBuilder<AuthState>(
      stream: repo.onAuthStateChange,
      builder: (context, snapshot) {
        final session =
            Supabase.instance.client.auth.currentSession;
        if (session == null) {
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
