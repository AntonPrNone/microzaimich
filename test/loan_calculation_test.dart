import 'package:flutter_test/flutter_test.dart';
import 'package:microzaimich/data/models/app_clock_settings.dart';
import 'package:microzaimich/data/models/loan.dart';
import 'package:microzaimich/data/models/payment_schedule_item.dart';
import 'package:microzaimich/data/services/app_clock.dart';

void main() {
  tearDown(() {
    AppClock.applySettings(const AppClockSettings.disabled());
  });

  group('Loan calculations', () {
    Loan buildTwoPartLoan({
      required String id,
      required DateTime issuedAt,
      required DateTime firstDueDate,
      required DateTime secondDueDate,
      PaymentScheduleItem? firstItem,
      PaymentScheduleItem? secondItem,
    }) {
      return Loan(
        id: id,
        userId: 'user-$id',
        title: 'Loan $id',
        principal: 1000,
        interestPercent: 10,
        totalAmount: 1100,
        dailyPenaltyAmount: 20,
        issuedAt: issuedAt,
        status: 'active',
        schedule: [
          firstItem ??
              PaymentScheduleItem(
                id: 'p1',
                dueDate: firstDueDate,
                amount: 550,
                isPaid: false,
                penaltyAccrued: 0,
                principalAmount: 500,
                interestAccruedPaid: 0,
              ),
          secondItem ??
              PaymentScheduleItem(
                id: 'p2',
                dueDate: secondDueDate,
                amount: 550,
                isPaid: false,
                penaltyAccrued: 0,
                principalAmount: 500,
                interestAccruedPaid: 0,
              ),
        ],
      );
    }

    test('planned outstanding does not decrease because of paid penalties', () {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 20),
          updatedAt: DateTime.utc(2026, 4, 20),
        ),
      );

      final loan = Loan(
        id: 'loan-1',
        userId: 'user-1',
        title: 'Займ 01.04.2026',
        principal: 1000,
        interestPercent: 10,
        totalAmount: 1100,
        dailyPenaltyAmount: 20,
        issuedAt: DateTime.utc(2026, 4, 1),
        status: 'active',
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 4, 10),
            amount: 550,
            isPaid: true,
            penaltyAccrued: 30,
            principalAmount: 500,
            interestAccruedPaid: 2.48,
            paidAt: DateTime.utc(2026, 4, 10),
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

      final secondItem = loan.orderedSchedule.last;

      expect(loan.paidAmount, 531.83);
      expect(loan.plannedPaidAmount, loan.plannedAmountForItem(loan.orderedSchedule.first));
      expect(
        loan.plannedOutstandingAmount,
        loan.plannedAmountForItem(secondItem) + loan.penaltyOutstanding,
      );
    });

    test('next installment amount stays fixed by plan before due date', () {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 6),
          updatedAt: DateTime.utc(2026, 4, 6),
        ),
      );

      final loan = Loan(
        id: 'loan-2',
        userId: 'user-2',
        title: 'Займ 01.04.2026',
        principal: 1000,
        interestPercent: 10,
        totalAmount: 1100,
        dailyPenaltyAmount: 20,
        issuedAt: DateTime.utc(2026, 4, 1),
        status: 'active',
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 4, 11),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 4, 21),
            amount: 550,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 500,
            interestAccruedPaid: 0,
          ),
        ],
      );

      final firstItem = loan.orderedSchedule.first;

      expect(loan.interestOutstanding, 1.37);
      expect(loan.nextInstallmentAmount, loan.plannedAmountForItem(firstItem));
    });

    test('planned outstanding includes accrued unpaid penalty', () {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );

      final loan = Loan(
        id: 'loan-3',
        userId: 'user-3',
        title: 'Р—Р°Р№Рј 01.04.2026',
        principal: 1000,
        interestPercent: 10,
        totalAmount: 1100,
        dailyPenaltyAmount: 20,
        issuedAt: DateTime.utc(2026, 4, 1),
        status: 'active',
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

      expect(loan.penaltyOutstanding, 60);
      expect(
        loan.plannedOutstandingAmount,
        closeTo(loan.plannedTotalAmount + loan.penaltyOutstanding, 0.001),
      );
    });

    test('interest stops growing while payment is overdue', () {
      final issuedAt = DateTime.utc(2026, 4, 1);
      final firstDueDate = DateTime.utc(2026, 4, 10);
      final secondDueDate = DateTime.utc(2026, 4, 20);

      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 11),
          updatedAt: DateTime.utc(2026, 4, 11),
        ),
      );
      final loanAtFirstOverdueDay = buildTwoPartLoan(
        id: 'loan-4',
        issuedAt: issuedAt,
        firstDueDate: firstDueDate,
        secondDueDate: secondDueDate,
      );
      final interestAtFirstOverdueDay = loanAtFirstOverdueDay.interestOutstanding;

      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );
      final loanAfterSeveralOverdueDays = buildTwoPartLoan(
        id: 'loan-4b',
        issuedAt: issuedAt,
        firstDueDate: firstDueDate,
        secondDueDate: secondDueDate,
      );

      expect(loanAfterSeveralOverdueDays.interestOutstanding, interestAtFirstOverdueDay);
      expect(loanAfterSeveralOverdueDays.penaltyOutstanding, 60);
    });

    test('interest resumes after overdue payment is settled', () {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 15),
          updatedAt: DateTime.utc(2026, 4, 15),
        ),
      );

      final loan = buildTwoPartLoan(
        id: 'loan-5',
        issuedAt: DateTime.utc(2026, 4, 1),
        firstDueDate: DateTime.utc(2026, 4, 10),
        secondDueDate: DateTime.utc(2026, 4, 20),
        firstItem: PaymentScheduleItem(
          id: 'p1',
          dueDate: DateTime.utc(2026, 4, 10),
          amount: 550,
          isPaid: true,
          penaltyAccrued: 40,
          principalAmount: 500,
          interestAccruedPaid: 2.48,
          paidAt: DateTime.utc(2026, 4, 13),
        ),
      );

      expect(loan.penaltyOutstanding, 0);
      expect(loan.interestOutstanding, 0.4);
      expect(loan.fullCloseAmount, 501.05);
    });

    test('full close before due date excludes future interest', () {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 6),
          updatedAt: DateTime.utc(2026, 4, 6),
        ),
      );

      final loan = buildTwoPartLoan(
        id: 'loan-6',
        issuedAt: DateTime.utc(2026, 4, 1),
        firstDueDate: DateTime.utc(2026, 4, 11),
        secondDueDate: DateTime.utc(2026, 4, 21),
      );

      expect(loan.interestOutstanding, 1.37);
      expect(loan.penaltyOutstanding, 0);
      expect(loan.fullCloseAmount, 1001.37);
      expect(loan.fullCloseAmount, lessThan(loan.totalAmount));
    });

    test('next installment amount adds only penalty on top of planned payment', () {
      AppClock.applySettings(
        AppClockSettings(
          debugEnabled: true,
          debugNow: DateTime.utc(2026, 4, 13),
          updatedAt: DateTime.utc(2026, 4, 13),
        ),
      );

      final loan = buildTwoPartLoan(
        id: 'loan-7',
        issuedAt: DateTime.utc(2026, 4, 1),
        firstDueDate: DateTime.utc(2026, 4, 10),
        secondDueDate: DateTime.utc(2026, 4, 20),
      );

      final firstItem = loan.orderedSchedule.first;

      expect(loan.interestOutstanding, 2.48);
      expect(loan.penaltyOutstanding, 60);
      expect(
        loan.nextInstallmentAmount,
        loan.plannedAmountForItem(firstItem) + loan.penaltyOutstanding,
      );
    });

    test('planned outstanding is zero for fully closed loan', () {
      final loan = buildTwoPartLoan(
        id: 'loan-8b',
        issuedAt: DateTime.utc(2026, 4, 1),
        firstDueDate: DateTime.utc(2026, 4, 10),
        secondDueDate: DateTime.utc(2026, 4, 20),
        firstItem: PaymentScheduleItem(
          id: 'p1',
          dueDate: DateTime.utc(2026, 4, 10),
          amount: 0,
          isPaid: true,
          penaltyAccrued: 0,
          principalAmount: 500,
          interestAccruedPaid: 2.61,
          paidAt: DateTime.utc(2026, 4, 10),
        ),
        secondItem: PaymentScheduleItem(
          id: 'p2',
          dueDate: DateTime.utc(2026, 4, 20),
          amount: 0,
          isPaid: true,
          penaltyAccrued: 0,
          principalAmount: 500,
          interestAccruedPaid: 1.32,
          paidAt: DateTime.utc(2026, 4, 20),
        ),
      ).copyWith(status: 'closed');

      expect(loan.plannedOutstandingAmount, 0);
    });

    test('planned interest decreases as principal balance goes down', () {
      final loan = buildTwoPartLoan(
        id: 'loan-8',
        issuedAt: DateTime.utc(2026, 4, 1),
        firstDueDate: DateTime.utc(2026, 4, 10),
        secondDueDate: DateTime.utc(2026, 4, 20),
      );

      final firstItem = loan.orderedSchedule.first;
      final secondItem = loan.orderedSchedule.last;

      expect(loan.plannedInterestForItem(firstItem), 2.61);
      expect(loan.plannedInterestForItem(secondItem), 1.32);
      expect(
        loan.plannedInterestForItem(firstItem),
        greaterThan(loan.plannedInterestForItem(secondItem)),
      );
    });

    test('all planned payments except last stay equal after rounding', () {
      final issuedAt = DateTime.utc(2026, 5, 2);
      final schedule = List.generate(
        6,
        (index) => PaymentScheduleItem(
          id: 'p$index',
          dueDate: DateTime.utc(2026, 6 + index, 2),
          amount: 0,
          isPaid: false,
          penaltyAccrued: 0,
          principalAmount: 0,
          interestAccruedPaid: 0,
        ),
      );

      final loan = Loan(
        id: 'loan-9',
        userId: 'user-9',
        title: 'Loan 9',
        principal: 5000,
        interestPercent: 15,
        totalAmount: 0,
        dailyPenaltyAmount: 20,
        issuedAt: issuedAt,
        status: 'active',
        schedule: schedule,
      );

      final totals = loan.orderedSchedule
          .map(
            (item) => loan.principalAmountForItem(item) + loan.plannedInterestForItem(item),
          )
          .toList();

      expect(totals.take(5).toSet().length, 1);
      expect((totals.last - totals.first).abs(), lessThanOrEqualTo(0.01));
    });

    test('planned total matches displayed payment sum without extra cent', () {
      final loan = Loan(
        id: 'loan-10',
        userId: 'user-10',
        title: 'Loan 10',
        principal: 5000,
        interestPercent: 10,
        totalAmount: 0,
        dailyPenaltyAmount: 20,
        issuedAt: DateTime.utc(2026, 5, 2),
        status: 'active',
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 6, 2),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 7, 2),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p3',
            dueDate: DateTime.utc(2026, 8, 2),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p4',
            dueDate: DateTime.utc(2026, 9, 2),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p5',
            dueDate: DateTime.utc(2026, 10, 2),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p6',
            dueDate: DateTime.utc(2026, 11, 2),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
        ],
      );

      final displayedSum = loan.orderedSchedule.fold<double>(
        0,
        (sum, item) => sum + loan.plannedAmountForItem(item),
      );

      expect(displayedSum, 5148.06);
      expect(loan.plannedTotalAmount, displayedSum);
    });

    test('first monthly payment includes planned interest', () {
      final loan = Loan(
        id: 'loan-11',
        userId: 'user-11',
        title: 'Loan 11',
        principal: 5000,
        interestPercent: 10,
        totalAmount: 0,
        dailyPenaltyAmount: 20,
        issuedAt: DateTime.utc(2026, 5, 5),
        status: 'active',
        paymentIntervalCount: 1,
        paymentIntervalUnit: 'months',
        schedule: [
          PaymentScheduleItem(
            id: 'p1',
            dueDate: DateTime.utc(2026, 6, 5),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p2',
            dueDate: DateTime.utc(2026, 7, 5),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p3',
            dueDate: DateTime.utc(2026, 8, 5),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p4',
            dueDate: DateTime.utc(2026, 9, 5),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p5',
            dueDate: DateTime.utc(2026, 10, 5),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
          PaymentScheduleItem(
            id: 'p6',
            dueDate: DateTime.utc(2026, 11, 5),
            amount: 0,
            isPaid: false,
            penaltyAccrued: 0,
            principalAmount: 0,
            interestAccruedPaid: 0,
          ),
        ],
      );

      final firstItem = loan.orderedSchedule.first;
      expect(loan.plannedInterestForItem(firstItem), greaterThan(0));
      expect(loan.amountForItem(firstItem), loan.plannedAmountForItem(firstItem));
    });
  });
}
