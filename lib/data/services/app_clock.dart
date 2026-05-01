import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_clock_settings.dart';
import 'firestore_service.dart';

class AppClock {
  AppClock._();

  static const Duration _moscowOffset = Duration(hours: 3);
  static Duration _serverOffset = Duration.zero;
  static AppClockSettings _settings = const AppClockSettings.disabled();

  static DateTime now() {
    if (_settings.debugEnabled && _settings.debugNow != null) {
      return toMoscow(_settings.debugNow!);
    }
    return toMoscow(DateTime.now().add(_serverOffset));
  }

  static AppClockSettings get settings => _settings;

  static void applySettings(AppClockSettings settings) {
    _settings = settings;
  }

  static DateTime toMoscow(DateTime date) {
    final utcDate = date.isUtc ? date : date.toUtc();
    final moscow = utcDate.add(_moscowOffset);
    return DateTime(
      moscow.year,
      moscow.month,
      moscow.day,
      moscow.hour,
      moscow.minute,
      moscow.second,
      moscow.millisecond,
      moscow.microsecond,
    );
  }

  static DateTime fromMoscowWallClock(DateTime date) {
    return DateTime.utc(
      date.year,
      date.month,
      date.day,
      date.hour,
      date.minute,
      date.second,
      date.millisecond,
      date.microsecond,
    ).subtract(_moscowOffset);
  }

  static DateTime nowForStorage() => fromMoscowWallClock(now());

  static Future<void> syncServerTime(FirestoreService firestore) async {
    try {
      final probeRef = firestore.appSettings.doc('_server_clock_probe');
      final before = DateTime.now();
      await probeRef.set({
        'serverNow': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      final snapshot = await probeRef.get();
      final after = DateTime.now();
      final serverNow = (snapshot.data()?['serverNow'] as Timestamp?)?.toDate();
      if (serverNow == null) {
        return;
      }
      final midpoint = before.add(
        Duration(milliseconds: after.difference(before).inMilliseconds ~/ 2),
      );
      _serverOffset = serverNow.difference(midpoint);
    } on Object {
      _serverOffset = Duration.zero;
    }
  }
}
