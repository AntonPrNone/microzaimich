import 'dart:io';

import 'package:microzaimich/data/services/app_clock.dart';
import 'package:microzaimich/data/services/firestore_service.dart';

Future<void> main() async {
  final firestoreService = FirestoreService();
  stdout.writeln('before syncServerTime');
  await AppClock.syncServerTime(firestoreService);
  stdout.writeln('after syncServerTime');
}
