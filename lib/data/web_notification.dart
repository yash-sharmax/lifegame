// Web Notification API access (conditional import: the real
// implementation only compiles for web).
//
// The app never claims web alarms work while closed: the browser
// Notification is a best-effort extra on top of the in-app banner,
// which fires whenever the app is open.
export 'web_notification_stub.dart'
    if (dart.library.html) 'web_notification_html.dart';
