import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microzaimich/data/models/app_notification.dart';
import 'package:microzaimich/data/models/app_clock_settings.dart';
import 'package:microzaimich/data/models/loan.dart';
import 'package:microzaimich/data/models/payment_request.dart';
import 'package:microzaimich/data/models/payment_schedule_item.dart';
import 'package:microzaimich/data/repositories/notification_repository.dart';
import 'package:microzaimich/data/repositories/payment_request_repository.dart';
import 'package:microzaimich/data/services/app_clock.dart';
import 'package:microzaimich/data/services/firestore_service.dart';

void main() {
  tearDown(() {
    AppClock.applySettings(const AppClockSettings.disabled());
  });

  group('PaymentRequestRepository', () {
    late FakeFirebaseFirestore firestore;
    late FirestoreService firestoreService;
    late NotificationRepository notificationRepository;
    late PaymentRequestRepository paymentRequestRepository;

    setUp(() async {
      firestore = FakeFirebaseFirestore();
      firestoreService = FirestoreService(db: firestore);
      notificationRepository = NotificationRepository(
        firestoreService: firestoreService,
      );
      paymentRequestRepository = PaymentRequestRepository(
        firestoreService: firestoreService,
        notificationRepository: notificationRepository,
      );

      await firestore.collection('users').doc('admin-1').set({
        'name': 'Admin',
        'phone': '79990000000',
        'role': 'admin',
      });
      await firestore.collection('users').doc('user-1').set({
        'name': 'Нием',
        'phone': '78888888888',
        'role': 'client',
      });
    });

    Loan buildLoan({
      required List<PaymentScheduleItem> schedule,
      String status = 'active',
    }) {
      return Loan(
        id: 'loan-1',
        userId: 'user-1',
        title: 'Займ 01.04.2026',
        principal: 1000,
        interestPercent: 10,
        totalAmount: 1100,
        dailyPenaltyAmount: 20,
        issuedAt: DateTime.utc(2026, 4, 1),
        schedule: schedule,
        status: status,
      );
    }

    test('createNextInstallmentRequest stores snapshot and admin notification', () async {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );

      final loan = buildLoan(
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 4, 10),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 4, 20),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
        ],
      );

      await paymentRequestRepository.createNextInstallmentRequest(loan);

      final requestDocs = await firestore.collection('payment_requests').get();
      expect(requestDocs.docs, hasLength(1));
      final request = PaymentRequest.fromDoc(requestDocs.docs.single);
      expect(request.type, PaymentRequestType.nextInstallment);
      expect(request.principalAmount, 500);
      expect(request.interestAmount, 47.37);
      expect(request.penaltyAmount, 60);
      expect(request.requestedAmount, 607.37);

      final adminNotifications = await firestore
          .collection('notifications')
          .where('userId', isEqualTo: 'admin-1')
          .get();
      expect(adminNotifications.docs, hasLength(1));

    });

    test('approve next installment marks item paid and request approved', () async {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );

      final loan = buildLoan(
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 4, 10),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 4, 20),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
        ],
      );
      await firestore.collection('loans').doc(loan.id).set(loan.toMap());
      await paymentRequestRepository.createNextInstallmentRequest(loan);

      final requestDoc = (await firestore.collection('payment_requests').get()).docs.single;
      final request = PaymentRequest.fromDoc(requestDoc);

      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 14),
          updatedAt: DateTime.utc(2026, 4, 14),
        ),
      );

      await paymentRequestRepository.approveRequest(request: request, loan: loan);

      final updatedLoanDoc = await firestore.collection('loans').doc(loan.id).get();
      final updatedLoan = Loan.fromDoc(updatedLoanDoc);
      final firstItem = updatedLoan.orderedSchedule.first;
      expect(firstItem.isPaid, isTrue);
      expect(firstItem.penaltyAccrued, 60);
      expect(firstItem.interestAccruedPaid, 47.37);

      final updatedRequestDoc = await firestore
          .collection('payment_requests')
          .doc(request.id)
          .get();
      expect(updatedRequestDoc.data()!['status'], PaymentRequestStatus.approved.name);
    });

    test('approve full close closes remaining schedule', () async {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );

      final loan = buildLoan(
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 4, 10),
            amount: 550,
            isPaid: true,
            penaltyAccrued: 20,
            principalAmount: 500,
            interestAccruedPaid: 31.58,
            paidAt: DateTime.utc(2026, 4, 11),
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 4, 20),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
        ],
      );
      await firestore.collection('loans').doc(loan.id).set(loan.toMap());

      await paymentRequestRepository.createFullCloseRequest(loan);
      final requestDoc = (await firestore.collection('payment_requests').get()).docs.single;
      final request = PaymentRequest.fromDoc(requestDoc);

      await paymentRequestRepository.approveRequest(request: request, loan: loan);

      final updatedLoanDoc = await firestore.collection('loans').doc(loan.id).get();
      expect(updatedLoanDoc.data()!['status'], 'closed');

    });

    test('full request lifecycle keeps loan data and events consistent', () async {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );

      final loan = buildLoan(
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 4, 10),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 4, 20),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
        ],
      );
      await firestore.collection('loans').doc(loan.id).set(loan.toMap());

      await paymentRequestRepository.createNextInstallmentRequest(loan);
      final firstRequest = PaymentRequest.fromDoc(
        (await firestore.collection('payment_requests').get()).docs.single,
      );
      await paymentRequestRepository.approveRequest(
        request: firstRequest,
        loan: loan,
      );

      final afterFirstPayment = Loan.fromDoc(
        await firestore.collection('loans').doc(loan.id).get(),
      );
      expect(afterFirstPayment.status, 'active');
      expect(
        afterFirstPayment.orderedSchedule.where((item) => item.isPaid),
        hasLength(1),
      );

      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 15),
          updatedAt: DateTime.utc(2026, 4, 15),
        ),
      );

      await paymentRequestRepository.createFullCloseRequest(afterFirstPayment);
      final allRequests = await firestore.collection('payment_requests').get();
      final closeRequest = allRequests.docs
          .map(PaymentRequest.fromDoc)
          .firstWhere((request) => request.type == PaymentRequestType.fullClose);
      await paymentRequestRepository.approveRequest(
        request: closeRequest,
        loan: afterFirstPayment,
      );

      final closedLoan = Loan.fromDoc(
        await firestore.collection('loans').doc(loan.id).get(),
      );
      expect(closedLoan.status, 'closed');
      expect(closedLoan.orderedSchedule.every((item) => item.isPaid), isTrue);

    });

    test('reject request keeps loan active and notifies user', () async {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );

      final loan = buildLoan(
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 4, 10),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 4, 20),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
        ],
      );
      await firestore.collection('loans').doc(loan.id).set(loan.toMap());
      await paymentRequestRepository.createNextInstallmentRequest(loan);

      final request = PaymentRequest.fromDoc(
        (await firestore.collection('payment_requests').get()).docs.single,
      );
      await paymentRequestRepository.rejectRequest(request);

      final requestDoc = await firestore
          .collection('payment_requests')
          .doc(request.id)
          .get();
      expect(requestDoc.data()!['status'], PaymentRequestStatus.rejected.name);

      final loanDoc = await firestore.collection('loans').doc(loan.id).get();
      expect(loanDoc.data()!['status'], 'active');

      final userNotifications = await firestore
          .collection('notifications')
          .where('userId', isEqualTo: 'user-1')
          .get();
      expect(
        userNotifications.docs.any(
          (doc) =>
              (doc.data()['type'] as String? ?? '') ==
              AppNotificationType.paymentRejected.name,
        ),
        isTrue,
      );
    });
  });
}
