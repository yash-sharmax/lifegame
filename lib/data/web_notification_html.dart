// Browser Notification API (web only).
//
// dart:html is deprecated in favour of package:web — kept here because
// it is still present in the pinned SDK (Flutter 3.47 / Dart 3.13) and
// is far simpler for this one call. If a future SDK removes dart:html,
// move these two functions to package:web.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
library;

import 'dart:html' as html;

/// Asks the browser for notification permission. Returns true when
/// the user granted it.
Future<bool> requestWebNotificationPermission() async {
  if (!html.Notification.supported) return false;
  if (html.Notification.permission == 'granted') return true;
  final permission = await html.Notification.requestPermission();
  return permission == 'granted';
}

/// Shows a browser notification (only when permission was granted).
void showWebNotification(String title, String body) {
  if (!html.Notification.supported) return;
  if (html.Notification.permission != 'granted') return;
  html.Notification(title, body: body);
}

/// True when this browser supports the Notification API at all.
bool get webNotificationsSupported => html.Notification.supported;
