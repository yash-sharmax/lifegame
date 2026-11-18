/// App configuration: Appwrite project wiring + public URLs.
///
/// The Appwrite project ID is passed at build time with
/// `--dart-define APPWRITE_PROJECT_ID=...` and the region endpoint with
/// `--dart-define APPWRITE_ENDPOINT=...` (database ID defaults to
/// 'lifegame' and can be overridden with APPWRITE_DATABASE_ID).
/// Until a real project ID is provided, the app runs in "unconfigured"
/// mode: it renders the login screen and explains that setup is still
/// pending.
///
/// The endpoint matters: the project lives in the Toronto region, so
/// the endpoint must be https://tor.cloud.appwrite.io/v1 — the generic
/// https://cloud.appwrite.io/v1 will NOT reach it.
///
/// No secrets live here: the endpoint + project ID are public-by-design
/// identifiers (they ship inside the web bundle of every Appwrite app).
/// The API key is used ONLY by the setup script (see APPWRITE.md and
/// scripts/setup_appwrite.mjs) — never in the app, never in the repo.
library;

class AppConfig {
  /// App version (e.g. '2.7.0+13'). Single source of truth for the
  /// in-app About label — bump this together with pubspec.yaml on
  /// every release. (18 Nov 2026: the v2.5.1 About label was a
  /// hard-coded string and was never bumped, so it kept showing the
  /// old version even though the new build was live.)
  static const String appVersion = '2.8.5+19';

  /// Appwrite Cloud endpoint (region-specific for this project).
  static const String endpoint = String.fromEnvironment(
    'APPWRITE_ENDPOINT',
    defaultValue: 'https://tor.cloud.appwrite.io/v1',
  );

  static const String projectId = String.fromEnvironment(
    'APPWRITE_PROJECT_ID',
    defaultValue: 'placeholder-project-id',
  );

  static const String databaseId = String.fromEnvironment(
    'APPWRITE_DATABASE_ID',
    defaultValue: 'lifegame',
  );

  static bool get isConfigured => !projectId.contains('placeholder');

  /// Where Appwrite password-recovery emails must land back in the app.
  /// The app's host must be registered as a Web platform in the Appwrite
  /// console (the setup script does this — see APPWRITE.md).
  static const String resetContinueUrl = 'https://yashx.xyz/lifegame';

  /// Base URL of the app (used as the OAuth2 success/failure redirect).
  static const String appUrl = 'https://yashx.xyz/lifegame';
}

/// Thrown whenever a feature needs Appwrite and no project is configured.
class AppwriteNotConfigured implements Exception {
  @override
  String toString() =>
      'Appwrite is not configured yet. Add the APPWRITE_PROJECT_ID value '
      'with --dart-define and rebuild.';
}
