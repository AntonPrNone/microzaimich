import 'package:microzaimich/data/services/firestore_service.dart';
import 'package:microzaimich/data/repositories/auth_repository.dart';
import 'package:microzaimich/data/repositories/notification_repository.dart';
import 'package:microzaimich/data/repositories/loan_repository.dart';
import 'package:microzaimich/data/services/session_service.dart';
import 'package:microzaimich/data/services/bootstrap_service.dart';
Future<void> main() async {
  final fs = FirestoreService();
  final auth = AuthRepository(firestoreService: fs);
  final notif = NotificationRepository(firestoreService: fs);
  final loans = LoanRepository(firestoreService: fs, notificationRepository: notif);
  final boot = BootstrapService(authRepository: auth, loanRepository: loans, sessionService: SessionService());
  print('before seedIfNeeded');
  await boot.seedIfNeeded();
  print('after seedIfNeeded');
}
