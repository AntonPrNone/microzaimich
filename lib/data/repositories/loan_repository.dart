import 'dart:async';
import 'dart:io' show Platform;

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
    if (Platform.isWindows) {
      return Stream.multi((controller) {
        Timer? timer;
        var active = true;

        Future<void> emit() async {
          try {
            final docs = await _firestoreService.windowsRest!.listDocuments('loans');
            final loans = docs
                .map((doc) => Loan.fromMap(doc.id, doc.data))
                .where((loan) => loan.userId == userId)
                .toList()
              ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt));
            if (active) {
              controller.add(loans);
            }
          } catch (error, stackTrace) {
            if (active) {
              controller.addError(error, stackTrace);
            }
          }
        }

        unawaited(emit());
        timer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(emit()),
        );
        controller.onCancel = () {
          active = false;
          timer?.cancel();
        };
      });
    }

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
    if (Platform.isWindows) {
      return Stream.multi((controller) {
        Timer? timer;
        var active = true;

        Future<void> emit() async {
          try {
            final docs = await _firestoreService.windowsRest!.listDocuments('loans');
            final loans = docs.map((doc) => Loan.fromMap(doc.id, doc.data)).toList()
              ..sort((a, b) => b.issuedAt.compareTo(a.issuedAt));
            if (active) {
              controller.add(loans);
            }
          } catch (error, stackTrace) {
            if (active) {
              controller.addError(error, stackTrace);
            }
          }
        }

        unawaited(emit());
        timer = Timer.periodic(
          const Duration(seconds: 2),
          (_) => unawaited(emit()),
        );
        controller.onCancel = () {
          active = false;
          timer?.cancel();
        };
      });
    }

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
    required DateTime issuedAt,
    required List<PaymentScheduleItem> schedule,
    int paymentIntervalCount = 0,
    String paymentIntervalUnit = '',
    String? note,
  }) async {
    if (Platform.isWindows) {
      final created = await _firestoreService.windowsRest!.createDocument('loans', {
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
      });
      final loan = Loan.fromMap(created.id, created.data);
      await _notificationRepository.notifyUser(
        userId: userId,
        title: 'РќР°Р·РЅР°С‡РµРЅ РЅРѕРІС‹Р№ Р·Р°Р№Рј',
        body:
            'Р’Р°Рј РЅР°Р·РЅР°С‡РµРЅ ${loan.displayTitle} РЅР° СЃСѓРјРјСѓ ${Formatters.money(totalAmount)}',
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
        paidAt: settlementStorageDate,
        penaltyAccrued: isSettlementItem ? loan.penaltyForItem(item, at: settlementDate) : 0,
        interestAccruedPaid: isSettlementItem ? loan.interestOutstandingAt(settlementDate) : 0,
      );
    }).toList();
    await _updateLoan(loan, updatedSchedule);
  }

  Future<void> updateLoan(Loan loan) async {
    if (Platform.isWindows) {
      final previousSnapshot =
          await _firestoreService.windowsRest!.getDocument('loans/${loan.id}');
      final previousLoan = previousSnapshot == null
          ? null
          : Loan.fromMap(previousSnapshot.id, previousSnapshot.data);
      final isClosed = loan.schedule.every((item) => item.isPaid);
      await _firestoreService.windowsRest!.updateDocument('loans/${loan.id}', {
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
          title: 'Р—Р°Р№Рј Р·Р°РєСЂС‹С‚',
          body:
              'РђРґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂ РѕС‚РјРµС‚РёР» РїРѕР»РЅРѕРµ РїРѕРіР°С€РµРЅРёРµ РїРѕ Р·Р°Р№РјСѓ ${loan.displayTitle}.',
          type: AppNotificationType.paymentApproved,
        );
        return;
      }

      final paymentDate = newlyPaidItems.last.paidAt;
      await _notificationRepository.notifyUser(
        userId: loan.userId,
        title: 'РџР»Р°С‚С‘Р¶ РѕС‚РјРµС‡РµРЅ РєР°Рє РѕРїР»Р°С‡РµРЅРЅС‹Р№',
        body:
            'РђРґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂ РѕС‚РјРµС‚РёР» РѕРїР»Р°С‚Сѓ РїРѕ Р·Р°Р№РјСѓ ${loan.displayTitle}'
            '${paymentDate == null ? '' : ' РѕС‚ ${Formatters.date(paymentDate)}'}.',
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

    final paymentDate = newlyPaidItems.last.paidAt;
    await _notificationRepository.notifyUser(
      userId: loan.userId,
      title: 'Платёж отмечен как оплаченный',
      body:
          'Администратор отметил оплату по займу ${loan.displayTitle}'
          '${paymentDate == null ? '' : ' от ${Formatters.date(paymentDate)}'}.',
      type: AppNotificationType.paymentApproved,
    );
  }

  Future<void> deleteLoansForUser(String userId) async {
    if (Platform.isWindows) {
      final docs = await _firestoreService.windowsRest!.listDocuments('loans');
      for (final doc in docs.where((doc) => doc.data['userId'] == userId)) {
        await _firestoreService.windowsRest!.deleteDocument('loans/${doc.id}');
      }
      return;
    }

    final snapshot =
        await _firestoreService.loans.where('userId', isEqualTo: userId).get();
    for (final doc in snapshot.docs) {
      await doc.reference.delete();
    }
  }

  Future<void> deleteLoan(String loanId) async {
    if (Platform.isWindows) {
      await _firestoreService.windowsRest!.deleteDocument('loans/$loanId');
      return;
    }
    await _firestoreService.loans.doc(loanId).delete();
  }

  Future<void> _updateLoan(
    Loan loan,
    List<PaymentScheduleItem> schedule,
  ) async {
    if (Platform.isWindows) {
      final isClosed = schedule.every((item) => item.isPaid);
      await _firestoreService.windowsRest!.updateDocument('loans/${loan.id}', {
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
