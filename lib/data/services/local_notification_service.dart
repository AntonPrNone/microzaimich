import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../core/utils/formatters.dart';
import '../../core/utils/platform_utils.dart';
import '../models/app_user.dart';
import '../models/loan.dart';

class LocalNotificationService {
  LocalNotificationService._();

  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  static const MethodChannel platform = MethodChannel('loan_notifications');

  static const _updatesChannelId = 'loan_updates';
  static const _remindersChannelId = 'loan_reminders';
  static const _adminReminderPrefix = 'admin_reminders_';
  static const _clientReminderPrefix = 'client_reminders_';
  static bool _timezoneReady = false;

  static bool get _supportsAndroidNotifications =>
      !kIsWeb && AppPlatform.isAndroid;
  static bool get _supportsAppleNotifications =>
      !kIsWeb && (AppPlatform.isIOS || AppPlatform.isMacOS);
  static bool get _supportsWindowsNotifications =>
      !kIsWeb && AppPlatform.isWindows;
  static bool get _supportsLocalReminders =>
      _supportsAndroidNotifications || _supportsAppleNotifications;
  static const DarwinNotificationDetails _darwinForegroundDetails =
      DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        presentBanner: true,
        presentList: true,
      );

  static Future<void> initialize() async {
    if (kIsWeb) {
      return;
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const windowsInit = WindowsInitializationSettings(
      appName: 'Микрозаймич',
      appUserModelId: 'Anton.Microzaimich.App.1',
      guid: '4f6f0c4a-6e2b-4f36-9d83-6c1a7c3ef7f1',
    );
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: darwinInit,
      macOS: darwinInit,
      windows: windowsInit,
    );

    await plugin.initialize(initSettings);

    if (_supportsAndroidNotifications) {
      await plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    if (AppPlatform.isIOS) {
      await plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    }

    if (AppPlatform.isMacOS) {
      await plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    }

    _ensureTimezones();
  }

  static void _ensureTimezones() {
    if (_timezoneReady) {
      return;
    }
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('Europe/Moscow'));
    } on Object {
      // Fallback to default timezone data location when explicit zone is unavailable.
    }
    _timezoneReady = true;
  }

  static Future<void> showUpdate({
    required String title,
    required String body,
    String? payload,
  }) async {
    if (!_supportsAndroidNotifications &&
        !_supportsAppleNotifications &&
        !_supportsWindowsNotifications) {
      return;
    }

    final details = NotificationDetails(
      android: _supportsAndroidNotifications
          ? const AndroidNotificationDetails(
              _updatesChannelId,
              'События по займам',
              channelDescription:
                  'Назначение займа и подтверждение оплаты администратором',
              importance: Importance.max,
              priority: Priority.high,
            )
          : null,
      iOS: _supportsAppleNotifications ? _darwinForegroundDetails : null,
      macOS: _supportsAppleNotifications ? _darwinForegroundDetails : null,
      windows: _supportsWindowsNotifications
          ? const WindowsNotificationDetails()
          : null,
    );

    await plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: payload,
    );
  }

  static Future<void> syncLoanRemindersForUser(
    AppUser user,
    List<Loan> loans,
  ) async {
    if (!_supportsLocalReminders) {
      return;
    }

    _ensureTimezones();
    final prefs = await SharedPreferences.getInstance();
    final key = '$_clientReminderPrefix${user.id}';
    final previousIds = (prefs.getStringList(key) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final activeIds = <int>{};
    final now = DateTime.now();
    final reminderTime = await getReminderTime(forAdmin: false);

    for (final loan in loans.where((item) => item.status == 'active')) {
      for (final scheduleItem in loan.schedule.where((item) => !item.isPaid)) {
        final dueDate = DateTime(
          scheduleItem.dueDate.year,
          scheduleItem.dueDate.month,
          scheduleItem.dueDate.day,
          reminderTime.hour,
          reminderTime.minute,
        );
        final reminderEntries =
            <({String suffix, DateTime date, String title, String body})>[
              (
                suffix: 'day_before',
                date: dueDate.subtract(const Duration(days: 1)),
                title: 'Платёж уже завтра',
                body:
                    'Займ ${_loanLabel(loan)}: до ${Formatters.date(scheduleItem.dueDate)} нужно внести ${Formatters.money(scheduleItem.amount)}',
              ),
              (
                suffix: 'due_today',
                date: dueDate,
                title: 'Сегодня срок платежа',
                body:
                    'Займ ${_loanLabel(loan)}: сегодня нужно внести ${Formatters.money(scheduleItem.amount)}',
              ),
            ];

        for (final entry in reminderEntries) {
          if (!entry.date.isAfter(now)) {
            continue;
          }
          final id = _stableId(
            '${user.id}_${loan.id}_${scheduleItem.id}_${entry.suffix}',
          );
          activeIds.add(id);
          await _scheduleReminder(
            id: id,
            title: entry.title,
            body: entry.body,
            scheduledAt: tz.TZDateTime.from(entry.date, tz.local),
            payload: loan.id,
          );
        }
      }
    }

    await _dropStaleReminderIds(previousIds, activeIds);
    await prefs.setStringList(
      key,
      activeIds.map((id) => id.toString()).toList(),
    );
  }

  static Future<void> syncAdminDueReminders({
    required AppUser user,
    required List<Loan> loans,
    required Map<String, String> clientNames,
  }) async {
    if (!_supportsLocalReminders) {
      return;
    }

    _ensureTimezones();
    final prefs = await SharedPreferences.getInstance();
    final key = '$_adminReminderPrefix${user.id}';
    final previousIds = (prefs.getStringList(key) ?? const <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final activeIds = <int>{};
    final now = DateTime.now();
    final reminderTime = await getReminderTime(forAdmin: true);

    for (final loan in loans.where((item) => item.status == 'active')) {
      final clientName = clientNames[loan.userId]?.trim();
      if (clientName == null || clientName.isEmpty) {
        continue;
      }

      for (final scheduleItem in loan.schedule.where((item) => !item.isPaid)) {
        final scheduledAt = DateTime(
          scheduleItem.dueDate.year,
          scheduleItem.dueDate.month,
          scheduleItem.dueDate.day,
          reminderTime.hour,
          reminderTime.minute,
        );
        if (!scheduledAt.isAfter(now)) {
          continue;
        }

        final id = _stableId(
          '${user.id}_${loan.id}_${scheduleItem.id}_admin_due',
        );
        activeIds.add(id);
        await _scheduleReminder(
          id: id,
          title: 'У клиента сегодня день платежа',
          body:
              '$clientName • займ ${_loanLabel(loan)}: сегодня срок платежа ${Formatters.money(scheduleItem.amount)}',
          scheduledAt: tz.TZDateTime.from(scheduledAt, tz.local),
          payload: loan.id,
        );
      }
    }

    await _dropStaleReminderIds(previousIds, activeIds);
    await prefs.setStringList(
      key,
      activeIds.map((id) => id.toString()).toList(),
    );
  }

  static Future<void> clearUserReminders(String userId) async {
    if (!_supportsLocalReminders) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    for (final key in <String>[
      '$_clientReminderPrefix$userId',
      '$_adminReminderPrefix$userId',
    ]) {
      final ids = (prefs.getStringList(key) ?? const <String>[])
          .map(int.tryParse)
          .whereType<int>();
      for (final id in ids) {
        await plugin.cancel(id);
      }
      await prefs.remove(key);
    }
  }

  static Future<void> testNotification() async {
    await showUpdate(
      title: 'Тест уведомления',
      body: 'Локальные уведомления работают',
    );
  }

  static Future<void> startBackgroundNotifications(String userId) async {
    if (!_supportsAndroidNotifications) {
      return;
    }
    await platform.invokeMethod('start', {'userId': userId});
  }

  static Future<void> stopBackgroundNotifications() async {
    if (!_supportsAndroidNotifications) {
      return;
    }
    await platform.invokeMethod('stop');
  }

  static Future<void> clearReminderCache() async {
    if (!_supportsAndroidNotifications) {
      return;
    }
    try {
      await platform.invokeMethod('clearReminderCache');
    } on MissingPluginException {
      // Older installed native shells may not expose this method until reinstall.
    }
  }

  static Future<bool> isRunning() async {
    if (!_supportsAndroidNotifications) {
      return false;
    }
    return await platform.invokeMethod<bool>('isRunning') ?? false;
  }

  static Future<bool> isServiceNotificationEnabled() async {
    if (!_supportsAndroidNotifications) {
      return false;
    }
    return await platform.invokeMethod<bool>('isServiceNotificationEnabled') ??
        true;
  }

  static Future<void> openServiceNotificationSettings() async {
    if (!_supportsAndroidNotifications) {
      return;
    }
    await platform.invokeMethod('openServiceNotificationSettings');
  }

  static Future<TimeOfDay> getReminderTime({required bool forAdmin}) async {
    final defaultHour = forAdmin ? 18 : 10;
    if (_supportsAndroidNotifications) {
      final data = await platform.invokeMapMethod<String, dynamic>(
        'getReminderTime',
        {'forAdmin': forAdmin},
      );
      return TimeOfDay(
        hour: ((data?['hour'] as num?)?.toInt() ?? defaultHour).clamp(0, 23),
        minute: ((data?['minute'] as num?)?.toInt() ?? 0).clamp(0, 59),
      );
    }
    if (!_supportsLocalReminders) {
      return TimeOfDay(hour: defaultHour, minute: 0);
    }

    final prefs = await SharedPreferences.getInstance();
    final prefix = forAdmin ? 'admin' : 'client';
    return TimeOfDay(
      hour: (prefs.getInt('${prefix}_reminder_hour') ?? defaultHour).clamp(
        0,
        23,
      ),
      minute: (prefs.getInt('${prefix}_reminder_minute') ?? 0).clamp(0, 59),
    );
  }

  static Future<void> setReminderTime({
    required bool forAdmin,
    required TimeOfDay time,
  }) async {
    if (_supportsAndroidNotifications) {
      await platform.invokeMethod('setReminderTime', {
        'forAdmin': forAdmin,
        'hour': time.hour,
        'minute': time.minute,
      });
      return;
    }
    if (!_supportsLocalReminders) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final prefix = forAdmin ? 'admin' : 'client';
    await prefs.setInt('${prefix}_reminder_hour', time.hour);
    await prefs.setInt('${prefix}_reminder_minute', time.minute);
  }

  static Future<void> _scheduleReminder({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledAt,
    required String payload,
  }) async {
    if (!_supportsLocalReminders) {
      return;
    }

    final details = NotificationDetails(
      android: _supportsAndroidNotifications
          ? const AndroidNotificationDetails(
              _remindersChannelId,
              'Напоминания о платежах',
              channelDescription: 'Напоминания за день и в день платежа',
              importance: Importance.max,
              priority: Priority.high,
            )
          : null,
      iOS: _supportsAppleNotifications ? _darwinForegroundDetails : null,
      macOS: _supportsAppleNotifications ? _darwinForegroundDetails : null,
    );

    try {
      await plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledAt,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        payload: payload,
      );
    } on PlatformException catch (error) {
      if (!_supportsAndroidNotifications ||
          error.code != 'exact_alarms_not_permitted') {
        rethrow;
      }
      await plugin.zonedSchedule(
        id,
        title,
        body,
        scheduledAt,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
      );
    }
  }

  static Future<void> _dropStaleReminderIds(
    Set<int> previousIds,
    Set<int> activeIds,
  ) async {
    for (final id in previousIds.difference(activeIds)) {
      await plugin.cancel(id);
    }
  }

  static int _stableId(String value) {
    var hash = 0;
    for (final codeUnit in value.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0x7fffffff;
    }
    return hash;
  }

  static String _loanLabel(Loan loan) {
    final date = loan.issuedAt;
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();
    return '$day.$month.$year';
  }
}
