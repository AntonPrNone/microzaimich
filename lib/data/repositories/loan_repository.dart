import '../../core/utils/formatters.dart';
import '../models/app_notification.dart';
import '../models/loan.dart';
import '../models/payment_schedule_item.dart';
import '../services/app_clock.dart';
import '../services/firestore_service.dart';
import 'notification_repository.dart';

class LoanRepository {
  LoanRepository({
    required FirestoreService firestoreService,
    required NotificationRepository notificationRepository,
  }) : _firestoreService = firestoreService,
       _notificationRepository = notificationRepository;

  final FirestoreService _firestoreService;
  final NotificationRepository _notificationRepository;

  Stream<List<Loan>> watchLoansForUser(String userId) {
    return _firestoreService.loans
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map(
          (snapshot) =>
              snapshot.docs.map(Loan.fromDoc).toList()
                ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt)),
        );
  }

  Stream<List<Loan>> watchAllLoans() {
    return _firestoreService.loans.snapshots().map(
      (snapshot) =>
          snapshot.docs.map(Loan.fromDoc).toList()
            ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt)),
    );
  }

  Future<Loan> createLoan({
    required String userId,
    required String title,
    required double principal,
    required double interestPercent,
    required double totalAmount,
    required double dailyPenaltyAmount,
    required List<PaymentScheduleItem> schedule,
    String? note,
  }) async {
    final ref = _firestoreService.loans.doc();
    final loan = Loan(
      id: ref.id,
      userId: userId,
      title: title,
      principal: principal,
      interestPercent: interestPercent,
      totalAmount: totalAmount,
      dailyPenaltyAmount: dailyPenaltyAmount,
      issuedAt: AppClock.nowForStorage(),
      schedule: schedule,
      status: 'active',
      note: note,
    );
    await ref.set(loan.toMap());
    await _notificationRepository.notifyUser(
      userId: userId,
      title: 'Назначен новый займ',
      body:
          'Вам назначен ${loan.displayTitle} на сумму ${Formatters.money(totalAmount)}',
      type: AppNotificationType.loanAssigned,
    );
    return loan;
  }

  Future<void> payNextInstallment(Loan loan) async {
    final updatedSchedule = [...loan.schedule];
    final index = updatedSchedule.indexWhere((item) => !item.isPaid);
    if (index == -1) {
      return;
    }
    updatedSchedule[index] = updatedSchedule[index].copyWith(
      isPaid: true,
      paidAt: AppClock.nowForStorage(),
      penaltyAccrued: loan.penaltyForItem(updatedSchedule[index]),
      interestAccruedPaid: loan.interestOutstanding,
    );
    await _updateLoan(loan, updatedSchedule);
  }

  Future<void> closeLoan(Loan loan) async {
    final now = AppClock.nowForStorage();
    final unpaidItems = loan.orderedSchedule
        .where((item) => !item.isPaid)
        .toList();
    if (unpaidItems.isEmpty) {
      return;
    }
    final lastUnpaidId = unpaidItems.last.id;
    final updatedSchedule = loan.orderedSchedule.map((item) {
      if (item.isPaid) {
        return item;
      }
      final isSettlementItem = item.id == lastUnpaidId;
      return item.copyWith(
        isPaid: true,
        paidAt: now,
        penaltyAccrued: isSettlementItem ? loan.penaltyOutstanding : 0,
        interestAccruedPaid: isSettlementItem ? loan.interestOutstanding : 0,
      );
    }).toList();
    await _updateLoan(loan, updatedSchedule);
  }

  Future<void> updateLoan(Loan loan) async {
    final isClosed = loan.schedule.every((item) => item.isPaid);
    await _firestoreService.loans.doc(loan.id).update({
      ...loan.toMap(),
      'status': isClosed ? 'closed' : loan.status,
    });
  }

  Future<void> deleteLoansForUser(String userId) async {
    final snapshot = await _firestoreService.loans
        .where('userId', isEqualTo: userId)
        .get();

    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }

  Future<void> _updateLoan(
    Loan loan,
    List<PaymentScheduleItem> schedule,
  ) async {
    final isClosed = schedule.every((item) => item.isPaid);
    await _firestoreService.loans.doc(loan.id).update({
      'schedule': schedule.map((item) => item.toMap()).toList(),
      'status': isClosed ? 'closed' : 'active',
    });
  }
}
