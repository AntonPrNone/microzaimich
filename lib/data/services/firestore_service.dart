import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/utils/platform_utils.dart';
import 'windows_firestore_stream_service.dart';

class FirestoreService {
  FirestoreService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance {
    if (AppPlatform.isWindows) {
      _db.settings = const Settings(persistenceEnabled: false);
    }
  }

  final FirebaseFirestore _db;
  WindowsFirestoreStreamService? get windowsStream =>
      AppPlatform.isWindows ? WindowsFirestoreStreamService.instance : null;

  CollectionReference<Map<String, dynamic>> get users => _db.collection('users');

  CollectionReference<Map<String, dynamic>> get loans => _db.collection('loans');

  CollectionReference<Map<String, dynamic>> get notifications =>
      _db.collection('notifications');

  CollectionReference<Map<String, dynamic>> get appSettings =>
      _db.collection('app_settings');

  CollectionReference<Map<String, dynamic>> get telegramDeliveries =>
      _db.collection('telegram_deliveries');

  CollectionReference<Map<String, dynamic>> get serviceState =>
      _db.collection('_service_state');

}
