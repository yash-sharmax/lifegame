// App update check (v2.10.0).
//
// On app start (and on resume) the app fetches the live
// version.json and compares it to the running version. When a NEWER
// version is available it raises an "Update available" notice — a
// card in the Notifications screen (bell) and a dot on the bell.
// Tapping the card opens the update (the APK download). The notice
// is deduplicated by version (the same version is never shown twice)
// and can be dismissed (a dismissed version never shows again).
//
// The check NEVER blocks app start and NEVER surfaces an error: it
// fails silently when offline or the fetch fails.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'local_store.dart';

/// The live version.json (the deployed web build's version).
const String kAppVersionUrl = 'https://yashx.xyz/lifegame/version.json';

/// Where tapping an update notice goes: the latest APK.
const String kAppUpdateUrl =
    'https://github.com/yash-sharmax/lifegame/releases/download/apk-latest/app-release.apk';

/// An available update.
class AppUpdateInfo {
  const AppUpdateInfo({required this.version});

  /// The newer version string, e.g. "2.10.0".
  final String version;
}

/// Semantic version compare: negative when [a] < [b], 0 when equal,
/// positive when [a] > [b]. Compares the numeric dot-separated
/// parts; any '+build' suffix is ignored. Pure, so it is unit-tested.
int compareVersions(String a, String b) {
  final aParts = _versionPart(a).split('.');
  final bParts = _versionPart(b).split('.');
  final len = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < len; i++) {
    final aNum = i < aParts.length ? int.tryParse(aParts[i]) ?? 0 : 0;
    final bNum = i < bParts.length ? int.tryParse(bParts[i]) ?? 0 : 0;
    if (aNum != bNum) return aNum.compareTo(bNum);
  }
  return 0;
}

/// The version without any '+build' suffix.
String _versionPart(String version) => version.split('+').first.trim();

class AppUpdateChecker {
  AppUpdateChecker._();

  static final AppUpdateChecker instance = AppUpdateChecker._();

  /// The available update, or null when there is none (or it was
  /// dismissed). The bell and the Notifications screen listen to this.
  final ValueNotifier<AppUpdateInfo?> update = ValueNotifier(null);

  bool _inFlight = false;
  DateTime? _lastCheck;

  /// Fetches the live version and raises the notice when a newer one
  /// is available. Throttled to at most once per 15 minutes (start
  /// and resume both call it); fails silently on any error.
  /// [fetch] is injectable for tests (defaults to a real HTTP GET).
  Future<void> check({
    Future<String> Function(Uri url)? fetch,
  }) async {
    if (_inFlight) return;
    final now = DateTime.now();
    if (_lastCheck != null &&
        now.difference(_lastCheck!) < const Duration(minutes: 15)) {
      return;
    }
    _inFlight = true;
    _lastCheck = now;
    try {
      final current = _versionPart(AppConfig.appVersion);
      final body = await (fetch ??
              (Uri url) async {
                final response = await http
                    .get(url)
                    .timeout(const Duration(seconds: 8));
                if (response.statusCode != 200) {
                  throw Exception('HTTP ${response.statusCode}');
                }
                return response.body;
              })(Uri.parse(kAppVersionUrl));
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return;
      final remoteRaw = decoded['version'];
      if (remoteRaw is! String || remoteRaw.trim().isEmpty) return;
      final remote = _versionPart(remoteRaw);
      if (compareVersions(remote, current) <= 0) {
        // No newer version — clear any stale notice.
        if (update.value != null) update.value = null;
        return;
      }
      final store = await LocalStore.getInstance();
      if (store.updateDismissedVersion == remote) return;
      if (update.value?.version == remote) return;
      update.value = AppUpdateInfo(version: remote);
      await store.setLastSeenUpdateVersion(remote);
    } catch (_) {
      // Fail silently: offline or a bad fetch must never surface.
    } finally {
      _inFlight = false;
    }
  }

  /// Dismisses the current update notice (that version never shows
  /// again). A newer version later still raises a fresh notice.
  Future<void> dismiss() async {
    final version = update.value?.version;
    update.value = null;
    if (version == null) return;
    try {
      final store = await LocalStore.getInstance();
      await store.setUpdateDismissedVersion(version);
    } catch (_) {}
  }

  /// Test-only: resets the throttle + notice so a test can re-check.
  @visibleForTesting
  void resetForTest() {
    update.value = null;
    _lastCheck = null;
    _inFlight = false;
  }
}
