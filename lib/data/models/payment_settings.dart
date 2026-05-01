import 'package:cloud_firestore/cloud_firestore.dart';

class PaymentSettings {
  const PaymentSettings({
    required this.bankName,
    required this.recipientName,
    required this.recipientPhone,
    required this.paymentLink,
    required this.updatedAt,
  });

  const PaymentSettings.empty()
      : bankName = '',
        recipientName = '',
        recipientPhone = '',
        paymentLink = '',
        updatedAt = null;

  final String bankName;
  final String recipientName;
  final String recipientPhone;
  final String paymentLink;
  final DateTime? updatedAt;

  bool get hasPaymentLink => paymentLink.trim().isNotEmpty;
  bool get hasRecipient => recipientName.trim().isNotEmpty || recipientPhone.trim().isNotEmpty;

  Map<String, dynamic> toMap() {
    return {
      'bankName': bankName.trim(),
      'recipientName': recipientName.trim(),
      'recipientPhone': recipientPhone.trim(),
      'paymentLink': paymentLink.trim(),
      'updatedAt': updatedAt == null ? FieldValue.serverTimestamp() : Timestamp.fromDate(updatedAt!),
    };
  }

  PaymentSettings copyWith({
    String? bankName,
    String? recipientName,
    String? recipientPhone,
    String? paymentLink,
    DateTime? updatedAt,
  }) {
    return PaymentSettings(
      bankName: bankName ?? this.bankName,
      recipientName: recipientName ?? this.recipientName,
      recipientPhone: recipientPhone ?? this.recipientPhone,
      paymentLink: paymentLink ?? this.paymentLink,
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
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
