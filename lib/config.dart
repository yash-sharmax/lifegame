/// Supabase configuration.
///
/// The real Supabase URL + anon key are passed at build time with
/// `--dart-define SUPABASE_URL=... --dart-define SUPABASE_ANON_KEY=...`.
/// Until they are provided, the app runs in "unconfigured" mode: it renders
/// the login screen and explains that setup is still pending. No real keys
/// are ever hardcoded here.
class AppConfig {
  static const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://placeholder.supabase.co',
  );
  static const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'placeholder-anon-key',
  );

  static bool get isConfigured =>
      !supabaseUrl.contains('placeholder') &&
      !supabaseAnonKey.contains('placeholder');

  static const googleRedirectUrl = String.fromEnvironment(
    'GOOGLE_REDIRECT_URL',
    defaultValue: '',
  );
}

/// Thrown whenever a feature needs Supabase and no project is configured.
class SupabaseNotConfigured implements Exception {
  @override
  String toString() =>
      'Supabase is not configured yet. Add SUPABASE_URL and '
      'SUPABASE_ANON_KEY with --dart-define and rebuild.';
}
