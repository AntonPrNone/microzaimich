import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:microzaimich/data/models/app_notification.dart';
import 'package:microzaimich/data/models/app_user.dart';
import 'package:microzaimich/data/models/loan.dart';
import 'package:microzaimich/data/models/loan_defaults_settings.dart';
import 'package:microzaimich/data/models/payment_schedule_item.dart';
import 'package:microzaimich/data/models/payment_settings.dart';
import 'package:microzaimich/data/models/user_role.dart';
import 'package:microzaimich/data/services/backup_service.dart';
import 'package:microzaimich/data/services/firestore_service.dart';

void main() {
  group('BackupService', () {
    test('exports only current collections and excludes app_settings/clock', () async {
      final fake = FakeFirebaseFirestore();
      final service = BackupService(
        firestoreService: FirestoreService(db: fake),
      );

      final issuedAt = DateTime.utc(2026, 1, 10, 9);
      final dueAt = DateTime.utc(2026, 2, 10, 9);
      final paidAt = DateTime.utc(2026, 2, 8, 10);

      final user = AppUser(
        id: 'user-1',
        name: 'Тестовый клиент',
        phone: '79990000000',
        role: UserRole.client,
        password: '1234',
        reminderHour: 10,
        reminderMinute: 0,
        createdAt: DateTime.utc(2026, 1, 1, 12),
      );
      await fake.collection('users').doc(user.id).set(user.toMap());

      final loan = Loan(
        id: 'loan-1',
        userId: user.id,
        title: 'Займ 10.01.2026',
        principal: 5000,
        interestPercent: 10.125,
        totalAmount: 5148.06,
        dailyPenaltyAmount: 50,
        issuedAt: issuedAt,
        status: 'active',
        paymentIntervalCount: 1,
        paymentIntervalUnit: 'months',
        note: 'Архивный тест',
        schedule: [
          PaymentScheduleItem(
            id: 'payment-1',
            dueDate: dueAt,
            amount: 858.01,
            isPaid: true,
            penaltyAccrued: 0,
            principalAmount: 824.76,
            interestAccruedPaid: 20.67,
            paidAt: paidAt,
          ),
          PaymentScheduleItem(
            id: 'payment-2',
            dueDate: DateTime.utc(2026, 3, 10, 9),
            amount: 858.01,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 828.17,
            interestAccruedPaid: 0,
          ),
        ],
      );
      await fake.collection('loans').doc(loan.id).set(loan.toMap());

      final notification = AppNotification(
        id: 'notification-1',
        userId: user.id,
        title: 'Платёж отмечен',
        body: 'Администратор отметил платёж',
        type: AppNotificationType.paymentApproved,
        createdAt: DateTime.utc(2026, 2, 8, 10),
        readAt: DateTime.utc(2026, 2, 8, 11),
      );
      await fake
          .collection('notifications')
          .doc(notification.id)
          .set(notification.toMap());

      final paymentSettings = PaymentSettings(
        bankName: 'Т-Банк',
        recipientName: 'Администратор',
        recipientPhone: '79991112233',
        paymentLink: 'https://example.com/pay',
        adminDueReminderHour: 18,
        adminDueReminderMinute: 15,
        updatedAt: DateTime.utc(2026, 2, 1, 8),
      );
      await fake
          .collection('app_settings')
          .doc('payment')
          .set(paymentSettings.toMap());

      final defaults = LoanDefaultsSettings(
        principal: 10000,
        interestPercent: 12.5,
        dailyPenaltyAmount: 100,
        paymentCount: 6,
        paymentIntervalCount: 1,
        paymentIntervalUnit: 'months',
        updatedAt: DateTime.utc(2026, 2, 1, 9),
      );
      await fake
          .collection('app_settings')
          .doc('loan_defaults')
          .set(defaults.toMap());

      await fake.collection('app_settings').doc('clock').set({
        'debugEnabled': true,
        'debugNow': Timestamp.fromDate(DateTime.utc(2026, 5, 1, 12)),
      });

      final jsonString = await service.exportBackupJson();
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      final collections = decoded['collections'] as Map<String, dynamic>;

      expect(collections.keys.toSet(), {
        'users',
        'loans',
        'notifications',
        'app_settings',
      });

      final appSettingsDocs = collections['app_settings'] as List<dynamic>;
      expect(
        appSettingsDocs.map((doc) => (doc as Map<String, dynamic>)['id']).toSet(),
        {'payment', 'loan_defaults'},
      );

      final exportedLoanDoc = (collections['loans'] as List<dynamic>).single as Map<String, dynamic>;
      final exportedLoanData = exportedLoanDoc['data'] as Map<String, dynamic>;
      expect(exportedLoanData['paymentIntervalCount'], 1);
      expect(exportedLoanData['paymentIntervalUnit'], 'months');
      expect(exportedLoanData['note'], 'Архивный тест');
      expect((exportedLoanData['schedule'] as List).length, 2);
    });

    test('imports backup back into current collections with current fields', () async {
      final sourceDb = FakeFirebaseFirestore();
      final sourceService = BackupService(
        firestoreService: FirestoreService(db: sourceDb),
      );

      await sourceDb.collection('users').doc('user-1').set({
        'name': 'Клиент',
        'phone': '79990000000',
        'role': 'client',
        'password': '1234',
        'reminderHour': 10,
        'reminderMinute': 0,
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1, 12)),
      });
      await sourceDb.collection('loans').doc('loan-1').set({
        'userId': 'user-1',
        'title': 'Займ 01.01.2026',
        'principal': 5000,
        'interestPercent': 10.125,
        'totalAmount': 5148.06,
        'dailyPenaltyAmount': 50,
        'issuedAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1, 12)),
        'status': 'active',
        'paymentIntervalCount': 1,
        'paymentIntervalUnit': 'months',
        'note': 'Тест импорта',
        'schedule': [
          {
            'id': 'payment-1',
            'dueDate': '2026-02-01T12:00:00.000Z',
            'amount': 858.01,
            'isPaid': true,
            'penaltyAccrued': 0,
            'principalAmount': 824.76,
            'interestAccruedPaid': 20.67,
            'paidAt': '2026-01-31T09:00:00.000Z',
          },
        ],
      });
      await sourceDb.collection('notifications').doc('notification-1').set({
        'userId': 'user-1',
        'title': 'Платёж отмечен',
        'body': 'Администратор отметил платёж',
        'type': 'paymentApproved',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 2, 1, 10)),
        'readAt': null,
      });
      await sourceDb.collection('app_settings').doc('payment').set({
        'bankName': 'Т-Банк',
        'recipientName': 'Админ',
        'recipientPhone': '79991112233',
        'paymentLink': 'https://example.com/pay',
        'adminDueReminderHour': 18,
        'adminDueReminderMinute': 0,
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 2, 1, 8)),
      });
      await sourceDb.collection('app_settings').doc('loan_defaults').set({
        'principal': 10000,
        'interestPercent': 12.5,
        'dailyPenaltyAmount': 100,
        'paymentCount': 6,
        'paymentIntervalCount': 1,
        'paymentIntervalUnit': 'months',
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 2, 1, 9)),
      });

      final backupJson = await sourceService.exportBackupJson();

      final targetDb = FakeFirebaseFirestore();
      final targetService = BackupService(
        firestoreService: FirestoreService(db: targetDb),
      );

      await targetDb.collection('users').doc('stale-user').set({
        'name': 'Старый',
        'phone': '70000000000',
        'role': 'client',
        'reminderHour': 12,
        'reminderMinute': 30,
      });
      await targetDb.collection('app_settings').doc('clock').set({
        'debugEnabled': true,
      });

      await targetService.importBackupJson(backupJson);

      final users = await targetDb.collection('users').get();
      final loans = await targetDb.collection('loans').get();
      final notifications = await targetDb.collection('notifications').get();
      final paymentDoc = await targetDb.collection('app_settings').doc('payment').get();
      final defaultsDoc = await targetDb.collection('app_settings').doc('loan_defaults').get();
      final clockDoc = await targetDb.collection('app_settings').doc('clock').get();

      expect(users.docs.map((doc) => doc.id).toList(), ['user-1']);
      expect(loans.docs.map((doc) => doc.id).toList(), ['loan-1']);
      expect(notifications.docs.map((doc) => doc.id).toList(), ['notification-1']);

      final importedLoan = loans.docs.single.data();
      expect(importedLoan['paymentIntervalCount'], 1);
      expect(importedLoan['paymentIntervalUnit'], 'months');
      expect(importedLoan['note'], 'Тест импорта');
      expect((importedLoan['schedule'] as List).single['id'], 'payment-1');

      expect(paymentDoc.exists, isTrue);
      expect(defaultsDoc.exists, isTrue);
      expect(clockDoc.exists, isFalse);
    });
  });
}
