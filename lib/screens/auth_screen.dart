import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../config.dart';
import '../data/repositories.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Shows an error as a SnackBar. v2.9.0: a NETWORK failure is a small
/// subtle line (short text, the card background — never the big red /
/// flame banner), because offline is a normal state the app handles
/// by working from its local cache. A real (non-network) error keeps
/// the existing red SnackBar.
void showError(BuildContext context, Object e) {
  final message = e is AuthException ? e.message : e.toString();
  if (isNetworkError(e)) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "You're offline — changes will sync when you're back online.",
          style: const TextStyle(fontSize: 13),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: AppTheme.flame),
  );
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

enum AuthMode { login, signup, forgot }

/// Login / signup / forgot-password, plus the Google button.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    this.authRepo,
    this.sessionNotice,
    this.onRetrySessionCheck,
  });

  final AuthRepository? authRepo;

  /// Shown when the stored session could not be checked (e.g. the
  /// network failed) — the user is not actually signed out, the check
  /// just did not complete. Shown as a banner above the form.
  final String? sessionNotice;

  /// Retries the session check; shown as a button in the banner.
  final Future<void> Function()? onRetrySessionCheck;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  AuthMode _mode = AuthMode.login;
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  // Account visibility (v2.9.0): Public by default.
  String _visibility = 'public';

  AuthRepository get _auth => widget.authRepo ?? AuthRepository();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _username.dispose();
    _displayName.dispose();
    super.dispose();
  }

  String get _title => switch (_mode) {
    AuthMode.login => 'Welcome back',
    AuthMode.signup => 'Create your account',
    AuthMode.forgot => 'Reset your password',
  };

  String get _subtitle => switch (_mode) {
    AuthMode.login => 'Log in to keep your streak alive.',
    AuthMode.signup => 'Your game, your rules. Start at level 1.',
    AuthMode.forgot => 'We will email you a reset link.',
  };

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      switch (_mode) {
        case AuthMode.login:
          await _auth.signIn(
            email: _email.text.trim(),
            password: _password.text,
          );
        case AuthMode.signup:
          final username = _username.text.trim().toLowerCase();
          final profiles = ProfileRepository();
          if (await profiles.isUsernameTaken(username)) {
            throw const AuthException(
              'That username is already taken. Try another one.',
            );
          }
          final hasSession = await _auth.signUp(
            email: _email.text.trim(),
            password: _password.text,
            username: username,
            displayName: _displayName.text.trim().isEmpty
                ? username
                : _displayName.text.trim(),
            visibility: _visibility,
          );
          if (!mounted) return;
          if (!hasSession) {
            showInfo(
              context,
              'Account created! Check your email to confirm, then log in.',
            );
            setState(() => _mode = AuthMode.login);
            return;
          }
        case AuthMode.forgot:
          await _auth.sendPasswordReset(_email.text.trim());
          if (!mounted) return;
          showInfo(
            context,
            'Reset link sent. Check your email (and spam folder).',
          );
          setState(() => _mode = AuthMode.login);
          return;
      }
    } on AuthException catch (e) {
      if (mounted) showError(context, e);
    } on AppwriteNotConfigured catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [
              Color(0xFF0E0C13),
              Color(0xFF2A1202),
              Color(0xFF7F1D1D),
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 64,
                            height: 64,
                            decoration: const BoxDecoration(
                              gradient: AppTheme.heroGradient,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.shield,
                              color: AppTheme.ink,
                              size: 34,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'Life Game',
                            style: TextStyle(
                              color: AppTheme.ink,
                              fontSize: 32,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ).animate().fadeIn().slideY(begin: -0.2),
                      const SizedBox(height: 8),
                      Text(
                        'Small steps, every day.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTheme.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 32),
                      Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: AppTheme.card,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: AppTheme.cardBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _title,
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _subtitle,
                              style: TextStyle(color: AppTheme.inkSoft),
                            ),
                            if (!AppConfig.isConfigured) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.gold.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'Setup in progress — sign-in will work once '
                                  'the Appwrite project is connected.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                            if (widget.sessionNotice != null) ...[
                              const SizedBox(height: 16),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.flame.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'Could not check your saved session: '
                                      '${widget.sessionNotice}',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (widget.onRetrySessionCheck != null) ...[
                                      const SizedBox(height: 8),
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: TextButton(
                                          onPressed: () async {
                                            final retry =
                                                widget.onRetrySessionCheck;
                                            if (retry != null) await retry();
                                          },
                                          child: const Text('Retry'),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 20),
                            if (_mode == AuthMode.signup) ...[
                              TextFormField(
                                controller: _displayName,
                                decoration: const InputDecoration(
                                  labelText: 'Display name',
                                  hintText: 'e.g. Yash Sharma',
                                ),
                              ),
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _username,
                                decoration: const InputDecoration(
                                  labelText: 'Username',
                                  hintText: 'unique, e.g. yashsharma',
                                  prefixText: '@',
                                ),
                                validator: (v) {
                                  final value = (v ?? '').trim();
                                  if (value.length < 3) {
                                    return 'Username needs at least 3 characters';
                                  }
                                  if (value.length > 32) {
                                    return 'Username must be at most 32 characters';
                                  }
                                  if (!RegExp(r'^[a-zA-Z0-9_]+$')
                                      .hasMatch(value)) {
                                    return 'Letters, numbers and _ only';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 14),
                            ],
                            TextFormField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                              ),
                              validator: (v) => (v ?? '').contains('@')
                                  ? null
                                  : 'Enter a valid email',
                            ),
                            const SizedBox(height: 14),
                            if (_mode != AuthMode.forgot)
                              TextFormField(
                                controller: _password,
                                obscureText: _obscure,
                                decoration: InputDecoration(
                                  labelText: 'Password',
                                  suffixIcon: IconButton(
                                    onPressed: () =>
                                        setState(() => _obscure = !_obscure),
                                    icon: Icon(
                                      _obscure
                                          ? Icons.visibility
                                          : Icons.visibility_off,
                                    ),
                                  ),
                                ),
                                validator: (v) => (v ?? '').length >= 8
                                    ? null
                                    : 'At least 8 characters',
                              ),
                            if (_mode == AuthMode.signup) ...[
                              const SizedBox(height: 14),
                              TextFormField(
                                controller: _confirmPassword,
                                obscureText: _obscure,
                                decoration: const InputDecoration(
                                  labelText: 'Confirm password',
                                ),
                                validator: (v) => v == _password.text
                                    ? null
                                    : 'Passwords do not match',
                              ),
                              const SizedBox(height: 18),
                              // Account visibility (v2.9.0): who can see
                              // my habits. Public by default.
                              _VisibilitySelector(
                                value: _visibility,
                                onChanged: (v) =>
                                    setState(() => _visibility = v),
                              ),
                            ],
                            if (_mode != AuthMode.forgot)
                              const SizedBox(height: 8),
                            if (_mode == AuthMode.login)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () =>
                                      setState(() => _mode = AuthMode.forgot),
                                  child: const Text('Forgot password?'),
                                ),
                              ),
                            const SizedBox(height: 16),
                            GradientButton(
                              label: switch (_mode) {
                                AuthMode.login => 'Log in',
                                AuthMode.signup => 'Create account',
                                AuthMode.forgot => 'Send reset link',
                              },
                              onPressed: _submit,
                              loading: _busy,
                            ),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    _mode == AuthMode.login
                                        ? "New to Life Game?"
                                        : "Already have an account?",
                                    style: TextStyle(
                                      color: AppTheme.inkSoft,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => setState(
                                    () => _mode = _mode == AuthMode.login
                                        ? AuthMode.signup
                                        : AuthMode.login,
                                  ),
                                  child: Text(
                                    _mode == AuthMode.login
                                        ? 'Create account'
                                        : 'Log in',
                                  ),
                                ),
                              ],
                            ),
                            if (_mode == AuthMode.forgot)
                              Center(
                                child: TextButton(
                                  onPressed: () =>
                                      setState(() => _mode = AuthMode.login),
                                  child: const Text('Back to log in'),
                                ),
                              ),
                          ],
                        ),
                      ).animate().fadeIn(delay: 120.ms).slideY(begin: 0.15),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The Public / Private account choice (v2.9.0), shared by signup
/// and the one-time username setup: two options, each with a one-line
/// explanation. Public is the default.
class _VisibilitySelector extends StatelessWidget {
  const _VisibilitySelector({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Who can see your habits?',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        const SizedBox(height: 8),
        _VisibilityOption(
          title: 'Public',
          subtitle: 'Anyone can see your habits',
          selected: value == 'public',
          onTap: () => onChanged('public'),
        ),
        const SizedBox(height: 8),
        _VisibilityOption(
          title: 'Private',
          subtitle: 'Only mutual friends can see your habits',
          selected: value == 'private',
          onTap: () => onChanged('private'),
        ),
      ],
    );
  }
}

class _VisibilityOption extends StatelessWidget {
  const _VisibilityOption({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppTheme.ember.withValues(alpha: 0.12)
          : AppTheme.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? AppTheme.ember : AppTheme.cardBorder,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppTheme.inkSoft,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle, color: AppTheme.ember),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown after sign-in when the user has no profile row yet
/// (e.g. signed up with Google, or email confirmation finished).
/// Collects the unique username once.
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key, this.profileRepo, this.authRepo});

  final ProfileRepository? profileRepo;
  final AuthRepository? authRepo;

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  bool _busy = false;
  // Account visibility (v2.9.0): Public by default.
  String _visibility = 'public';

  @override
  void initState() {
    super.initState();
    // Prefill the display name from the auth account (e.g. the name on
    // the Google account used to sign in).
    final displayName = widget.authRepo?.currentUser?.displayName;
    if (displayName != null) {
      _displayName.text = displayName;
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final repo = widget.profileRepo ?? ProfileRepository();
      final username = _username.text.trim().toLowerCase();
      if (await repo.isUsernameTaken(username)) {
        throw const AuthException('That username is already taken.');
      }
      await repo.createProfile(
        username: username,
        displayName: _displayName.text.trim().isEmpty
            ? username
            : _displayName.text.trim(),
        visibility: _visibility,
      );
    } on AuthException catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 32),
                    const Text(
                      'Pick your username',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'This is how friends find you and how you appear on the leaderboard.',
                      style: TextStyle(color: AppTheme.inkSoft, fontSize: 15),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _displayName,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Tell us your name' : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _username,
                      decoration: const InputDecoration(
                        labelText: 'Username',
                        prefixText: '@',
                      ),
                      validator: (v) {
                        final value = (v ?? '').trim();
                        if (value.length < 3) return 'At least 3 characters';
                        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(value)) {
                          return 'Letters, numbers and _ only';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),
                    _VisibilitySelector(
                      value: _visibility,
                      onChanged: (v) => setState(() => _visibility = v),
                    ),
                    const SizedBox(height: 24),
                    GradientButton(
                      label: 'Start playing',
                      onPressed: _save,
                      loading: _busy,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Set a new password after clicking a recovery link.
///
/// [recoveryUserId] and [recoverySecret] come from the Appwrite reset
/// link (?userId=...&secret=...). When they are present, the new password
/// is set with `updateRecovery`; without them (signed-in user changing
/// their password) `updatePassword` is used instead.
/// [onResetDone] runs after a successful reset so the auth gate can return
/// to the login screen.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({
    super.key,
    this.authRepo,
    this.recoveryUserId,
    this.recoverySecret,
    this.onResetDone,
  });

  final AuthRepository? authRepo;
  final String? recoveryUserId;
  final String? recoverySecret;
  final VoidCallback? onResetDone;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final repo = widget.authRepo ?? AuthRepository();
      if (widget.recoveryUserId != null && widget.recoverySecret != null) {
        await repo.confirmPasswordReset(
          userId: widget.recoveryUserId!,
          secret: widget.recoverySecret!,
          newPassword: _password.text,
        );
      } else {
        await repo.updatePassword(_password.text);
        await repo.signOut();
      }
      if (!mounted) return;
      showInfo(context, 'Password updated. Log in with your new password.');
      widget.onResetDone?.call();
    } on AuthException catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Choose a new password for your Life Game account.',
                    style: TextStyle(color: AppTheme.inkSoft, fontSize: 15),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'New password',
                    ),
                    validator: (v) =>
                        (v ?? '').length >= 8 ? null : 'At least 8 characters',
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Confirm new password',
                    ),
                    validator: (v) =>
                        v == _password.text ? null : 'Passwords do not match',
                  ),
                  const SizedBox(height: 24),
                  GradientButton(
                    label: 'Update password',
                    onPressed: _save,
                    loading: _busy,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
