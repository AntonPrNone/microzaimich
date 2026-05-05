import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../core/utils/formatters.dart';
import '../models/app_user.dart';
import '../models/loan.dart';

class LocalNotificationService {
  LocalNotificationService._();

  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  static const MethodChannel platform = MethodChannel('loan_notifications');

  static const _updatesChannelId = 'loan_updates';
  static const _remindersChannelId = 'loan_reminders';
  static bool _timezoneReady = false;

  static Future<void> initialize() async {
    if (kIsWeb) {
      return;
    }
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await plugin.initialize(initSettings);
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
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
    if (kIsWeb) {
      return;
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _updatesChannelId,
        'События по займам',
        channelDescription: 'Назначение займа, заявки на оплату и подтверждения',
        importance: Importance.max,
        priority: Priority.high,
      ),
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
    if (kIsWeb) {
      return;
    }
    _ensureTimezones();
    final prefs = await SharedPreferences.getInstance();
    final key = 'scheduled_reminders_${user.id}';
    final previousIds = (prefs.getStringList(key) ?? <String>[])
        .map(int.tryParse)
        .whereType<int>()
        .toSet();
    final activeIds = <int>{};
    final now = DateTime.now();

    for (final loan in loans.where((item) => item.status == 'active')) {
      for (final scheduleItem in loan.schedule.where((item) => !item.isPaid)) {
        final dueDate = DateTime(
          scheduleItem.dueDate.year,
          scheduleItem.dueDate.month,
          scheduleItem.dueDate.day,
          10,
        );
        final reminderEntries = <({String suffix, DateTime date, String title, String body})>[
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

    for (final id in previousIds.difference(activeIds)) {
      await plugin.cancel(id);
    }

    await prefs.setStringList(
      key,
      activeIds.map((id) => id.toString()).toList(),
    );
  }

  static Future<void> clearUserReminders(String userId) async {
    if (kIsWeb) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final key = 'scheduled_reminders_$userId';
    final ids = (prefs.getStringList(key) ?? <String>[])
        .map(int.tryParse)
        .whereType<int>();
    for (final id in ids) {
      await plugin.cancel(id);
    }
    await prefs.remove(key);
  }

  static Future<void> testNotification() async {
    await showUpdate(
      title: 'Тест уведомления',
      body: 'Локальные уведомления работают',
    );
  }

  static Future<void> startBackgroundNotifications(String userId) async {
    if (kIsWeb) {
      return;
    }
    await platform.invokeMethod('start', {'userId': userId});
  }

  static Future<void> stopBackgroundNotifications() async {
    if (kIsWeb) {
      return;
    }
    await platform.invokeMethod('stop');
  }

  static Future<void> clearReminderCache() async {
    if (kIsWeb) {
      return;
    }
    try {
      await platform.invokeMethod('clearReminderCache');
    } on MissingPluginException {
      // Older installed native shells may not expose this method until reinstall.
    }
  }

  static Future<bool> isRunning() async {
    if (kIsWeb) {
      return false;
    }
    return await platform.invokeMethod<bool>('isRunning') ?? false;
  }

  static Future<bool> isServiceNotificationEnabled() async {
    if (kIsWeb) {
      return false;
    }
    return await platform.invokeMethod<bool>('isServiceNotificationEnabled') ??
        true;
  }

  static Future<void> openServiceNotificationSettings() async {
    if (kIsWeb) {
      return;
    }
    await platform.invokeMethod('openServiceNotificationSettings');
  }

  static Future<TimeOfDay> getReminderTime({required bool forAdmin}) async {
    if (kIsWeb) {
      return TimeOfDay(hour: forAdmin ? 18 : 10, minute: 0);
    }
    final data = await platform.invokeMapMethod<String, dynamic>(
      'getReminderTime',
      {'forAdmin': forAdmin},
    );
    final defaultHour = forAdmin ? 18 : 10;
    return TimeOfDay(
      hour: ((data?['hour'] as num?)?.toInt() ?? defaultHour).clamp(0, 23),
      minute: ((data?['minute'] as num?)?.toInt() ?? 0).clamp(0, 59),
    );
  }

  static Future<void> setReminderTime({
    required bool forAdmin,
    required TimeOfDay time,
  }) async {
    if (kIsWeb) {
      return;
    }
    await platform.invokeMethod('setReminderTime', {
      'forAdmin': forAdmin,
      'hour': time.hour,
      'minute': time.minute,
    });
  }

  static Future<void> _scheduleReminder({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime scheduledAt,
    required String payload,
  }) async {
    if (kIsWeb) {
      return;
    }
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _remindersChannelId,
        'Напоминания о платежах',
        channelDescription: 'Напоминания за день и в день платежа',
        importance: Importance.max,
        priority: Priority.high,
      ),
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
      if (error.code != 'exact_alarms_not_permitted') {
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
