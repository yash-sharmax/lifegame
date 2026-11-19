/// Secure Chat platform channel (v2.11.0, point 10).
///
/// Toggles Android FLAG_SECURE while a secure chat is open, so
/// screenshots / screen recordings are blocked on Android. On web
/// and other platforms this is a no-op — the channel simply does
/// not exist there, and the call is swallowed.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class SecureChat {
  static const MethodChannel _channel = MethodChannel(
    'lifegame/secure_chat',
  );

  /// Turns screenshot blocking on (true) or off (false).
  /// Never throws — on platforms without the channel it does nothing.
  static Future<void> setSecure(bool on) async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod<void>('setSecure', {'on': on});
    } catch (_) {
      // No channel (e.g. iOS, tests, desktop) — screenshots simply
      // cannot be blocked there. Text chat is unaffected.
    }
  }
}
