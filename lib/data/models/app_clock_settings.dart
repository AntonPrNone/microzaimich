import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/app_clock.dart';

class AppClockSettings {
  const AppClockSettings({
    required this.debugEnabled,
    required this.debugNow,
    required this.updatedAt,
  });

  const AppClockSettings.disabled()
    : debugEnabled = false,
      debugNow = null,
      updatedAt = null;

  final bool debugEnabled;
  final DateTime? debugNow;
  final DateTime? updatedAt;

  Map<String, dynamic> toMap() {
    return {
      'debugEnabled': debugEnabled,
      'debugNow': debugNow == null ? null : Timestamp.fromDate(debugNow!),
      'updatedAt': updatedAt == null
          ? FieldValue.serverTimestamp()
          : Timestamp.fromDate(updatedAt!),
    };
  }

  factory AppClockSettings.fromMap(Map<String, dynamic>? data) {
    final map = data ?? <String, dynamic>{};
    return AppClockSettings(
      debugEnabled: map['debugEnabled'] as bool? ?? false,
      debugNow: _readDateTime(map['debugNow']),
      updatedAt: _readDateTime(map['updatedAt']),
    );
  }

  static DateTime? _readDateTime(dynamic value) {
    if (value is Timestamp) {
      return AppClock.toMoscow(value.toDate());
    }
    if (value is DateTime) {
      return AppClock.toMoscow(value);
    }
    if (value is String && value.isNotEmpty) {
      return AppClock.toMoscow(DateTime.parse(value));
    }
    return null;
  }
}
