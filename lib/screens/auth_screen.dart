import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/repositories.dart';
import '../data/supabase_service.dart';
import '../theme.dart';
import '../widgets/common.dart';

void showError(BuildContext context, Object e) {
  final message = e is AuthException
      ? e.message
      : e is SupabaseNotConfigured
          ? e.toString()
          : e.toString();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: Colors.red.shade600),
  );
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message)),
  );
}

enum AuthMode { login, signup, forgot }

/// Login / signup / forgot-password, plus the Google button.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, this.authRepo});

  final AuthRepository? authRepo;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  AuthMode _mode = AuthMode.login;
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  bool _busy = false;
  bool _googleBusy = false;
  bool _obscure = true;

  AuthRepository get _auth => widget.authRepo ?? AuthRepository();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
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
    } on SupabaseNotConfigured catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _google() async {
    setState(() => _googleBusy = true);
    try {
      await _auth.signInWithGoogle();
    } on AuthException catch (e) {
      if (mounted) showError(context, e);
    } on SupabaseNotConfigured catch (e) {
      if (mounted) showError(context, e);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _googleBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF1E1B2E), Color(0xFF4C1D95), Color(0xFF7C3AED)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 16,
              ),
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
                          child: const Icon(
                            Icons.bolt,
                            color: Colors.white,
                            size: 34,
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Text(
                          'Life Game',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ).animate().fadeIn().slideY(begin: -0.2),
                    const SizedBox(height: 8),
                    const Text(
                      'Win your day. Level up your life.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 32),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(28),
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
                            style: const TextStyle(color: AppTheme.inkSoft),
                          ),
                          if (!AppConfig.isConfigured) ...[
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: AppTheme.amber.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'Setup in progress — sign-in will work once '
                                'the Supabase project is connected.',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
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
                                if (!RegExp(
                                  r'^[a-zA-Z0-9_]+$',
                                ).hasMatch(value)) {
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
                                  onPressed: () => setState(
                                    () => _obscure = !_obscure,
                                  ),
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility
                                        : Icons.visibility_off,
                                  ),
                                ),
                              ),
                              validator: (v) => (v ?? '').length >= 6
                                  ? null
                                  : 'At least 6 characters',
                            ),
                          if (_mode != AuthMode.forgot) const SizedBox(height: 8),
                          if (_mode == AuthMode.login)
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: () => setState(
                                  () => _mode = AuthMode.forgot,
                                ),
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
                          if (_mode != AuthMode.forgot) ...[
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                const Expanded(child: Divider()),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  child: Text(
                                    'OR',
                                    style: TextStyle(
                                      color: Colors.grey.shade500,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                                const Expanded(child: Divider()),
                              ],
                            ),
                            const SizedBox(height: 16),
                            GoogleButton(
                              onPressed: _google,
                              loading: _googleBusy,
                            ),
                          ],
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _mode == AuthMode.login
                                    ? "New to Life Game?"
                                    : "Already have an account?",
                                style: const TextStyle(
                                  color: AppTheme.inkSoft,
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
                                onPressed: () => setState(
                                  () => _mode = AuthMode.login,
                                ),
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

  @override
  void initState() {
    super.initState();
    final meta =
        widget.authRepo?.currentUser?.userMetadata ??
        SupabaseService.clientOrNull?.auth.currentUser?.userMetadata;
    if (meta != null) {
      _displayName.text =
          (meta['display_name'] as String?) ??
          (meta['full_name'] as String?) ??
          '';
      if (meta['username'] is String) {
        _username.text = meta['username'] as String;
      }
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
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This is how friends find you and how you appear on the leaderboard.',
                  style: TextStyle(color: AppTheme.inkSoft, fontSize: 15),
                ),
                const SizedBox(height: 28),
                TextFormField(
                  controller: _displayName,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                  ),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'Tell us your name'
                      : null,
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
    );
  }
}

/// Set a new password after clicking a recovery link.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, this.authRepo});

  final AuthRepository? authRepo;

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
      await repo.updatePassword(_password.text);
      if (!mounted) return;
      showInfo(context, 'Password updated. Log in with your new password.');
      await repo.signOut();
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
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
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
                validator: (v) => (v ?? '').length >= 6
                    ? null
                    : 'At least 6 characters',
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                ),
                validator: (v) => v == _password.text
                    ? null
                    : 'Passwords do not match',
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
    );
  }
}
