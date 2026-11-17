// Non-web stub: browser notifications do not exist here.
library;

/// Always false off the web.
Future<bool> requestWebNotificationPermission() async => false;

/// No-op off the web.
void showWebNotification(String title, String body) {}

/// False off the web.
bool get webNotificationsSupported => false;
