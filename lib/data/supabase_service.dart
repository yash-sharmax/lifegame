import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';

/// Single place that owns the Supabase client.
///
/// Initialised once in main(). When [AppConfig.isConfigured] is false the
/// client is never created and every repository throws
/// [SupabaseNotConfigured] with a friendly message instead of crashing.
class SupabaseService {
  static bool _initialized = false;

  static bool get isConfigured => AppConfig.isConfigured;

  static Future<void> init() async {
    if (!AppConfig.isConfigured) return;
    if (_initialized) return;
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
    _initialized = true;
  }

  /// The client. Throws [SupabaseNotConfigured] when unconfigured.
  static SupabaseClient get client {
    if (!AppConfig.isConfigured || !_initialized) {
      throw SupabaseNotConfigured();
    }
    return Supabase.instance.client;
  }

  /// Null-safe accessor used by repositories that must degrade gracefully.
  static SupabaseClient? get clientOrNull {
    if (!AppConfig.isConfigured || !_initialized) return null;
    return Supabase.instance.client;
  }
}
