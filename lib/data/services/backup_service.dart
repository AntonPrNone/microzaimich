import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'firestore_service.dart';

class BackupService {
  BackupService({required FirestoreService firestoreService})
    : _firestoreService = firestoreService;

  final FirestoreService _firestoreService;

  Future<String> exportBackupJson() async {
    final users = await _readCollection(_firestoreService.users);
    final loans = await _readCollection(_firestoreService.loans);
    final notifications = await _readCollection(_firestoreService.notifications);
    final appSettings = await _readCollection(
      _firestoreService.appSettings,
      excludeIds: const {'clock'},
    );

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

    await _replaceCollection(
      _firestoreService.users,
      _parseDocuments(collections['users']),
    );
    await _replaceCollection(
      _firestoreService.loans,
      _parseDocuments(collections['loans']),
    );
    await _replaceCollection(
      _firestoreService.notifications,
      _parseDocuments(collections['notifications']),
    );
    await _replaceCollection(
      _firestoreService.appSettings,
      _parseDocuments(collections['app_settings'])
          .where((document) => document.id != 'clock')
          .toList(),
    );
  }

  Future<void> clearAllPreservingAdmin(String adminUserId) async {
    await _clearCollection(_firestoreService.loans);
    await _clearCollection(_firestoreService.notifications);
    await _clearCollection(_firestoreService.appSettings);

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
