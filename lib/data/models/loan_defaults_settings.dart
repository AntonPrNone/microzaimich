import 'package:cloud_firestore/cloud_firestore.dart';

class LoanDefaultsSettings {
  const LoanDefaultsSettings({
    required this.principal,
    required this.interestPercent,
    required this.dailyPenaltyAmount,
    required this.paymentCount,
    required this.paymentIntervalCount,
    required this.paymentIntervalUnit,
    required this.updatedAt,
  });

  const LoanDefaultsSettings.empty()
      : principal = 0,
        interestPercent = 0,
        dailyPenaltyAmount = 0,
        paymentCount = 6,
        paymentIntervalCount = 1,
        paymentIntervalUnit = 'months',
        updatedAt = null;

  final double principal;
  final double interestPercent;
  final double dailyPenaltyAmount;
  final int paymentCount;
  final int paymentIntervalCount;
  final String paymentIntervalUnit;
  final DateTime? updatedAt;

  Map<String, dynamic> toMap() {
    return {
      'principal': principal,
      'interestPercent': interestPercent,
      'dailyPenaltyAmount': dailyPenaltyAmount,
      'paymentCount': paymentCount,
      'paymentIntervalCount': paymentIntervalCount,
      'paymentIntervalUnit': paymentIntervalUnit,
      'updatedAt': updatedAt == null
          ? FieldValue.serverTimestamp()
          : Timestamp.fromDate(updatedAt!),
    };
  }

  factory LoanDefaultsSettings.fromMap(Map<String, dynamic>? data) {
    final map = data ?? <String, dynamic>{};
    return LoanDefaultsSettings(
      principal: (map['principal'] as num?)?.toDouble() ?? 0,
      interestPercent: (map['interestPercent'] as num?)?.toDouble() ?? 0,
      dailyPenaltyAmount: (map['dailyPenaltyAmount'] as num?)?.toDouble() ?? 0,
      paymentCount: (map['paymentCount'] as num?)?.toInt() ?? 6,
      paymentIntervalCount: (map['paymentIntervalCount'] as num?)?.toInt() ?? 1,
      paymentIntervalUnit: map['paymentIntervalUnit'] as String? ?? 'months',
      updatedAt: (map['updatedAt'] as Timestamp?)?.toDate(),
    );
  }
}
