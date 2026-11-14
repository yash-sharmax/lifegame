import 'package:appwrite/appwrite.dart';

import '../config.dart';

/// Single place that owns the Appwrite client.
///
/// Initialised once in main(). When [AppConfig.isConfigured] is false the
/// client is never created and every repository throws
/// [AppwriteNotConfigured] with a friendly message instead of crashing.
///
/// The client talks to Appwrite Cloud (Toronto region endpoint).
/// No API key lives here — the app only ever uses the public project ID;
/// the API key belongs to the setup script only (see APPWRITE.md).
class AppwriteService {
  static Client? _client;
  static Account? _account;
  static TablesDB? _databases;

  static bool get isConfigured => AppConfig.isConfigured;

  static void init() {
    if (!AppConfig.isConfigured) return;
    if (_client != null) return;
    final client = Client()
        .setEndpoint(AppConfig.endpoint)
        .setProject(AppConfig.projectId)
        .setSelfSigned(status: false);
    _client = client;
    _account = Account(client);
    _databases = TablesDB(client);
  }

  static bool get isInitialized => _client != null;

  static String get databaseId => AppConfig.databaseId;

  /// Appwrite Account. Throws [AppwriteNotConfigured] when unconfigured.
  static Account get account {
    if (!AppConfig.isConfigured || _account == null) {
      throw AppwriteNotConfigured();
    }
    return _account!;
  }

  /// Appwrite TablesDB. Throws [AppwriteNotConfigured] when unconfigured.
  static TablesDB get db {
    if (!AppConfig.isConfigured || _databases == null) {
      throw AppwriteNotConfigured();
    }
    return _databases!;
  }

  /// Null-safe accessors used by repositories that must degrade gracefully.
  static Account? get accountOrNull =>
      AppConfig.isConfigured ? _account : null;

  static TablesDB? get dbOrNull => AppConfig.isConfigured ? _databases : null;
}
