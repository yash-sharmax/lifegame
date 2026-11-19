// Reminder delivery (v2.3.0).
//
// Two channels, honestly separated in the UI:
//
// - In-app reminders (every platform): while the app is open, a timer
//   checks every 30 seconds whether a reminder time has passed today
//   and fires once — an in-app banner (via [alerts]) plus, on web, a
//   browser Notification when permission was granted. Web alarms do
//   NOT fire while the app is closed; the UI says so.
// - Android exact alarms: when a reminder is saved on Android, an
//   exact daily alarm is scheduled with flutter_local_notifications
//   (SCHEDULE_EXACT_ALARM). This fires even with the app closed.
//   Permissions are requested best-effort; a denial only disables the
//   Android channel — in-app reminders still work.
//
// v2.11.2 firing (all three paths, so a reminder fires whether the
// app is open or closed):
// 1. In-app timer while open (every 30s) — posts a "Reminder:
//    <task>" message into the Reminders chat, shows the banner /
//    web notification, and removes the reminder from Active.
// 2. On start AND on resume ([refresh], called by MainShell) — any
//    reminder that became due while the app was closed fires the
//    same way the moment the app runs again, instead of silently
//    staying in Active.
// 3. Android exact alarms — the one-shot alarm fires the system
//    notification even with the app closed; tapping it opens the
//    Reminders tab ([notificationOpened]) and the start/resume
//    check from (2) posts the chat message. When exact alarms are
//    not permitted, the alarm is scheduled inexact instead of
//    failing silently.
// Web has no push server, so a fully-closed browser tab cannot wake
// itself — web relies on (1) + (2); the closed-app guarantee is
// the Android APK path via (3).
//
// All failures are swallowed: a reminder that cannot be delivered
// must never crash the app.
library;

import 'dart:async';

import 'package:appwrite/appwrite.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../logic/reminders.dart';
import '../logic/xp.dart';
import 'local_store.dart';
import 'models.dart';
import 'repositories.dart';
import 'web_notification.dart';

/// A reminder that just fired — the UI shows it as a banner.
class ReminderAlert {
  const ReminderAlert({required this.reminder});

  final Reminder reminder;
}

/// A chat reminder that just fired — the UI shows it as a banner
/// (v2.9.0, Reminders tab).
class ChatReminderAlert {
  const ChatReminderAlert({required this.reminder});

  final ChatReminder reminder;
}

class ReminderService {
  ReminderService._();

  static final ReminderService instance = ReminderService._();

  final _alerts = StreamController<ReminderAlert>.broadcast();

  /// Fires once per due reminder (in-app banner; MainShell listens).
  Stream<ReminderAlert> get alerts => _alerts.stream;

  final _chatAlerts = StreamController<ChatReminderAlert>.broadcast();

  /// Fires once per due CHAT reminder (v2.9.0; MainShell listens).
  Stream<ChatReminderAlert> get chatAlerts => _chatAlerts.stream;

  // v2.11.2: a reminder notification was tapped (or the app was
  // cold-started from one). MainShell listens and opens the
  // Reminders tab, so the user lands on the fired reminder's chat
  // message; the start/resume due-check runs anyway.
  final _notificationOpened = StreamController<void>.broadcast();

  /// Fires when the app is opened from a reminder notification.
  Stream<void> get notificationOpened => _notificationOpened.stream;

  Timer? _timer;
  FlutterLocalNotificationsPlugin? _notifications;
  bool _initialized = false;

  /// Starts the in-app timer and, on Android, the exact-alarm channel.
  /// Safe to call repeatedly; only the first call does the work.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    if (!kIsWeb) {
      await _initAndroidNotifications();
    }
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_tick());
    });
    await _tick();
  }

  /// Stops the in-app timer (only used in tests / shutdown).
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// Re-checks due reminders now (e.g. after a reminder was saved) and
  /// re-schedules Android alarms for the current user.
  Future<void> refresh() async {
    await _tick();
    await _rescheduleAllAndroid();
  }

  /// Asks the browser for notification permission (web only). Called
  /// when the user first saves a reminder; a denial is fine.
  Future<bool> ensureWebPermission() async {
    if (!kIsWeb) return false;
    try {
      return await requestWebNotificationPermission();
    } catch (_) {
      return false;
    }
  }

  // -- Android exact alarms ------------------------------------------------

  Future<void> _initAndroidNotifications() async {
    try {
      tzdata.initializeTimeZones();
      try {
        final info = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(info.identifier));
      } catch (_) {
        // Falls back to tz.local (UTC) — alarms may fire at the wrong
        // hour on devices where the timezone lookup fails.
      }
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        // v2.11.2: tapping the notification opens the Reminders tab
        // (MainShell listens to [notificationOpened]).
        onDidReceiveNotificationResponse: (_) {
          if (!_notificationOpened.isClosed) {
            _notificationOpened.add(null);
          }
        },
      );
      _notifications = plugin;
      // Cold start from a notification tap (v2.11.2): the due-check
      // in refresh() runs on start anyway; this also opens the tab.
      try {
        final launch = await plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp == true) {
          if (!_notificationOpened.isClosed) {
            _notificationOpened.add(null);
          }
        }
      } catch (_) {}
      final android = plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
      await _rescheduleAllAndroid();
    } catch (_) {
      _notifications = null;
    }
  }

  /// Exact alarms need the Android 12+ SCHEDULE_EXACT_ALARM grant.
  /// When it is not granted (user turned it off, or the system
  /// revoked it), schedule INEXACT instead of failing silently —
  /// an approximate notification still beats none at all
  /// (v2.11.2). The grant is requested once at init; this only
  /// reads the current state, never yanks the user to Settings.
  Future<AndroidScheduleMode> _exactOrInexact() async {
    try {
      final android = _notifications
          ?.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return AndroidScheduleMode.exactAllowWhileIdle;
      final canExact = await android.canScheduleExactNotifications();
      if (canExact == true) return AndroidScheduleMode.exactAllowWhileIdle;
      return AndroidScheduleMode.inexactAllowWhileIdle;
    } catch (_) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
  }

  int _notificationId(Reminder reminder) =>
      reminder.id.hashCode & 0x7fffffff;

  /// Schedules (or cancels, when disabled) the exact daily Android
  /// alarm for one reminder. No-op on web and when the plugin failed
  /// to initialise.
  Future<void> scheduleAndroidReminder(Reminder reminder) async {
    final plugin = _notifications;
    if (plugin == null) return;
    final id = _notificationId(reminder);
    try {
      if (!reminder.enabled) {
        await plugin.cancel(id: id);
        return;
      }
      final when = tz.TZDateTime.from(
        nextOccurrence(reminder.timeKey),
        tz.local,
      );
      await plugin.zonedSchedule(
        id: id,
        title: 'Life Game — time for ${reminder.title}',
        body: 'Tap to tick it off and earn +$xpPerTask XP.',
        scheduledDate: when,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'lifegame_reminders',
            'Habit reminders',
            channelDescription: 'Daily reminders for your habits and tasks',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: await _exactOrInexact(),
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // A failed schedule must not break saving the reminder itself.
    }
  }

  Future<void> cancelAndroidReminder(Reminder reminder) async {
    try {
      await _notifications?.cancel(id: _notificationId(reminder));
    } catch (_) {}
  }

  Future<void> _rescheduleAllAndroid() async {
    if (_notifications == null) return;
    final user = AuthRepository.cachedUser;
    if (user == null) return;
    try {
      final store = await LocalStore.getInstance();
      final reminders = store
          .loadReminders()
          .where((r) => r.ownerId == user.uid);
      for (final reminder in reminders) {
        await scheduleAndroidReminder(reminder);
      }
      // v2.9.0: the one-shot chat reminders too.
      final chatReminders = store
          .loadChatReminders(user.uid)
          .where((r) => !r.fired);
      for (final reminder in chatReminders) {
        await scheduleAndroidChatReminder(reminder);
      }
    } catch (_) {}
  }

  // -- Chat reminders (v2.9.0, Reminders tab) ------------------------------
  // A chat reminder is a ONE-SHOT alarm: it fires once, at the exact
  // date + time the user typed. Unlike habit reminders it has no
  // matchDateTimeComponents (no daily repeat) and no "enabled" flag —
  // a fired reminder is marked fired and never fires again.

  int _chatNotificationId(ChatReminder reminder) =>
      ('chat:${reminder.id}').hashCode & 0x7fffffff;

  /// Schedules the one-shot exact Android alarm for a chat reminder.
  /// No-op on web and when the plugin failed to initialise. A
  /// reminder already in the past is not scheduled.
  Future<void> scheduleAndroidChatReminder(ChatReminder reminder) async {
    final plugin = _notifications;
    if (plugin == null) return;
    if (reminder.fired) return;
    final when = tz.TZDateTime.from(reminder.scheduledAt, tz.local);
    if (when.isBefore(tz.TZDateTime.now(tz.local))) return;
    try {
      await plugin.zonedSchedule(
        id: _chatNotificationId(reminder),
        title: 'Reminder',
        body: '${reminder.text} is due.',
        scheduledDate: when,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'lifegame_chat_reminders',
            'Chat reminders',
            channelDescription:
                'Reminders you set by typing in the Reminders tab',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: await _exactOrInexact(),
        // No matchDateTimeComponents: this fires ONCE, at the date
        // + time above — not every day.
      );
    } catch (_) {
      // A failed schedule must not break saving the reminder itself.
    }
  }

  Future<void> cancelAndroidChatReminder(ChatReminder reminder) async {
    try {
      await _notifications?.cancel(id: _chatNotificationId(reminder));
    } catch (_) {}
  }

  // -- In-app timer ----------------------------------------------------------

  Future<void> _tick() async {
    final user = AuthRepository.cachedUser;
    if (user == null) return;
    try {
      final store = await LocalStore.getInstance();
      final now = DateTime.now();
      final today = todayKey(now);
      final reminders = store.loadReminders().where(
        (r) => r.ownerId == user.uid && r.enabled,
      );
      for (final reminder in reminders) {
        final lastFired = store.lastFiredDate(reminder.id);
        if (!isReminderDueNow(
          time: reminder.timeKey,
          now: now,
          lastFiredDateKey: lastFired,
        )) {
          continue;
        }
        await store.markFired(reminder.id, today);
        if (!_alerts.isClosed) {
          _alerts.add(ReminderAlert(reminder: reminder));
        }
        if (kIsWeb) {
          try {
            showWebNotification(
              'Life Game — time for ${reminder.title}',
              'Tap to tick it off and earn +$xpPerTask XP.',
            );
          } catch (_) {}
        }
      }
      // v2.9.0: chat reminders — due when their time has passed and
      // they have not fired yet. Marking them fired here is what
      // stops the in-app banner repeating; the Android alarm fires
      // on its own even with the app closed.
      //
      // v2.11.2: firing also posts a "Reminder: <task>" message into
      // the Reminders chat (so the user sees what fired when they
      // open the tab) and removes the reminder from Active (fired:
      // true). This runs on the 30-second timer while the app is
      // open AND on start/resume (refresh), so reminders that came
      // due while the app was closed fire the moment it runs again.
      final chatReminders = store.loadChatReminders(user.uid);
      var changed = false;
      final firedMessages = <ChatMessage>[];
      for (final reminder in chatReminders) {
        if (reminder.fired) continue;
        if (reminder.scheduledAt.isAfter(now)) continue;
        final fired = reminder.copyWith(fired: true);
        final index = chatReminders.indexWhere((r) => r.id == reminder.id);
        chatReminders[index] = fired;
        changed = true;
        firedMessages.add(
          ChatMessage(
            id: ID.unique(),
            ownerId: user.uid,
            role: 'assistant',
            text: 'Reminder: ${reminder.text}',
            createdAt: now,
          ),
        );
        if (!_chatAlerts.isClosed) {
          _chatAlerts.add(ChatReminderAlert(reminder: fired));
        }
        if (kIsWeb) {
          try {
            showWebNotification('Reminder', '${reminder.text} is due.');
          } catch (_) {}
        }
      }
      if (changed) {
        await store.saveChatReminders(chatReminders);
        if (firedMessages.isNotEmpty) {
          final messages = store.loadChatMessages(user.uid)
            ..addAll(firedMessages);
          await store.saveChatMessages(user.uid, messages);
        }
      }
    } catch (_) {}
  }
}
