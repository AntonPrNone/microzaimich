import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';

import 'windows_firestore_rest_service.dart';

class FirestoreService {
  FirestoreService({FirebaseFirestore? db}) : _db = db ?? FirebaseFirestore.instance {
    if (Platform.isWindows) {
      _db.settings = const Settings(persistenceEnabled: false);
    }
  }

  final FirebaseFirestore _db;
  WindowsFirestoreRestService? get windowsRest =>
      Platform.isWindows ? WindowsFirestoreRestService.instance : null;

  CollectionReference<Map<String, dynamic>> get users => _db.collection('users');

  CollectionReference<Map<String, dynamic>> get loans => _db.collection('loans');

  CollectionReference<Map<String, dynamic>> get notifications =>
      _db.collection('notifications');

  CollectionReference<Map<String, dynamic>> get appSettings =>
      _db.collection('app_settings');

}
