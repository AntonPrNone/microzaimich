import '../models/payment_schedule_item.dart';
import '../models/user_role.dart';
import '../repositories/auth_repository.dart';
import '../repositories/loan_repository.dart';
import 'app_clock.dart';
import 'session_service.dart';

class BootstrapService {
  BootstrapService({
    required AuthRepository authRepository,
    required LoanRepository loanRepository,
    required SessionService sessionService,
  }) : _authRepository = authRepository,
       _loanRepository = loanRepository,
       _sessionService = sessionService;

  final AuthRepository _authRepository;
  final LoanRepository _loanRepository;
  final SessionService _sessionService;

  Future<void> seedIfNeeded() async {
    final hasAdmin = await _authRepository.hasAnyAdmin();
    if (hasAdmin) {
      return;
    }

    final admin = await _authRepository.createUser(
      name: 'Р“Р»Р°РІРЅС‹Р№ Р°РґРјРёРЅРёСЃС‚СЂР°С‚РѕСЂ',
      phone: '79990000000',
      password: 'admin123',
      role: UserRole.admin,
    );

    final client = await _authRepository.createUser(
      name: 'РђРЅРЅР° РљР»РёРµРЅС‚',
      phone: '79991112233',
      password: 'client123',
      role: UserRole.client,
    );

    final issuedAt = AppClock.now();
    await _loanRepository.createLoan(
      userId: client.id,
      title: 'Р”РµРјРѕ-Р·Р°Р№Рј',
      principal: 30000,
      interestPercent: 20,
      totalAmount: 36000,
      dailyPenaltyAmount: 150,
      issuedAt: AppClock.fromMoscowWallClock(issuedAt),
      note: 'Р”РµРјРѕ-Р·Р°Р№Рј РґР»СЏ РїРµСЂРІРѕРіРѕ Р·Р°РїСѓСЃРєР°.',
      schedule: List.generate(
        6,
        (index) => PaymentScheduleItem(
          id: 'seed-$index',
          dueDate: AppClock.fromMoscowWallClock(
            issuedAt.add(Duration(days: 14 * (index + 1))),
          ),
          amount: 6000,
          isPaid: index == 0,
          penaltyAccrued: 0,
          paidAt: index == 0
              ? AppClock.fromMoscowWallClock(issuedAt.subtract(const Duration(days: 1)))
              : null,
        ),
      ),
    );
    await _sessionService.clear();
    await _authRepository.getUserById(admin.id);
  }
}
