import '../services/app_clock.dart';

class PaymentScheduleItem {
  const PaymentScheduleItem({
    required this.id,
    required this.dueDate,
    required this.amount,
    required this.isPaid,
    required this.penaltyAccrued,
    this.principalAmount,
    this.interestAccruedPaid = 0,
    this.paidAt,
  });

  final String id;
  final DateTime dueDate;
  final double amount;
  final bool isPaid;
  final double penaltyAccrued;
  final double? principalAmount;
  final double interestAccruedPaid;
  final DateTime? paidAt;

  double get settledCharges => interestAccruedPaid + penaltyAccrued;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'dueDate': dueDate.toIso8601String(),
      'amount': amount,
      'isPaid': isPaid,
      'penaltyAccrued': penaltyAccrued,
      'principalAmount': principalAmount,
      'interestAccruedPaid': interestAccruedPaid,
      'paidAt': paidAt?.toIso8601String(),
    };
  }

  PaymentScheduleItem copyWith({
    String? id,
    DateTime? dueDate,
    double? amount,
    bool? isPaid,
    double? penaltyAccrued,
    double? principalAmount,
    double? interestAccruedPaid,
    DateTime? paidAt,
  }) {
    return PaymentScheduleItem(
      id: id ?? this.id,
      dueDate: dueDate ?? this.dueDate,
      amount: amount ?? this.amount,
      isPaid: isPaid ?? this.isPaid,
      penaltyAccrued: penaltyAccrued ?? this.penaltyAccrued,
      principalAmount: principalAmount ?? this.principalAmount,
      interestAccruedPaid: interestAccruedPaid ?? this.interestAccruedPaid,
      paidAt: paidAt ?? this.paidAt,
    );
  }

  factory PaymentScheduleItem.fromMap(Map<String, dynamic> map) {
    final parsedDueDate = DateTime.tryParse(map['dueDate'] as String? ?? '');
    final parsedPaidAt = DateTime.tryParse(map['paidAt'] as String? ?? '');
    return PaymentScheduleItem(
      id: map['id'] as String? ?? '',
      dueDate: parsedDueDate == null
          ? AppClock.now()
          : AppClock.toMoscow(parsedDueDate),
      amount: (map['amount'] as num?)?.toDouble() ?? 0,
      isPaid: map['isPaid'] as bool? ?? false,
      penaltyAccrued: (map['penaltyAccrued'] as num?)?.toDouble() ?? 0,
      principalAmount: (map['principalAmount'] as num?)?.toDouble(),
      interestAccruedPaid:
          (map['interestAccruedPaid'] as num?)?.toDouble() ?? 0,
      paidAt: parsedPaidAt == null ? null : AppClock.toMoscow(parsedPaidAt),
    );
  }
}
