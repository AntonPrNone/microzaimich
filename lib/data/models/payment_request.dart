import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/app_clock.dart';

enum PaymentRequestType { nextInstallment, fullClose }

enum PaymentRequestStatus { pending, approved, rejected }

class PaymentRequest {
  const PaymentRequest({
    required this.id,
    required this.loanId,
    required this.userId,
    required this.loanLabel,
    required this.type,
    required this.status,
    required this.requestedAmount,
    required this.requestedAt,
    this.principalAmount,
    this.interestAmount,
    this.penaltyAmount,
    this.scheduleItemId,
    this.reviewedAt,
  });

  final String id;
  final String loanId;
  final String userId;
  final String loanLabel;
  final PaymentRequestType type;
  final PaymentRequestStatus status;
  final double requestedAmount;
  final DateTime requestedAt;
  final double? principalAmount;
  final double? interestAmount;
  final double? penaltyAmount;
  final String? scheduleItemId;
  final DateTime? reviewedAt;

  bool get isPending => status == PaymentRequestStatus.pending;

  Map<String, dynamic> toMap() {
    return {
      'loanId': loanId,
      'userId': userId,
      'loanLabel': loanLabel,
      'type': type.name,
      'status': status.name,
      'requestedAmount': requestedAmount,
      'requestedAt': Timestamp.fromDate(requestedAt),
      'principalAmount': principalAmount,
      'interestAmount': interestAmount,
      'penaltyAmount': penaltyAmount,
      'scheduleItemId': scheduleItemId,
      'reviewedAt': reviewedAt == null ? null : Timestamp.fromDate(reviewedAt!),
    };
  }

  PaymentRequest copyWith({
    String? id,
    String? loanId,
    String? userId,
    String? loanLabel,
    PaymentRequestType? type,
    PaymentRequestStatus? status,
    double? requestedAmount,
    DateTime? requestedAt,
    double? principalAmount,
    double? interestAmount,
    double? penaltyAmount,
    String? scheduleItemId,
    DateTime? reviewedAt,
  }) {
    return PaymentRequest(
      id: id ?? this.id,
      loanId: loanId ?? this.loanId,
      userId: userId ?? this.userId,
      loanLabel: loanLabel ?? this.loanLabel,
      type: type ?? this.type,
      status: status ?? this.status,
      requestedAmount: requestedAmount ?? this.requestedAmount,
      requestedAt: requestedAt ?? this.requestedAt,
      principalAmount: principalAmount ?? this.principalAmount,
      interestAmount: interestAmount ?? this.interestAmount,
      penaltyAmount: penaltyAmount ?? this.penaltyAmount,
      scheduleItemId: scheduleItemId ?? this.scheduleItemId,
      reviewedAt: reviewedAt ?? this.reviewedAt,
    );
  }

  factory PaymentRequest.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    return PaymentRequest(
      id: doc.id,
      loanId: data['loanId'] as String? ?? '',
      userId: data['userId'] as String? ?? '',
      loanLabel: data['loanLabel'] as String? ?? '',
      type: PaymentRequestType.values.firstWhere(
        (value) => value.name == (data['type'] as String? ?? ''),
        orElse: () => PaymentRequestType.nextInstallment,
      ),
      status: PaymentRequestStatus.values.firstWhere(
        (value) => value.name == (data['status'] as String? ?? ''),
        orElse: () => PaymentRequestStatus.pending,
      ),
      requestedAmount: (data['requestedAmount'] as num?)?.toDouble() ?? 0,
      requestedAt: (data['requestedAt'] as Timestamp?)?.toDate() == null
          ? AppClock.now()
          : AppClock.toMoscow((data['requestedAt'] as Timestamp).toDate()),
      principalAmount: (data['principalAmount'] as num?)?.toDouble(),
      interestAmount: (data['interestAmount'] as num?)?.toDouble(),
      penaltyAmount: (data['penaltyAmount'] as num?)?.toDouble(),
      scheduleItemId: data['scheduleItemId'] as String?,
      reviewedAt: (data['reviewedAt'] as Timestamp?)?.toDate() == null
          ? null
          : AppClock.toMoscow((data['reviewedAt'] as Timestamp).toDate()),
    );
  }
}
