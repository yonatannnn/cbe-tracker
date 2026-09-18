/// Daily "generate your reports" reminder (§FR-6, optional item).
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// A wall-clock time of day, stored as "HH:mm".
class ReminderTime {
  const ReminderTime(this.hour, this.minute);

  final int hour;
  final int minute;

  static const ReminderTime defaultTime = ReminderTime(18, 0);

  static ReminderTime? parse(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return ReminderTime(hour, minute);
  }

  String get stored =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  String get display => stored;
}

class NotificationService {
  NotificationService();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const int reminderId = 1001;
  static const String _channelId = 'daily_reports';

  bool _ready = false;

  /// Sets up plugin + timezone data. Safe to call more than once.
  Future<void> init({void Function(String? payload)? onTap}) async {
    if (_ready) return;

    tz_data.initializeTimeZones();
    tz.setLocalLocation(_deviceLocation());

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        // request* default to TRUE, which pops iOS's permission dialog at
        // first cold open with zero context. Permission is asked exactly once,
        // from the reminder toggle, where the user can see why.
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (response) =>
          onTap?.call(response.payload),
    );
    _ready = true;
  }

  /// Picks the tz location matching the device's current UTC offset.
  ///
  /// The alternative is another package just to read the zone NAME. Matching
  /// on offset is sound here: Ethiopia is UTC+3 year-round with no DST, so the
  /// chosen location's rules and the device's agree. Somewhere with DST could
  /// land on a same-offset zone with different rules and drift by an hour
  /// after a transition — worth revisiting if this ever ships beyond Ethiopia.
  tz.Location _deviceLocation() {
    // TimeZone.offset is a Duration in timezone 0.11 (an int in older ones).
    final offset = DateTime.now().timeZoneOffset;
    for (final location in tz.timeZoneDatabase.locations.values) {
      if (location.currentTimeZone.offset == offset) return location;
    }
    return tz.UTC;
  }

  Future<bool> requestPermission() async {
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? false;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    return await ios?.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        ) ??
        false;
  }

  /// Schedules (or reschedules) the daily reminder.
  Future<void> scheduleDaily(ReminderTime time) async {
    await init();
    await cancel();

    await _plugin.zonedSchedule(
      id: reminderId,
      title: "Time to generate today's branch reports",
      body: 'Tap to open Reports',
      scheduledDate: _nextOccurrence(time),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Daily reports',
          channelDescription: 'Evening reminder to generate branch reports',
          importance: Importance.defaultImportance,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      // Inexact avoids needing the SCHEDULE_EXACT_ALARM permission — a
      // reminder a few minutes late is fine.
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      // Repeat every day at this wall-clock time.
      matchDateTimeComponents: DateTimeComponents.time,
      payload: 'reports',
    );
  }

  Future<void> cancel() => _plugin.cancel(id: reminderId);

  /// The next [time] that is still in the future.
  tz.TZDateTime _nextOccurrence(ReminderTime time) {
    final now = tz.TZDateTime.now(tz.local);
    var next = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    // Already gone today → tomorrow. zonedSchedule rejects a past date.
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next;
  }
}
