import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/utils/platform_utils.dart';
import 'firestore_service.dart';

class BackupService {
  BackupService({required FirestoreService firestoreService})
    : _firestoreService = firestoreService;

  final FirestoreService _firestoreService;

  Future<String> exportBackupJson() async {
    final users = AppPlatform.isWindows
        ? await _readWindowsCollection('users')
        : await _readCollection(_firestoreService.users);
    final loans = AppPlatform.isWindows
        ? await _readWindowsCollection('loans')
        : await _readCollection(_firestoreService.loans);
    final notifications = AppPlatform.isWindows
        ? await _readWindowsCollection('notifications')
        : await _readCollection(_firestoreService.notifications);
    final appSettings = AppPlatform.isWindows
        ? await _readWindowsCollection('app_settings', excludeIds: const {'clock'})
        : await _readCollection(
            _firestoreService.appSettings,
            excludeIds: const {'clock'},
          );
    final telegramDeliveries = AppPlatform.isWindows
        ? await _readWindowsCollection('telegram_deliveries')
        : await _readCollection(_firestoreService.telegramDeliveries);
    final serviceState = AppPlatform.isWindows
        ? await _readWindowsCollection('_service_state')
        : await _readCollection(_firestoreService.serviceState);

    final payload = <String, dynamic>{
      'meta': {
        'app': 'microzaimich',
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'version': 1,
      },
      'collections': {
        'users': users,
        'loans': loans,
        'notifications': notifications,
        'app_settings': appSettings,
        'telegram_deliveries': telegramDeliveries,
        '_service_state': serviceState,
      },
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> importBackupJson(String jsonString) async {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, dynamic>) {
      throw const BackupException('Файл резервной копии повреждён');
    }

    final collections = decoded['collections'];
    if (collections is! Map<String, dynamic>) {
      throw const BackupException('В файле нет данных коллекций');
    }

    final users = _parseDocuments(collections['users']);
    final loans = _parseDocuments(collections['loans']);
    final notifications = _parseDocuments(collections['notifications']);
    final appSettings = _parseDocuments(collections['app_settings'])
        .where((document) => document.id != 'clock')
        .toList();
    final telegramDeliveries = _parseDocuments(collections['telegram_deliveries']);
    final serviceState = _parseDocuments(collections['_service_state']);

    if (AppPlatform.isWindows) {
      await _replaceWindowsCollection('users', users);
      await _replaceWindowsCollection('loans', loans);
      await _replaceWindowsCollection('notifications', notifications);
      await _replaceWindowsCollection('app_settings', appSettings);
      await _replaceWindowsCollection('telegram_deliveries', telegramDeliveries);
      await _replaceWindowsCollection('_service_state', serviceState);
      return;
    }

    await _replaceCollection(_firestoreService.users, users);
    await _replaceCollection(_firestoreService.loans, loans);
    await _replaceCollection(_firestoreService.notifications, notifications);
    await _replaceCollection(_firestoreService.appSettings, appSettings);
    await _replaceCollection(
      _firestoreService.telegramDeliveries,
      telegramDeliveries,
    );
    await _replaceCollection(_firestoreService.serviceState, serviceState);
  }

  Future<void> clearAllPreservingAdmin(String adminUserId) async {
    if (AppPlatform.isWindows) {
      await _clearWindowsCollection('loans');
      await _clearWindowsCollection('notifications');
      await _clearWindowsCollection('app_settings');
      await _clearWindowsCollection('telegram_deliveries');
      await _clearWindowsCollection('_service_state');

      final users = await _firestoreService.windowsStream!.listDocuments('users');
      for (final doc in users) {
        if (doc.id == adminUserId) {
          continue;
        }
        await _firestoreService.windowsStream!.deleteDocument('users/${doc.id}');
      }
      return;
    }

    await _clearCollection(_firestoreService.loans);
    await _clearCollection(_firestoreService.notifications);
    await _clearCollection(_firestoreService.appSettings);
    await _clearCollection(_firestoreService.telegramDeliveries);
    await _clearCollection(_firestoreService.serviceState);

    final usersSnapshot = await _firestoreService.users.get();
    final firestore = _firestoreService.users.firestore;
    WriteBatch batch = firestore.batch();
    var operationCount = 0;

    for (final doc in usersSnapshot.docs) {
      if (doc.id == adminUserId) {
        continue;
      }
      batch.delete(doc.reference);
      operationCount += 1;

      if (operationCount >= 400) {
        await batch.commit();
        batch = firestore.batch();
        operationCount = 0;
      }
    }

    if (operationCount > 0) {
      await batch.commit();
    }
  }

  Future<List<Map<String, dynamic>>> _readCollection(CollectionReference<Map<String, dynamic>> collection, {Set<String>? excludeIds}) async {
    final excluded = excludeIds ?? const <String>{};
    final snapshot = await collection.get();
    return snapshot.docs
        .where((doc) => !excluded.contains(doc.id))
        .map(
          (doc) => <String, dynamic>{
            'id': doc.id,
            'data': _encodeValue(doc.data()),
          },
        )
        .toList();
  }

  Future<List<Map<String, dynamic>>> _readWindowsCollection(
    String collectionPath, {
    Set<String>? excludeIds,
  }) async {
    final excluded = excludeIds ?? const <String>{};
    final docs = await _firestoreService.windowsStream!.listDocuments(collectionPath);
    return docs
        .where((doc) => !excluded.contains(doc.id))
        .map(
          (doc) => <String, dynamic>{
            'id': doc.id,
            'data': _encodeValue(doc.data),
          },
        )
        .toList();
  }

  List<_BackupDocument> _parseDocuments(dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    return raw.whereType<Map>().map((item) {
      final id = item['id'];
      final data = item['data'];
      if (id is! String || data is! Map) {
        throw const BackupException('Файл резервной копии содержит неверные документы');
      }
      return _BackupDocument(
        id: id,
        data: Map<String, dynamic>.from(
          _decodeValue(Map<String, dynamic>.from(data)) as Map,
        ),
      );
    }).toList();
  }

  Future<void> _replaceCollection(
    CollectionReference<Map<String, dynamic>> collection,
    List<_BackupDocument> documents,
  ) async {
    await _clearCollection(collection);
    if (documents.isEmpty) {
      return;
    }

    final firestore = collection.firestore;
    WriteBatch batch = firestore.batch();
    var operationCount = 0;

    for (final document in documents) {
      batch.set(collection.doc(document.id), document.data);
      operationCount += 1;

      if (operationCount >= 400) {
        await batch.commit();
        batch = firestore.batch();
        operationCount = 0;
      }
    }

    if (operationCount > 0) {
      await batch.commit();
    }
  }

  Future<void> _replaceWindowsCollection(
    String collectionPath,
    List<_BackupDocument> documents,
  ) async {
    await _clearWindowsCollection(collectionPath);
    for (final document in documents) {
      await _firestoreService.windowsStream!.setDocument(
        '$collectionPath/${document.id}',
        document.data,
      );
    }
  }

  Future<void> _clearCollection(
    CollectionReference<Map<String, dynamic>> collection,
  ) async {
    final firestore = collection.firestore;

    while (true) {
      final snapshot = await collection.limit(400).get();
      if (snapshot.docs.isEmpty) {
        return;
      }

      final batch = firestore.batch();
      for (final doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    }
  }

  Future<void> _clearWindowsCollection(String collectionPath) async {
    final docs = await _firestoreService.windowsStream!.listDocuments(collectionPath);
    for (final doc in docs) {
      await _firestoreService.windowsStream!.deleteDocument('$collectionPath/${doc.id}');
    }
  }

  dynamic _encodeValue(dynamic value) {
    if (value is Timestamp) {
      return {
        '_type': 'timestamp',
        'value': value.toDate().toUtc().toIso8601String(),
      };
    }
    if (value is DateTime) {
      return {
        '_type': 'datetime',
        'value': value.toUtc().toIso8601String(),
      };
    }
    if (value is Map) {
      return value.map(
        (key, nestedValue) =>
            MapEntry(key.toString(), _encodeValue(nestedValue)),
      );
    }
    if (value is List) {
      return value.map(_encodeValue).toList();
    }
    return value;
  }

  dynamic _decodeValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      if (value['_type'] == 'timestamp' || value['_type'] == 'datetime') {
        final raw = value['value'];
        if (raw is! String) {
          throw const BackupException('В файле резервной копии повреждена дата');
        }
        return Timestamp.fromDate(DateTime.parse(raw).toUtc());
      }

      return value.map(
        (key, nestedValue) => MapEntry(key, _decodeValue(nestedValue)),
      );
    }
    if (value is List) {
      return value.map(_decodeValue).toList();
    }
    return value;
  }
}

class _BackupDocument {
  const _BackupDocument({required this.id, required this.data});

  final String id;
  final Map<String, dynamic> data;
}

class BackupException implements Exception {
  const BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
