import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/app_clock.dart';

enum AppNotificationType {
  loanAssigned,
  paymentApproved,
  paymentReminder,
}

class AppNotification {
  const AppNotification({
    required this.id,
    required this.userId,
    required this.title,
    required this.body,
    required this.type,
    required this.createdAt,
    this.readAt,
  });

  final String id;
  final String userId;
  final String title;
  final String body;
  final AppNotificationType type;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get isRead => readAt != null;

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'title': title,
      'body': body,
      'type': type.name,
      'createdAt': Timestamp.fromDate(createdAt),
      'readAt': readAt == null ? null : Timestamp.fromDate(readAt!),
    };
  }

  factory AppNotification.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    return AppNotification.fromMap(doc.id, data);
  }

  factory AppNotification.fromMap(String id, Map<String, dynamic> data) {
    return AppNotification(
      id: id,
      userId: data['userId'] as String? ?? '',
      title: data['title'] as String? ?? '',
      body: data['body'] as String? ?? '',
      type: AppNotificationType.values.firstWhere(
        (value) => value.name == (data['type'] as String? ?? ''),
        orElse: () => AppNotificationType.paymentReminder,
      ),
      createdAt: _readDateTime(data['createdAt']) ?? AppClock.now(),
      readAt: _readDateTime(data['readAt']),
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
