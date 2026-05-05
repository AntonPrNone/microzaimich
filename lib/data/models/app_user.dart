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
    required this.createdAt,
  });

  final String id;
  final String name;
  final String phone;
  final UserRole role;
  final String? password;
  final DateTime createdAt;

  bool get hasPassword => (password ?? '').isNotEmpty;
  bool get isAdmin => role == UserRole.admin;

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'phone': phone,
      'role': role.value,
      'password': password,
      'createdAt': Timestamp.fromDate(createdAt),
    };
  }

  AppUser copyWith({
    String? id,
    String? name,
    String? phone,
    UserRole? role,
    String? password,
    DateTime? createdAt,
  }) {
    return AppUser(
      id: id ?? this.id,
      name: name ?? this.name,
      phone: phone ?? this.phone,
      role: role ?? this.role,
      password: password ?? this.password,
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
      createdAt: _readDateTime(data['createdAt']),
    );
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
