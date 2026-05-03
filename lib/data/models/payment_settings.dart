import 'package:cloud_firestore/cloud_firestore.dart';

class PaymentSettings {
  const PaymentSettings({
    required this.bankName,
    required this.recipientName,
    required this.recipientPhone,
    required this.paymentLink,
    required this.adminDueReminderHour,
    required this.adminDueReminderMinute,
    required this.updatedAt,
  });

  const PaymentSettings.empty()
      : bankName = '',
        recipientName = '',
        recipientPhone = '',
        paymentLink = '',
        adminDueReminderHour = 18,
        adminDueReminderMinute = 0,
        updatedAt = null;

  final String bankName;
  final String recipientName;
  final String recipientPhone;
  final String paymentLink;
  final int adminDueReminderHour;
  final int adminDueReminderMinute;
  final DateTime? updatedAt;

  bool get hasPaymentLink => paymentLink.trim().isNotEmpty;
  bool get hasRecipient => recipientName.trim().isNotEmpty || recipientPhone.trim().isNotEmpty;

  Map<String, dynamic> toMap() {
    return {
      'bankName': bankName.trim(),
      'recipientName': recipientName.trim(),
      'recipientPhone': recipientPhone.trim(),
      'paymentLink': paymentLink.trim(),
      'adminDueReminderHour': adminDueReminderHour,
      'adminDueReminderMinute': adminDueReminderMinute,
      'updatedAt': updatedAt == null ? FieldValue.serverTimestamp() : Timestamp.fromDate(updatedAt!),
    };
  }

  PaymentSettings copyWith({
    String? bankName,
    String? recipientName,
    String? recipientPhone,
    String? paymentLink,
    int? adminDueReminderHour,
    int? adminDueReminderMinute,
    DateTime? updatedAt,
  }) {
    return PaymentSettings(
      bankName: bankName ?? this.bankName,
      recipientName: recipientName ?? this.recipientName,
      recipientPhone: recipientPhone ?? this.recipientPhone,
      paymentLink: paymentLink ?? this.paymentLink,
      adminDueReminderHour: adminDueReminderHour ?? this.adminDueReminderHour,
      adminDueReminderMinute:
          adminDueReminderMinute ?? this.adminDueReminderMinute,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory PaymentSettings.fromMap(Map<String, dynamic>? data) {
    final map = data ?? <String, dynamic>{};
    return PaymentSettings(
      bankName: map['bankName'] as String? ?? '',
      recipientName: map['recipientName'] as String? ?? '',
      recipientPhone: map['recipientPhone'] as String? ?? '',
      paymentLink: map['paymentLink'] as String? ?? '',
      adminDueReminderHour: ((map['adminDueReminderHour'] as num?)?.toInt() ?? 18)
          .clamp(0, 23),
      adminDueReminderMinute:
          ((map['adminDueReminderMinute'] as num?)?.toInt() ?? 0).clamp(0, 59),
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
