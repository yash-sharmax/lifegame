import 'dart:async';

import 'package:flutter/material.dart';

import 'config.dart';
import 'data/appwrite_service.dart';
import 'data/reminder_service.dart';
import 'data/repositories.dart';
import 'data/sync_service.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/home_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/reminders_screen.dart';
import 'screens/schedule_screen.dart';
import 'theme.dart';
import 'widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppwriteService.init();
  // The saved dark / light choice (v2.9.0) before the first frame.
  await ThemeController.instance.load();
  // Reminders start ticking before the first frame: the in-app banner
  // and (on Android) the exact alarms must not wait for a screen.
  await ReminderService.instance.init();
  // Offline-first (v2.9.0): the connectivity listener + the first
  // background sync. The outbox replays silently when the network is
  // there; when it is not, the app simply runs on its local cache.
  await SyncService.instance.init();
  unawaited(SyncService.instance.syncNow());
  runApp(const LifeGameApp());
}

class LifeGameApp extends StatelessWidget {
  const LifeGameApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Rebuilds the MaterialApp when the theme switch changes
    // (v2.9.0 dark / light).
    return AnimatedBuilder(
      animation: ThemeController.instance,
      builder: (context, _) => MaterialApp(
        title: 'Life Game — Habit Tracker',
        debugShowCheckedModeBanner: false,
        theme: ThemeController.instance.isLight
            ? AppTheme.light
            : AppTheme.dark,
        home: const AuthGate(),
      ),
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
          return const WarriorSplash(message: 'Loading…');
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

/// Bottom-navigation shell: Home, Dashboard, Reminders, Profile
/// (4 tabs, v2.9.0). Leaderboard and Search are NOT tabs any more — the
/// leaderboard opens by tapping the XP pill on Home, and Search opens
/// from the search icon in the top header of each screen.
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

  // The latest due CHAT reminder (v2.9.0, Reminders tab). Cleared
  // when dismissed or when the user opens the Reminders tab from it.
  ChatReminderAlert? _chatAlert;
  StreamSubscription<ChatReminderAlert>? _chatAlertSub;

  // Offline (v2.9.0): the small "you're offline" line. Starts with
  // the sync service's current state.
  bool _online = true;
  StreamSubscription<bool>? _onlineSub;

  @override
  void initState() {
    super.initState();
    _online = SyncService.instance.isOnline;
    _alertSub = ReminderService.instance.alerts.listen((alert) {
      if (mounted) setState(() => _alert = alert);
    });
    _chatAlertSub = ReminderService.instance.chatAlerts.listen((alert) {
      if (mounted) setState(() => _chatAlert = alert);
    });
    _onlineSub = SyncService.instance.online.listen((online) {
      if (mounted) setState(() => _online = online);
    });
    // The service started in main() before any session existed; now
    // that the user is signed in, re-check due reminders and
    // re-schedule the Android alarms for this account.
    unawaited(ReminderService.instance.refresh());
    // Heal any drift between the stored XP and the derived value
    // (2 XP per actually-completed habit/task) — once per session,
    // in the background; screens reload through the profile stream.
    unawaited(ProfileRepository().syncDerivedXpOnce());
    // Push any changes made while offline (v2.9.0).
    unawaited(SyncService.instance.syncNow());
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _chatAlertSub?.cancel();
    _onlineSub?.cancel();
    super.dispose();
  }

  void _openSchedule() {
    setState(() => _alert = null);
    Navigator.of(context).push(
      WarriorPageRoute(builder: (_) => const ScheduleScreen()),
    );
  }

  void _openReminders() {
    setState(() {
      _chatAlert = null;
      _index = 2;
    });
  }

  /// The small offline line (v2.9.0): a single subtle row, never a
  /// big error popup. It is the only place the app mentions the
  /// network — everything else just works from the local cache.
  Widget _offlineBanner() {
    if (_online) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      color: AppTheme.card,
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 15, color: AppTheme.inkSoft),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "You're offline — changes will sync when you're back online",
              style: TextStyle(color: AppTheme.inkSoft, fontSize: 12),
            ),
          ),
        ],
      ),
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
                // On the violet gradient — always white.
                Icon(Icons.alarm, color: AppTheme.onAccent, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reminder',
                        style: TextStyle(
                          color: AppTheme.onAccent.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Time for ${alert.reminder.title}',
                        style: TextStyle(
                          color: AppTheme.onAccent,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _openSchedule,
                  child: Text(
                    'View',
                    style: TextStyle(color: AppTheme.onAccent),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _alert = null),
                  icon: Icon(Icons.close, color: AppTheme.onAccent, size: 20),
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

  /// The chat-reminder banner (v2.9.0): "Reminder — [text] is due".
  /// Tapping it opens the Reminders tab.
  Widget _chatReminderBanner() {
    final alert = _chatAlert;
    if (alert == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openReminders,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              gradient: AppTheme.heroGradient,
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            child: Row(
              children: [
                // On the violet gradient — always white.
                Icon(
                  Icons.notifications_active,
                  color: AppTheme.onAccent,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reminder',
                        style: TextStyle(
                          color: AppTheme.onAccent.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${alert.reminder.text} is due',
                        style: TextStyle(
                          color: AppTheme.onAccent,
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _chatAlert = null),
                  icon: Icon(Icons.close, color: AppTheme.onAccent, size: 20),
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
    RemindersScreen(),
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
                  _offlineBanner(),
                  _reminderBanner(),
                  _chatReminderBanner(),
                  Expanded(
                    child: IndexedStack(index: _index, children: _screens),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: _CompactBottomNav(
              index: _index,
              onTap: (i) => setState(() => _index = i),
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
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      children: [
                        Icon(
                          Icons.shield,
                          color: AppTheme.ember,
                          size: 26,
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
                      icon: Icon(Icons.chat_bubble_outline),
                      selectedIcon: Icon(Icons.chat_bubble),
                      label: Text('Reminders'),
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
                      _offlineBanner(),
                      _reminderBanner(),
                      _chatReminderBanner(),
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

/// Compact bottom nav (v2.6.0, 18 Nov 2026): ~58px tall instead of
/// the stock NavigationBar, with a CLEAR animated active state — the
/// selected tab gets a violet pill that fades/slides in (200ms) and
/// its icon scales up, so it is obvious which tab you are on.
/// The unselected tabs show an icon only; the selected tab shows its
/// label too, inside the pill.
class _CompactBottomNav extends StatelessWidget {
  const _CompactBottomNav({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  static const List<({IconData icon, IconData selectedIcon, String label})>
  _items = [
    (icon: Icons.home_outlined, selectedIcon: Icons.home, label: 'Home'),
    (
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
      label: 'Dashboard',
    ),
    (
      icon: Icons.chat_bubble_outline,
      selectedIcon: Icons.chat_bubble,
      label: 'Reminders',
    ),
    (
      icon: Icons.person_outlined,
      selectedIcon: Icons.person,
      label: 'Profile',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          color: AppTheme.card,
          border: Border(top: BorderSide(color: AppTheme.cardBorder)),
        ),
        child: Row(
          children: [
            for (var i = 0; i < _items.length; i++)
              Expanded(
                child: _NavItem(
                  icon: _items[i].icon,
                  selectedIcon: _items[i].selectedIcon,
                  label: _items[i].label,
                  selected: index == i,
                  onTap: () => onTap(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppTheme.ember : AppTheme.inkSoft;
    // Icon over label (stacked): the horizontal icon+label pill
    // overflowed its third of the bar on a 390px phone — "Dashboard"
    // is too wide side-by-side with the icon. Stacked, the pill is
    // only as wide as the label, and the bar stays compact.
    return InkWell(
      onTap: onTap,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          // Tight horizontal padding (v2.9.0): with four tabs each
          // tab is ~97px on a 390px phone, and the 9-letter labels
          // ("Dashboard", "Reminders") wrapped to two lines and
          // overflowed the 58px bar by 8px at padding 14.
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.ember.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: selected ? 1.1 : 1.0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Icon(
                  selected ? selectedIcon : icon,
                  color: color,
                  size: 21,
                ),
              ),
              if (selected) ...[
                const SizedBox(height: 2),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
