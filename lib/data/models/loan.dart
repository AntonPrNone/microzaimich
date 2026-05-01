import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/utils/formatters.dart';
import '../services/app_clock.dart';
import 'payment_schedule_item.dart';

class Loan {
  const Loan({
    required this.id,
    required this.userId,
    required this.title,
    required this.principal,
    required this.interestPercent,
    required this.totalAmount,
    required this.dailyPenaltyAmount,
    required this.issuedAt,
    required this.schedule,
    required this.status,
    this.note,
  });

  final String id;
  final String userId;
  final String title;
  final double principal;
  final double interestPercent;
  final double totalAmount;
  final double dailyPenaltyAmount;
  final DateTime issuedAt;
  final List<PaymentScheduleItem> schedule;
  final String status;
  final String? note;

  List<PaymentScheduleItem> get orderedSchedule =>
      [...schedule]..sort((a, b) => a.dueDate.compareTo(b.dueDate));

  String get displayTitle {
    final trimmed = title.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
    final day = issuedAt.day.toString().padLeft(2, '0');
    final month = issuedAt.month.toString().padLeft(2, '0');
    final year = issuedAt.year.toString();
    return 'Займ $day.$month.$year';
  }

  double get plannedInterestAmount =>
      Formatters.cents(math.max(totalAmount - principal, 0));

  DateTime get termEndDate =>
      orderedSchedule.isEmpty ? issuedAt : orderedSchedule.last.dueDate;

  int get termDays {
    final days = _dateOnly(termEndDate).difference(_dateOnly(issuedAt)).inDays;
    return math.max(days, 1);
  }

  double get dailyInterestAmount {
    if (plannedInterestAmount <= 0) {
      return 0;
    }
    return plannedInterestAmount / termDays;
  }

  double principalAmountForItem(PaymentScheduleItem item) {
    if (item.principalAmount != null && item.principalAmount! > 0) {
      return Formatters.cents(item.principalAmount!);
    }

    final sorted = orderedSchedule;
    final totalScheduledAmount = sorted.fold<double>(
      0,
      (runningTotal, scheduleItem) => runningTotal + scheduleItem.amount,
    );

    if (totalScheduledAmount <= 0 || principal <= 0) {
      return 0;
    }

    final rawPrincipal = principal * (item.amount / totalScheduledAmount);
    final index = sorted.indexWhere(
      (scheduleItem) => scheduleItem.id == item.id,
    );

    if (index == -1) {
      return Formatters.cents(rawPrincipal);
    }

    if (index == sorted.length - 1) {
      final distributed = sorted.take(index).fold<double>(0, (
        runningTotal,
        scheduleItem,
      ) {
        final scheduleRawPrincipal =
            principal * (scheduleItem.amount / totalScheduledAmount);
        return runningTotal + Formatters.cents(scheduleRawPrincipal);
      });
      return Formatters.cents(math.max(principal - distributed, 0));
    }

    return Formatters.cents(rawPrincipal);
  }

  double get principalPaid => Formatters.cents(
    orderedSchedule
        .where((item) => item.isPaid)
        .fold<double>(
          0,
          (runningTotal, item) => runningTotal + principalAmountForItem(item),
        ),
  );

  double get principalOutstanding =>
      Formatters.centsUp(math.max(principal - principalPaid, 0));

  double get interestPaid => Formatters.cents(
    orderedSchedule.fold<double>(
      0,
      (runningTotal, item) => runningTotal + _interestPaidForItem(item),
    ),
  );

  double get penaltyPaid => Formatters.cents(
    orderedSchedule.fold<double>(
      0,
      (runningTotal, item) => runningTotal + item.penaltyAccrued,
    ),
  );

  LoanAccrualSnapshot accrualSnapshot({DateTime? at}) {
    final nowDate = _dateOnly(at ?? AppClock.now());
    final issuedDate = _dateOnly(issuedAt);

    if (!nowDate.isAfter(issuedDate)) {
      return LoanAccrualSnapshot(
        accruedInterest: 0,
        accruedPenalty: 0,
        interestPaid: interestPaid,
        penaltyPaid: penaltyPaid,
      );
    }

    final effectiveEndDate = _dateOnly(termEndDate);
    double accruedInterest = 0;
    double accruedPenalty = 0;

    final elapsedDays = nowDate.difference(issuedDate).inDays;
    for (var dayIndex = 1; dayIndex <= elapsedDays; dayIndex++) {
      final day = issuedDate.add(Duration(days: dayIndex));
      final hasOverdue = orderedSchedule.any(
        (item) => _isItemOverdueOnDate(item, day),
      );

      if (hasOverdue) {
        accruedPenalty += dailyPenaltyAmount;
      } else if (!day.isAfter(effectiveEndDate)) {
        accruedInterest += dailyInterestAmount;
      }
    }

    return LoanAccrualSnapshot(
      accruedInterest: Formatters.cents(accruedInterest),
      accruedPenalty: Formatters.cents(accruedPenalty),
      interestPaid: interestPaid,
      penaltyPaid: penaltyPaid,
    );
  }

  double get interestOutstanding => accrualSnapshot().interestOutstanding;

  double get penaltyOutstanding => accrualSnapshot().penaltyOutstanding;

  double get chargesOutstanding => accrualSnapshot().chargesOutstanding;

  double get outstandingAmount =>
      Formatters.centsUp(principalOutstanding + chargesOutstanding);

  double get paidAmount =>
      Formatters.cents(principalPaid + interestPaid + penaltyPaid);

  double get plannedPaidAmount =>
      Formatters.cents(principalPaid + interestPaid);

  double get plannedOutstandingAmount =>
      Formatters.centsUp(
        math.max(totalAmount - plannedPaidAmount, 0) + penaltyOutstanding,
      );

  PaymentScheduleItem? get nextUnpaid {
    for (final item in orderedSchedule) {
      if (!item.isPaid) {
        return item;
      }
    }
    return null;
  }

  double nextInstallmentAmountAt({DateTime? at}) {
    final next = nextUnpaid;
    if (next == null) {
      return 0;
    }
    return amountForItem(next, at: at);
  }

  double get nextInstallmentAmount => nextInstallmentAmountAt();

  double fullCloseAmountAt({DateTime? at}) {
    final snapshot = accrualSnapshot(at: at);
    return Formatters.centsUp(principalOutstanding + snapshot.chargesOutstanding);
  }

  double get fullCloseAmount => fullCloseAmountAt();

  DateTime periodStartForItem(PaymentScheduleItem item) {
    final sorted = orderedSchedule;
    final index = sorted.indexWhere(
      (scheduleItem) => scheduleItem.id == item.id,
    );
    if (index <= 0) {
      return issuedAt;
    }
    return sorted[index - 1].dueDate;
  }

  int periodDaysForItem(PaymentScheduleItem item) {
    final start = _dateOnly(periodStartForItem(item));
    final end = _dateOnly(item.dueDate);
    return math.max(end.difference(start).inDays, 1);
  }

  double plannedInterestForItem(PaymentScheduleItem item) {
    if (item.interestAccruedPaid > 0) {
      return Formatters.centsUp(item.interestAccruedPaid);
    }

    final sorted = orderedSchedule;
    final index = sorted.indexWhere(
      (scheduleItem) => scheduleItem.id == item.id,
    );
    if (index == -1) {
      return 0;
    }

    if (index == sorted.length - 1) {
      final distributed = sorted
          .take(index)
          .fold<double>(
            0,
            (runningTotal, scheduleItem) =>
                runningTotal + plannedInterestForItem(scheduleItem),
          );
      return Formatters.centsUp(
        math.max(plannedInterestAmount - distributed, 0),
      );
    }

    final rawInterest =
        plannedInterestAmount * (periodDaysForItem(item) / termDays);
    return Formatters.centsUp(rawInterest);
  }

  double interestForItem(PaymentScheduleItem item, {DateTime? at}) {
    if (item.isPaid) {
      return Formatters.centsUp(_interestPaidForItem(item));
    }
    final next = nextUnpaid;
    if (next != null && next.id == item.id) {
      return Formatters.centsUp(accrualSnapshot(at: at).interestOutstanding);
    }
    return plannedInterestForItem(item);
  }

  double amountForItem(PaymentScheduleItem item, {DateTime? at}) {
    final principalPart = principalAmountForItem(item);
    final interestPart = interestForItem(item, at: at);
    final penaltyPart = penaltyForItem(item, at: at);
    return Formatters.centsUp(principalPart + interestPart + penaltyPart);
  }

  double penaltyForItem(PaymentScheduleItem item, {DateTime? at}) {
    if (item.isPaid) {
      return Formatters.centsUp(item.penaltyAccrued);
    }
    final next = nextUnpaid;
    if (next == null || next.id != item.id) {
      return 0;
    }
    final snapshot = accrualSnapshot(at: at);
    if (!snapshot.hasOverdue) {
      return 0;
    }
    return Formatters.centsUp(snapshot.penaltyOutstanding);
  }

  bool isItemOverdue(PaymentScheduleItem item, {DateTime? at}) {
    final nowDate = _dateOnly(at ?? AppClock.now());
    return _isItemOverdueOnDate(item, nowDate);
  }

  bool isItemDueToday(PaymentScheduleItem item, {DateTime? at}) {
    if (item.isPaid) {
      return false;
    }
    final nowDate = _dateOnly(at ?? AppClock.now());
    return _dateOnly(item.dueDate) == nowDate;
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'title': title,
      'principal': principal,
      'interestPercent': interestPercent,
      'totalAmount': totalAmount,
      'dailyPenaltyAmount': dailyPenaltyAmount,
      'issuedAt': Timestamp.fromDate(issuedAt),
      'status': status,
      'note': note,
      'schedule': orderedSchedule.map((item) => item.toMap()).toList(),
    };
  }

  Loan copyWith({
    String? id,
    String? userId,
    String? title,
    double? principal,
    double? interestPercent,
    double? totalAmount,
    double? dailyPenaltyAmount,
    DateTime? issuedAt,
    List<PaymentScheduleItem>? schedule,
    String? status,
    String? note,
  }) {
    return Loan(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      title: title ?? this.title,
      principal: principal ?? this.principal,
      interestPercent: interestPercent ?? this.interestPercent,
      totalAmount: totalAmount ?? this.totalAmount,
      dailyPenaltyAmount: dailyPenaltyAmount ?? this.dailyPenaltyAmount,
      issuedAt: issuedAt ?? this.issuedAt,
      schedule: schedule ?? this.schedule,
      status: status ?? this.status,
      note: note ?? this.note,
    );
  }

  factory Loan.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    final schedule =
        (data['schedule'] as List<dynamic>? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(PaymentScheduleItem.fromMap)
            .toList()
          ..sort((a, b) => a.dueDate.compareTo(b.dueDate));

    return Loan(
      id: doc.id,
      userId: data['userId'] as String? ?? '',
      title: data['title'] as String? ?? '',
      principal: (data['principal'] as num?)?.toDouble() ?? 0,
      interestPercent: (data['interestPercent'] as num?)?.toDouble() ?? 0,
      totalAmount: (data['totalAmount'] as num?)?.toDouble() ?? 0,
      dailyPenaltyAmount: (data['dailyPenaltyAmount'] as num?)?.toDouble() ?? 0,
      issuedAt: (data['issuedAt'] as Timestamp?)?.toDate() == null
          ? AppClock.now()
          : AppClock.toMoscow((data['issuedAt'] as Timestamp).toDate()),
      schedule: schedule,
      status: data['status'] as String? ?? 'active',
      note: data['note'] as String?,
    );
  }

  bool _isItemOverdueOnDate(PaymentScheduleItem item, DateTime date) {
    if (_isItemPaidByDate(item, date)) {
      return false;
    }
    return _dateOnly(item.dueDate).isBefore(date);
  }

  bool _isItemPaidByDate(PaymentScheduleItem item, DateTime date) {
    if (!item.isPaid || item.paidAt == null) {
      return false;
    }
    return !_dateOnly(item.paidAt!).isAfter(date);
  }

  double _interestPaidForItem(PaymentScheduleItem item) {
    if (item.interestAccruedPaid > 0) {
      return item.interestAccruedPaid;
    }
    if (!item.isPaid) {
      return 0;
    }
    final inferredInterest =
        item.amount - principalAmountForItem(item) - item.penaltyAccrued;
    return Formatters.cents(math.max(inferredInterest, 0));
  }

  static DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);
}

class LoanAccrualSnapshot {
  const LoanAccrualSnapshot({
    required this.accruedInterest,
    required this.accruedPenalty,
    required this.interestPaid,
    required this.penaltyPaid,
  });

  final double accruedInterest;
  final double accruedPenalty;
  final double interestPaid;
  final double penaltyPaid;

  double get interestOutstanding =>
      Formatters.centsUp(math.max(accruedInterest - interestPaid, 0));

  double get penaltyOutstanding =>
      Formatters.centsUp(math.max(accruedPenalty - penaltyPaid, 0));

  double get chargesOutstanding =>
      Formatters.centsUp(interestOutstanding + penaltyOutstanding);

  bool get hasOverdue => penaltyOutstanding > 0;
}
