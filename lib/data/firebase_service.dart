import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../config.dart';
import '../firebase_options.dart';

/// Single place that owns the Firebase app.
///
/// Initialised once in main(). When [AppConfig.isConfigured] is false the
/// app is never initialised and every repository throws
/// [FirebaseNotConfigured] with a friendly message instead of crashing.
///
/// App Check: activated only when a reCAPTCHA v3 site key was supplied with
/// `--dart-define FIREBASE_RECAPTCHA_SITE_KEY=...`. Activation failures are
/// swallowed on purpose — App Check must never break sign-in while the
/// site key / enforcement is still being set up (see FIREBASE.md).
class FirebaseService {
  static bool _initialized = false;

  static bool get isConfigured => AppConfig.isConfigured;

  static Future<void> init() async {
    if (!AppConfig.isConfigured) return;
    if (_initialized) return;
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    if (AppConfig.appCheckConfigured) {
      try {
        await FirebaseAppCheck.instance.activate(
          providerWeb: ReCaptchaV3Provider(AppConfig.recaptchaSiteKey),
        );
      } catch (_) {
        // App Check is a hardening layer, not a dependency: if activation
        // fails (e.g. bad site key), the app keeps working without it.
      }
    }
    _initialized = true;
  }

  static bool get isInitialized => _initialized;

  /// Firebase Auth. Throws [FirebaseNotConfigured] when unconfigured.
  static FirebaseAuth get auth {
    if (!AppConfig.isConfigured || !_initialized) {
      throw FirebaseNotConfigured();
    }
    return FirebaseAuth.instance;
  }

  /// Firestore. Throws [FirebaseNotConfigured] when unconfigured.
  static FirebaseFirestore get db {
    if (!AppConfig.isConfigured || !_initialized) {
      throw FirebaseNotConfigured();
    }
    return FirebaseFirestore.instance;
  }

  /// Null-safe accessors used by repositories that must degrade gracefully.
  static FirebaseAuth? get authOrNull {
    if (!AppConfig.isConfigured || !_initialized) return null;
    return FirebaseAuth.instance;
  }

  static FirebaseFirestore? get dbOrNull {
    if (!AppConfig.isConfigured || !_initialized) return null;
    return FirebaseFirestore.instance;
  }
}
