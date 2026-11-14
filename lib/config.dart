/// App configuration: Firebase project wiring + public URLs.
///
/// The Firebase web config lives in [DefaultFirebaseOptions] and is passed
/// at build time with `--dart-define FIREBASE_*=...` (see that file).
/// Until it is provided, the app runs in "unconfigured" mode: it renders
/// the login screen and explains that setup is still pending.
library;

import 'firebase_options.dart';

class AppConfig {
  static bool get isConfigured => DefaultFirebaseOptions.isConfigured;

  /// reCAPTCHA v3 site key for Firebase App Check (web).
  /// Empty until the key is created in Google Cloud / reCAPTCHA admin and
  /// passed with `--dart-define FIREBASE_RECAPTCHA_SITE_KEY=...`.
  /// App Check is switched on only when this is non-empty; enforcement
  /// must also be turned on in the Firebase console (see FIREBASE.md).
  static const recaptchaSiteKey = String.fromEnvironment(
    'FIREBASE_RECAPTCHA_SITE_KEY',
    defaultValue: '',
  );

  static bool get appCheckConfigured => recaptchaSiteKey.isNotEmpty;

  /// Where Firebase password-reset emails must land back in the app.
  /// Registered as an Authorised domain / redirect in the Firebase console.
  static const String resetContinueUrl = 'https://yashx.xyz/lifegame';
}

/// Thrown whenever a feature needs Firebase and no project is configured.
class FirebaseNotConfigured implements Exception {
  @override
  String toString() =>
      'Firebase is not configured yet. Add the FIREBASE_* values with '
      '--dart-define and rebuild.';
}
