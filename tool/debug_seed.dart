import 'dart:io';

import 'package:microzaimich/data/repositories/auth_repository.dart';
import 'package:microzaimich/data/repositories/loan_repository.dart';
import 'package:microzaimich/data/repositories/notification_repository.dart';
import 'package:microzaimich/data/services/bootstrap_service.dart';
import 'package:microzaimich/data/services/firestore_service.dart';
import 'package:microzaimich/data/services/session_service.dart';

Future<void> main() async {
  final firestoreService = FirestoreService();
  final authRepository = AuthRepository(firestoreService: firestoreService);
  final notificationRepository = NotificationRepository(
    firestoreService: firestoreService,
  );
  final loanRepository = LoanRepository(
    firestoreService: firestoreService,
    notificationRepository: notificationRepository,
  );
  final bootstrapService = BootstrapService(
    authRepository: authRepository,
    loanRepository: loanRepository,
    sessionService: SessionService(),
  );

  stdout.writeln('before seedIfNeeded');
  await bootstrapService.seedIfNeeded();
  stdout.writeln('after seedIfNeeded');
}
