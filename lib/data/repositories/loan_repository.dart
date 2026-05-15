import '../../core/utils/formatters.dart';
import '../../core/utils/platform_utils.dart';
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

  List<Loan> _mapAndSortLoans(Iterable<dynamic> docs) {
    final loansById = <String, Loan>{};
    for (final doc in docs) {
      loansById[doc.id as String] = Loan.fromMap(
        doc.id as String,
        doc.data as Map<String, dynamic>,
      );
    }
    final loans = loansById.values.toList()
      ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt));
    return loans;
  }

  int _loanListSignature(List<Loan> loans) {
    return Object.hashAll(
      loans.map(
        (loan) => Object.hash(
          loan.id,
          loan.status,
          loan.issuedAt.millisecondsSinceEpoch,
          loan.plannedOutstandingAmount,
          loan.fullCloseAmount,
          loan.paidAmount,
          loan.interestPaid,
          loan.penaltyOutstanding,
          loan.penaltyPaid,
          loan.schedule.length,
          Object.hashAll(
            loan.schedule.map(
              (item) => Object.hash(
                item.id,
                item.isPaid,
                item.dueDate.millisecondsSinceEpoch,
                item.paidAt?.millisecondsSinceEpoch,
                item.amount,
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _sameLoanLists(List<Loan> previous, List<Loan> next) {
    return _loanListSignature(previous) == _loanListSignature(next);
  }

  Stream<List<Loan>> watchLoansForUser(String userId) {
    if (AppPlatform.isWindows) {
      return _firestoreService.windowsStream!
          .watchCollectionWhereEqual(
            'loans',
            fieldPath: 'userId',
            isEqualTo: userId,
          )
          .map(_mapAndSortLoans)
          .distinct(_sameLoanLists);
    }

    return _firestoreService.loans
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.map(Loan.fromDoc).toList()
            ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt)),
        );
  }

  Stream<List<Loan>> watchAllLoans() {
    if (AppPlatform.isWindows) {
      return _firestoreService.windowsStream!
          .watchCollection('loans')
          .map(_mapAndSortLoans)
          .distinct(_sameLoanLists);
    }

    return _firestoreService.loans.snapshots().map(
      (snapshot) => snapshot.docs.map(Loan.fromDoc).toList()
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
    required DateTime issuedAt,
    required List<PaymentScheduleItem> schedule,
    int paymentIntervalCount = 0,
    String paymentIntervalUnit = '',
    String? note,
  }) async {
    if (AppPlatform.isWindows) {
      final created = await _firestoreService.windowsStream!.createDocument(
        'loans',
        {
          'userId': userId,
          'title': title,
          'principal': principal,
          'interestPercent': interestPercent,
          'totalAmount': totalAmount,
          'dailyPenaltyAmount': dailyPenaltyAmount,
          'issuedAt': issuedAt,
          'status': 'active',
          'paymentIntervalCount': paymentIntervalCount,
          'paymentIntervalUnit': paymentIntervalUnit,
          'note': note,
          'schedule': schedule.map((item) => item.toMap()).toList(),
        },
      );
      final loan = Loan.fromMap(created.id, created.data);
      await _notificationRepository.notifyUser(
        userId: userId,
        title: 'Назначен новый займ',
        body:
            'Вам назначен ${loan.displayTitle} на сумму ${Formatters.money(totalAmount)}',
        type: AppNotificationType.loanAssigned,
      );
      return loan;
    }

    final ref = _firestoreService.loans.doc();
    final loan = Loan(
      id: ref.id,
      userId: userId,
      title: title,
      principal: principal,
      interestPercent: interestPercent,
      totalAmount: totalAmount,
      dailyPenaltyAmount: dailyPenaltyAmount,
      issuedAt: issuedAt,
      schedule: schedule,
      status: 'active',
      paymentIntervalCount: paymentIntervalCount,
      paymentIntervalUnit: paymentIntervalUnit,
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
    final targetItem = updatedSchedule[index];
    updatedSchedule[index] = updatedSchedule[index].copyWith(
      isPaid: true,
      paidAt: AppClock.nowForStorage(),
      penaltyAccrued: loan.penaltyForItem(targetItem),
      interestAccruedPaid: loan.plannedInterestForItem(targetItem),
    );
    await _updateLoan(loan, updatedSchedule);
  }

  Future<void> closeLoan(Loan loan, {DateTime? paidAt}) async {
    final settlementDate = paidAt ?? AppClock.now();
    final settlementStorageDate = AppClock.fromMoscowWallClock(settlementDate);
    final unpaidItems = loan.orderedSchedule.where((item) => !item.isPaid).toList();
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
        paidAt: settlementStorageDate,
        penaltyAccrued: isSettlementItem
            ? loan.penaltyForItem(item, at: settlementDate)
            : 0,
        interestAccruedPaid: isSettlementItem
            ? loan.interestOutstandingAt(settlementDate)
            : 0,
      );
    }).toList();
    await updateLoan(
      loan.copyWith(
        schedule: updatedSchedule,
        status: 'closed',
      ),
    );
  }

  Future<void> updateLoan(Loan loan) async {
    if (AppPlatform.isWindows) {
      final previousSnapshot = await _firestoreService.windowsStream!.getDocument(
        'loans/${loan.id}',
      );
      final previousLoan = previousSnapshot == null
          ? null
          : Loan.fromMap(previousSnapshot.id, previousSnapshot.data);
      final isClosed = loan.schedule.every((item) => item.isPaid);
      await _firestoreService.windowsStream!.updateDocument('loans/${loan.id}', {
        ...loan.toMap(),
        'status': isClosed ? 'closed' : loan.status,
      });

      if (previousLoan == null) {
        return;
      }

      final previousItems = {
        for (final item in previousLoan.schedule) item.id: item,
      };
      final newlyPaidItems = loan.schedule.where((item) {
        final previousItem = previousItems[item.id];
        return item.isPaid && (previousItem == null || !previousItem.isPaid);
      }).toList()
        ..sort((a, b) => a.dueDate.compareTo(b.dueDate));

      if (newlyPaidItems.isEmpty) {
        return;
      }

      if (isClosed && previousLoan.status != 'closed') {
        await _notificationRepository.notifyUser(
          userId: loan.userId,
          title: 'Займ закрыт',
          body:
              'Администратор отметил полное погашение по займу ${loan.displayTitle}.',
          type: AppNotificationType.paymentApproved,
        );
        return;
      }

      final paidItem = newlyPaidItems.last;
      await _notificationRepository.notifyUser(
        userId: loan.userId,
        title: 'Платёж отмечен как оплаченный',
        body:
            'Администратор отметил оплату по займу ${loan.displayTitle}'
            ' со сроком ${Formatters.date(paidItem.dueDate)}.',
        type: AppNotificationType.paymentApproved,
      );
      return;
    }

    final previousSnapshot = await _firestoreService.loans.doc(loan.id).get();
    final previousLoan = previousSnapshot.exists ? Loan.fromDoc(previousSnapshot) : null;
    final isClosed = loan.schedule.every((item) => item.isPaid);
    await _firestoreService.loans.doc(loan.id).update({
      ...loan.toMap(),
      'status': isClosed ? 'closed' : loan.status,
    });

    if (previousLoan == null) {
      return;
    }

    final previousItems = {
      for (final item in previousLoan.schedule) item.id: item,
    };
    final newlyPaidItems = loan.schedule.where((item) {
      final previousItem = previousItems[item.id];
      return item.isPaid && (previousItem == null || !previousItem.isPaid);
    }).toList()
      ..sort((a, b) => a.dueDate.compareTo(b.dueDate));

    if (newlyPaidItems.isEmpty) {
      return;
    }

    if (isClosed && previousLoan.status != 'closed') {
      await _notificationRepository.notifyUser(
        userId: loan.userId,
        title: 'Займ закрыт',
        body:
            'Администратор отметил полное погашение по займу ${loan.displayTitle}.',
        type: AppNotificationType.paymentApproved,
      );
      return;
    }

    final paidItem = newlyPaidItems.last;
    await _notificationRepository.notifyUser(
      userId: loan.userId,
      title: 'Платёж отмечен как оплаченный',
      body:
          'Администратор отметил оплату по займу ${loan.displayTitle}'
          ' со сроком ${Formatters.date(paidItem.dueDate)}.',
      type: AppNotificationType.paymentApproved,
    );
  }

  Future<void> deleteLoansForUser(String userId) async {
    if (AppPlatform.isWindows) {
      final docs = await _firestoreService.windowsStream!.queryDocuments(
        'loans',
        whereField: 'userId',
        isEqualTo: userId,
      );
      for (final doc in docs) {
        await _firestoreService.windowsStream!.deleteDocument('loans/${doc.id}');
      }
      return;
    }

    final snapshot = await _firestoreService.loans.where('userId', isEqualTo: userId).get();
    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }

  Future<void> deleteLoan(String loanId) async {
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.deleteDocument('loans/$loanId');
      return;
    }
    await _firestoreService.loans.doc(loanId).delete();
  }

  Future<void> _updateLoan(Loan loan, List<PaymentScheduleItem> schedule) async {
    if (AppPlatform.isWindows) {
      final isClosed = schedule.every((item) => item.isPaid);
      await _firestoreService.windowsStream!.updateDocument('loans/${loan.id}', {
        'schedule': schedule.map((item) => item.toMap()).toList(),
        'status': isClosed ? 'closed' : 'active',
      });
      return;
    }
    final isClosed = schedule.every((item) => item.isPaid);
    await _firestoreService.loans.doc(loan.id).update({
      'schedule': schedule.map((item) => item.toMap()).toList(),
      'status': isClosed ? 'closed' : 'active',
    });
  }
}
