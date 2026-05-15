import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/app_clock.dart';
import 'user_role.dart';

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.phone,
    required this.role,
    required this.password,
    required this.reminderHour,
    required this.reminderMinute,
    required this.telegramNotificationsEnabled,
    required this.createdAt,
    this.telegramChatId,
    this.telegramUsername,
    this.telegramLinkCode,
    this.telegramLinkedAt,
  });

  final String id;
  final String name;
  final String phone;
  final UserRole role;
  final String? password;
  final int reminderHour;
  final int reminderMinute;
  final String? telegramChatId;
  final String? telegramUsername;
  final String? telegramLinkCode;
  final DateTime? telegramLinkedAt;
  final bool telegramNotificationsEnabled;
  final DateTime createdAt;

  bool get hasPassword => (password ?? '').isNotEmpty;
  bool get isAdmin => role == UserRole.admin;
  bool get hasTelegramLinked => (telegramChatId ?? '').isNotEmpty;

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phone': phone,
      'role': role.value,
      'password': password,
      'reminderHour': reminderHour,
      'reminderMinute': reminderMinute,
      'telegramChatId': telegramChatId,
      'telegramUsername': telegramUsername,
      'telegramLinkCode': telegramLinkCode,
      'telegramLinkedAt': telegramLinkedAt == null
          ? null
          : Timestamp.fromDate(telegramLinkedAt!),
      'telegramNotificationsEnabled': telegramNotificationsEnabled,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  AppUser copyWith({
    String? id,
    String? name,
    String? phone,
    UserRole? role,
    String? password,
    int? reminderHour,
    int? reminderMinute,
    String? telegramChatId,
    String? telegramUsername,
    String? telegramLinkCode,
    DateTime? telegramLinkedAt,
    bool? telegramNotificationsEnabled,
    DateTime? createdAt,
  }) {
    return AppUser(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      password: password ?? this.password,
      reminderHour: reminderHour ?? this.reminderHour,
      reminderMinute: reminderMinute ?? this.reminderMinute,
      telegramChatId: telegramChatId ?? this.telegramChatId,
      telegramUsername: telegramUsername ?? this.telegramUsername,
      telegramLinkCode: telegramLinkCode ?? this.telegramLinkCode,
      telegramLinkedAt: telegramLinkedAt ?? this.telegramLinkedAt,
      telegramNotificationsEnabled:
          telegramNotificationsEnabled ?? this.telegramNotificationsEnabled,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory AppUser.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    return AppUser.fromMap(doc.id, data);
  }

  factory AppUser.fromMap(String id, Map<String, dynamic> data) {
    return AppUser(
      id: id,
      name: data['name'] as String? ?? '',
      phone: data['phone'] as String? ?? '',
      role: UserRole.fromValue(data['role'] as String? ?? 'client'),
      password: data['password'] as String?,
      reminderHour: ((data['reminderHour'] as num?)?.toInt() ?? 18).clamp(0, 23),
      reminderMinute:
          ((data['reminderMinute'] as num?)?.toInt() ?? 0).clamp(0, 59),
      telegramChatId: data['telegramChatId'] as String?,
      telegramUsername: data['telegramUsername'] as String?,
      telegramLinkCode: data['telegramLinkCode'] as String?,
      telegramLinkedAt: _readNullableDateTime(data['telegramLinkedAt']),
      telegramNotificationsEnabled:
          data['telegramNotificationsEnabled'] as bool? ??
          ((data['telegramChatId'] as String?)?.isNotEmpty ?? false),
      createdAt: _readDateTime(data['createdAt']),
    );
  }

  static DateTime? _readNullableDateTime(dynamic value) {
    if (value == null) {
      return null;
    }
    return _readDateTime(value);
  }

  static DateTime _readDateTime(dynamic value) {
    if (value is Timestamp) {
      return AppClock.toMoscow(value.toDate());
    }
    if (value is DateTime) {
      return AppClock.toMoscow(value);
    }
    if (value is String) {
      return AppClock.toMoscow(DateTime.parse(value));
    }
    return AppClock.now();
  }
}
