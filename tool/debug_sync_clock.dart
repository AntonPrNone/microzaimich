import 'package:microzaimich/data/services/firestore_service.dart';
import 'package:microzaimich/data/services/app_clock.dart';
Future<void> main() async {
  final fs = FirestoreService();
  print('before syncServerTime');
  await AppClock.syncServerTime(fs);
  print('after syncServerTime');
}
