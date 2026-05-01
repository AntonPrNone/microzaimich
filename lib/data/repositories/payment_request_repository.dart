import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/utils/formatters.dart';
import '../models/app_notification.dart';
import '../models/loan.dart';
import '../models/payment_request.dart';
import '../models/payment_schedule_item.dart';
import '../services/app_clock.dart';
import '../services/firestore_service.dart';
import 'notification_repository.dart';

class PaymentRequestRepository {
  PaymentRequestRepository({
    required FirestoreService firestoreService,
    required NotificationRepository notificationRepository,
  }) : _firestoreService = firestoreService,
       _notificationRepository = notificationRepository;

  final FirestoreService _firestoreService;
  final NotificationRepository _notificationRepository;

  Stream<List<PaymentRequest>> watchRequestsForUser(String userId) {
    return _firestoreService.paymentRequests
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs.map(PaymentRequest.fromDoc).toList()
                ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt)),
        );
  }

  Stream<List<PaymentRequest>> watchAllRequests() {
    return _firestoreService.paymentRequests.snapshots().map(
      (snapshot) =>
          snapshot.docs.map(PaymentRequest.fromDoc).toList()
            ..sort((a, b) => b.requestedAt.compareTo(a.requestedAt)),
    );
  }

  Future<void> createNextInstallmentRequest(Loan loan) async {
    final pending = await _findPendingForLoan(loan.id);
    if (pending != null) {
      throw const PaymentRequestException(
        'По этому займу уже есть заявка, ожидающая подтверждения',
      );
    }

    final nextUnpaid = loan.nextUnpaid;
    if (nextUnpaid == null) {
      throw const PaymentRequestException('У займа нет неоплаченных платежей');
    }

    final requestMoment = AppClock.now();
    final principalAmount = loan.principalAmountForItem(nextUnpaid);
    final interestAmount = loan.interestForItem(nextUnpaid, at: requestMoment);
    final penaltyAmount = loan.penaltyForItem(nextUnpaid, at: requestMoment);

    final ref = _firestoreService.paymentRequests.doc();
    final request = PaymentRequest(
      id: ref.id,
      loanId: loan.id,
      userId: loan.userId,
      loanLabel: _loanLabel(loan),
      type: PaymentRequestType.nextInstallment,
      status: PaymentRequestStatus.pending,
      requestedAmount: Formatters.centsUp(
        principalAmount + interestAmount + penaltyAmount,
      ),
      requestedAt: AppClock.nowForStorage(),
      principalAmount: principalAmount,
      interestAmount: interestAmount,
      penaltyAmount: penaltyAmount,
      scheduleItemId: nextUnpaid.id,
    );
    await ref.set(request.toMap());

    await _notifyAdminsAboutRequest(loan: loan, request: request);
  }

  Future<void> createFullCloseRequest(Loan loan) async {
    final pending = await _findPendingForLoan(loan.id);
    if (pending != null) {
      throw const PaymentRequestException(
        'По этому займу уже есть заявка, ожидающая подтверждения',
      );
    }

    final requestMoment = AppClock.now();
    final snapshot = loan.accrualSnapshot(at: requestMoment);
    final principalAmount = loan.principalOutstanding;
    final interestAmount = snapshot.interestOutstanding;
    final penaltyAmount = snapshot.penaltyOutstanding;

    final ref = _firestoreService.paymentRequests.doc();
    final request = PaymentRequest(
      id: ref.id,
      loanId: loan.id,
      userId: loan.userId,
      loanLabel: _loanLabel(loan),
      type: PaymentRequestType.fullClose,
      status: PaymentRequestStatus.pending,
      requestedAmount: Formatters.centsUp(
        principalAmount + interestAmount + penaltyAmount,
      ),
      requestedAt: AppClock.nowForStorage(),
      principalAmount: principalAmount,
      interestAmount: interestAmount,
      penaltyAmount: penaltyAmount,
    );
    await ref.set(request.toMap());

    await _notifyAdminsAboutRequest(loan: loan, request: request);
  }

  Future<void> approveRequest({
    required PaymentRequest request,
    required Loan loan,
  }) async {
    if (request.type == PaymentRequestType.nextInstallment) {
      final updatedSchedule = [...loan.schedule];
      final index = updatedSchedule.indexWhere(
        (item) => item.id == request.scheduleItemId,
      );
      if (index == -1) {
        throw const PaymentRequestException(
          'Платёж для подтверждения не найден',
        );
      }

      final item = updatedSchedule[index];
      final penaltyToSettle = request.penaltyAmount ?? 0;
      final interestToSettle = request.interestAmount ?? 0;

      updatedSchedule[index] = item.copyWith(
        isPaid: true,
        paidAt: AppClock.nowForStorage(),
        penaltyAccrued: Formatters.cents(item.penaltyAccrued + penaltyToSettle),
        interestAccruedPaid: Formatters.cents(
          item.interestAccruedPaid + interestToSettle,
        ),
      );
      await _updateLoanSchedule(loan, updatedSchedule);
    } else {
      final now = AppClock.nowForStorage();
      final unpaidItems = loan.orderedSchedule
          .where((item) => !item.isPaid)
          .toList();
      if (unpaidItems.isEmpty) {
        return;
      }

      final lastUnpaidId = unpaidItems.last.id;
      final penaltyToSettle = request.penaltyAmount ?? 0;
      final interestToSettle = request.interestAmount ?? 0;

      final updatedSchedule = loan.orderedSchedule.map((item) {
        if (item.isPaid) {
          return item;
        }
        final isSettlementItem = item.id == lastUnpaidId;
        return item.copyWith(
          isPaid: true,
          paidAt: now,
          penaltyAccrued: Formatters.cents(
            item.penaltyAccrued + (isSettlementItem ? penaltyToSettle : 0),
          ),
          interestAccruedPaid: Formatters.cents(
            item.interestAccruedPaid +
                (isSettlementItem ? interestToSettle : 0),
          ),
        );
      }).toList();
      await _updateLoanSchedule(loan, updatedSchedule);
    }

    await _firestoreService.paymentRequests.doc(request.id).update({
      'status': PaymentRequestStatus.approved.name,
      'reviewedAt': Timestamp.fromDate(AppClock.nowForStorage()),
    });

    await _notificationRepository.notifyUser(
      userId: request.userId,
      title: request.type == PaymentRequestType.fullClose
          ? 'Погашение подтверждено'
          : 'Платёж подтверждён',
      body: request.type == PaymentRequestType.fullClose
          ? '${request.loanLabel} полностью подтверждён администратором'
          : 'Администратор подтвердил оплату по займу ${request.loanLabel}',
      type: AppNotificationType.paymentApproved,
    );
  }

  Future<void> rejectRequest(PaymentRequest request) async {
    await _firestoreService.paymentRequests.doc(request.id).update({
      'status': PaymentRequestStatus.rejected.name,
      'reviewedAt': Timestamp.fromDate(AppClock.nowForStorage()),
    });

    await _notificationRepository.notifyUser(
      userId: request.userId,
      title: 'Заявка отклонена',
      body: 'Администратор отклонил заявку по займу ${request.loanLabel}',
      type: AppNotificationType.paymentRejected,
    );
  }

  Future<void> deleteRequestsForUser(String userId) async {
    final snapshot = await _firestoreService.paymentRequests
        .where('userId', isEqualTo: userId)
        .get();
    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }

  Future<PaymentRequest?> _findPendingForLoan(String loanId) async {
    final snapshot = await _firestoreService.paymentRequests
        .where('loanId', isEqualTo: loanId)
        .where('status', isEqualTo: PaymentRequestStatus.pending.name)
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) {
      return null;
    }
    return PaymentRequest.fromDoc(snapshot.docs.first);
  }

  Future<void> _updateLoanSchedule(
    Loan loan,
    List<PaymentScheduleItem> schedule,
  ) async {
    final isClosed = schedule.every((item) => item.isPaid);
    await _firestoreService.loans.doc(loan.id).update({
      'schedule': schedule.map((item) => item.toMap()).toList(),
      'status': isClosed ? 'closed' : 'active',
    });
  }

  Future<void> _notifyAdminsAboutRequest({
    required Loan loan,
    required PaymentRequest request,
  }) async {
    final userDoc = await _firestoreService.users.doc(loan.userId).get();
    final userName = userDoc.data()?['name'] as String? ?? 'Клиент';

    final title = request.type == PaymentRequestType.fullClose
        ? 'Клиент заявил полное погашение'
        : 'Клиент оплатил следующий платёж';

    final body = request.type == PaymentRequestType.fullClose
        ? '$userName сообщил, что полностью закрыл ${_loanLabel(loan)} на сумму ${Formatters.money(request.requestedAmount)}. Проверьте перевод и подтвердите закрытие, если оплата действительно поступила'
        : '$userName сообщил, что оплатил следующий платёж по займу ${_loanLabel(loan)} на сумму ${Formatters.money(request.requestedAmount)}. Проверьте перевод и подтвердите платёж, если оплата действительно поступила';

    await _notificationRepository.notifyAdmins(
      title: title,
      body: body,
      type: AppNotificationType.paymentSubmitted,
    );
  }

  String _loanLabel(Loan loan) => loan.displayTitle;
}

class PaymentRequestException implements Exception {
  const PaymentRequestException(this.message);

  final String message;

  @override
  String toString() => message;
}
