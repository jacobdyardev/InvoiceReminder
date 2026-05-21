import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:invoice_reminder/utils/debug_log.dart';

// Wraps local notification setup, scheduling, and cancellation.
// This is the app's shared notification entry point.
class NotificationService {
  static final _notifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  // Prints pending scheduled notifications in debug builds.
  // Used by reliability diagnostics and manual verification.
  static Future<void> debugPendingNotifications() async {
    final pending = await _notifications.pendingNotificationRequests();

    if (kDebugMode) {
      print("========== PENDING NOTIFICATIONS ==========");
      print("Count: ${pending.length}");

      for (final n in pending) {
        print("ID: ${n.id} | Title: ${n.title}");
      }

      print("===========================================");
    }
  }

  // Exposes the Android-specific notification plugin when needed.
  static AndroidFlutterLocalNotificationsPlugin? get androidPlugin {
    return _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
  }

  // Cancels every scheduled local notification for a full rebuild path.
  static Future<void> cancelAllScheduled() async {
    await _notifications.cancelAll();
  }

  static const String _channelId = 'invoice_reminders';

  // Posts an immediate notification without scheduling.
  // Used for debug feedback and direct alerts.
  static Future<void> showImmediateNotification({
  required int id,
  required String title,
  required String body,
  }) async {
    await _notifications.show(
      id,
      title,
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Invoice Reminders',
          channelDescription: 'Notifications for invoices',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
  
  // Creates the notification channel once and records completion.
  // Writes SharedPreferences state to avoid repeating channel setup.
  static Future<void> primeNotificationChannelOnce() async {
    final prefs = await SharedPreferences.getInstance();

    final alreadyPrimed =
        prefs.getBool('notification_channel_primed') ?? false;

    debugLog("CHANNEL PRIME CHECK → alreadyPrimed: $alreadyPrimed");    

    if (alreadyPrimed) return;

    debugLog("CREATING NOTIFICATION CHANNEL");

    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            'Invoice Reminders',
            description:
                'Notifications for upcoming and due invoices',
            importance: Importance.high,
          ),
        );

    await prefs.setBool('notification_channel_primed', true);

    debugLog("CHANNEL PRIME COMPLETE");
  }

  // Returns whether the OS currently allows app notifications.
  static Future<bool> areNotificationsAllowed() async {
    final androidPlugin =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin == null) return true;

    final allowed = await androidPlugin.areNotificationsEnabled();

    return allowed ?? true;
  }

  // Returns whether exact alarm scheduling is available on Android.
  static Future<bool> canScheduleExactAlarms() async {
    final android =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (android == null) return true;

    final allowed =
        await android.canScheduleExactNotifications();

    return allowed ?? true;
  }

  // Opens the platform flow for exact alarm permission management.
  static Future<void> openExactAlarmSettings() async {
    final android =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await android?.requestExactAlarmsPermission();
  }

  // Schedules a repeating daily notification at the requested time.
  // Used for reminder flows that repeat by time of day.
  static Future<void> scheduleDailyNotification({
  required int id,
  required String title,
  required String body,
  required DateTime startTime,
  }) async {
    final scheduled = tz.TZDateTime.from(startTime, tz.local);

    await _notifications.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Invoice Reminders',
          channelDescription: 'Notifications for upcoming and due invoices',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,

      matchDateTimeComponents: DateTimeComponents.time, // daily repeat
    );
  }

  // Initializes the local notifications plugin and channel state.
  // May also request permissions when running in the foreground.
  static Future<void> init({bool background = false}) async {
    if (_initialized) return;

    tz.initializeTimeZones();
    tz.setLocalLocation(tz.local);

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const settings =
        InitializationSettings(android: androidSettings);

    await _notifications.initialize(settings);

    final android =
        _notifications.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (!background) {
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
    }

    const channel = AndroidNotificationChannel(
      _channelId,
      'Invoice Reminders',
      description: 'Notifications for upcoming and due invoices',
      importance: Importance.high,
    );

    await android?.createNotificationChannel(channel);

    _initialized = true;
  }

  // Schedules a one-shot exact notification for a specific timestamp.
  // Used by the daily summary pipeline and invoice reminder flows.
  static Future<void> scheduleNotification({
  required int id,
  required String title,
  required String body,
  required DateTime dateTime,}) async {
    final scheduled = tz.TZDateTime.from(dateTime, tz.local);

    await _notifications.zonedSchedule(
      id,
      title,
      body,
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Invoice Reminders',
          channelDescription: 'Notifications for upcoming and due invoices',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    
      matchDateTimeComponents: null,
    );
  }

  // Cancels all app notifications, scheduled and active.
  static Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }

  // Cancels one notification ID.
  static Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }

  // Cancels every notification derived from one invoice record.
  // Used when invoice state changes or the invoice is removed.
  static Future<void> cancelAllForInvoice(String id) async {
    final base = id.hashCode & 0x7FFFFFFF;

    await cancel(base + 100000);
    await cancel(base + 1);
    await cancel(base + 2);
    await cancel(base + 3);
    await cancel(base + 30);
  }
}
