import 'package:flutter_test/flutter_test.dart';
import 'package:microzaimich/data/models/app_clock_settings.dart';
import 'package:microzaimich/data/models/loan.dart';
import 'package:microzaimich/data/models/payment_schedule_item.dart';
import 'package:microzaimich/data/services/app_clock.dart';
import 'package:microzaimich/core/utils/formatters.dart';

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
            interestAccruedPaid: 50,
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

      expect(loan.paidAmount, 580);
      expect(loan.plannedPaidAmount, 550);
      expect(loan.plannedOutstandingAmount, 550);
    });

    test('next installment amount includes accrued interest on request date', () {
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

      expect(loan.interestOutstanding, 25);
      expect(loan.nextInstallmentAmount, 525);
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
      expect(loan.plannedOutstandingAmount, 1160);
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
          interestAccruedPaid: 47.37,
          paidAt: DateTime.utc(2026, 4, 13),
        ),
      );

      expect(loan.penaltyOutstanding, 0);
      expect(loan.interestOutstanding, 15.79);
      expect(loan.fullCloseAmount, 515.79);
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

      expect(loan.interestOutstanding, 25);
      expect(loan.penaltyOutstanding, 0);
      expect(loan.fullCloseAmount, 1025);
      expect(loan.fullCloseAmount, lessThan(loan.totalAmount));
    });

    test('next installment amount includes principal interest and penalty snapshot', () {
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

      expect(loan.interestOutstanding, 47.37);
      expect(loan.penaltyOutstanding, 60);
      expect(loan.nextInstallmentAmount, Formatters.centsUp(500 + 47.37 + 60));
    });
  });
}
