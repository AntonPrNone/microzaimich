import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../firebase_options.dart';

class WindowsFirestoreRestDocument {
  const WindowsFirestoreRestDocument({
    required this.id,
    required this.path,
    required this.data,
  });

  final String id;
  final String path;
  final Map<String, dynamic> data;
}

class WindowsFirestoreRestService {
  WindowsFirestoreRestService._();

  static final WindowsFirestoreRestService instance =
      WindowsFirestoreRestService._();

  static const Duration defaultCacheTtl = Duration(minutes: 1);

  final HttpClient _httpClient = HttpClient();
  final Map<String, _CollectionWatchState> _watchStates = {};

  String get _projectId => DefaultFirebaseOptions.windows.projectId;
  String get _apiKey => DefaultFirebaseOptions.windows.apiKey;

  Uri _collectionUri(String collectionPath, [Map<String, String>? query]) {
    return Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$_projectId/databases/(default)/documents/$collectionPath',
      <String, String>{
        'key': _apiKey,
        if (query != null) ...query,
      },
    );
  }

  Uri _documentUri(String documentPath, [Map<String, String>? query]) {
    return Uri.https(
      'firestore.googleapis.com',
      '/v1/projects/$_projectId/databases/(default)/documents/$documentPath',
      <String, String>{
        'key': _apiKey,
        if (query != null) ...query,
      },
    );
  }

  Future<List<WindowsFirestoreRestDocument>> listDocuments(
    String collectionPath, {
    bool force = false,
  }) async {
    final state = _watchStates.putIfAbsent(
      collectionPath,
      () => _CollectionWatchState(),
    );
    if (!force &&
        state.documents != null &&
        state.lastFetchedAt != null &&
        DateTime.now().difference(state.lastFetchedAt!) < defaultCacheTtl) {
      return state.documents!;
    }
    if (!force && state.pendingFetch != null) {
      return state.pendingFetch!;
    }

    final future = _fetchDocuments(collectionPath);
    state.pendingFetch = future;
    try {
      final docs = await future;
      _setCollectionData(collectionPath, docs);
      return docs;
    } finally {
      state.pendingFetch = null;
    }
  }

  Future<WindowsFirestoreRestDocument?> getDocument(String documentPath) async {
    final response = await _sendRequest(_documentUri(documentPath));
    if (response.statusCode == HttpStatus.notFound) {
      await response.drain();
      return null;
    }
    final body = await _readJson(response);
    if (body.isEmpty) {
      return null;
    }
    return _decodeDocument(body);
  }

  Future<WindowsFirestoreRestDocument> createDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final response = await _sendRequest(
      _collectionUri(collectionPath),
      method: 'POST',
      body: {'fields': _encodeFields(data)},
    );
    final body = await _readJson(response);
    final document = _decodeDocument(body);
    _upsertCachedDocument(collectionPath, document);
    return document;
  }

  Future<void> setDocument(
    String documentPath,
    Map<String, dynamic> data,
  ) async {
    final response = await _sendRequest(
      _documentUri(documentPath),
      method: 'PATCH',
      body: {'fields': _encodeFields(data)},
    );
    final body = await _readJson(response);
    if (body.isNotEmpty) {
      _upsertCachedDocument(_collectionPathFromDocumentPath(documentPath), _decodeDocument(body));
    }
  }

  Future<void> updateDocument(
    String documentPath,
    Map<String, dynamic> data,
  ) async {
    final response = await _sendRequest(
      _documentUri(documentPath),
      method: 'PATCH',
      body: {'fields': _encodeFields(data)},
    );
    final body = await _readJson(response);
    if (body.isNotEmpty) {
      _upsertCachedDocument(_collectionPathFromDocumentPath(documentPath), _decodeDocument(body));
    } else {
      invalidateCollection(_collectionPathFromDocumentPath(documentPath));
    }
  }

  Future<void> deleteDocument(String documentPath) async {
    final response = await _sendRequest(
      _documentUri(documentPath),
      method: 'DELETE',
    );
    await response.drain();
    _removeCachedDocument(
      _collectionPathFromDocumentPath(documentPath),
      documentPath.split('/').last,
    );
  }

  Stream<List<WindowsFirestoreRestDocument>> watchCollection(
    String collectionPath, {
    Duration? interval,
  }) {
    final state = _watchStates.putIfAbsent(
      collectionPath,
      () => _CollectionWatchState(),
    );
    state.subscriberCount += 1;

    if (state.documents != null) {
      scheduleMicrotask(() {
        if (!state.controller.isClosed) {
          state.controller.add(List<WindowsFirestoreRestDocument>.unmodifiable(state.documents!));
        }
      });
    } else {
      unawaited(listDocuments(collectionPath));
    }

    return state.controller.stream.map(
      (docs) => List<WindowsFirestoreRestDocument>.unmodifiable(docs),
    );
  }

  void releaseWatch(String collectionPath) {
    final state = _watchStates[collectionPath];
    if (state == null) {
      return;
    }
    state.subscriberCount -= 1;
    if (state.subscriberCount > 0) {
      return;
    }
  }

  void invalidateCollection(String collectionPath) {
    final state = _watchStates[collectionPath];
    if (state == null) {
      return;
    }
    state.lastFetchedAt = null;
  }

  Future<List<WindowsFirestoreRestDocument>> _fetchDocuments(
    String collectionPath,
  ) async {
    final response = await _sendRequest(_collectionUri(collectionPath));
    final body = await _readJson(response);
    return (body['documents'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(_decodeDocument)
        .toList();
  }

  void _setCollectionData(
    String collectionPath,
    List<WindowsFirestoreRestDocument> documents,
  ) {
    final state = _watchStates.putIfAbsent(
      collectionPath,
      () => _CollectionWatchState(),
    );
    state.documents = documents;
    state.lastFetchedAt = DateTime.now();
    if (!state.controller.isClosed) {
      state.controller.add(documents);
    }
  }

  void _upsertCachedDocument(
    String collectionPath,
    WindowsFirestoreRestDocument document,
  ) {
    final state = _watchStates.putIfAbsent(
      collectionPath,
      () => _CollectionWatchState(),
    );
    final current = [...(state.documents ?? const <WindowsFirestoreRestDocument>[])];
    final index = current.indexWhere((item) => item.id == document.id);
    if (index >= 0) {
      current[index] = document;
    } else {
      current.add(document);
    }
    _setCollectionData(collectionPath, current);
  }

  void _removeCachedDocument(String collectionPath, String documentId) {
    final state = _watchStates[collectionPath];
    if (state == null || state.documents == null) {
      invalidateCollection(collectionPath);
      return;
    }
    final updated =
        state.documents!.where((item) => item.id != documentId).toList();
    _setCollectionData(collectionPath, updated);
  }

  String _collectionPathFromDocumentPath(String documentPath) {
    final parts = documentPath.split('/');
    if (parts.length <= 1) {
      return documentPath;
    }
    return parts.sublist(0, parts.length - 1).join('/');
  }

  Future<HttpClientResponse> _sendRequest(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final request = await _httpClient.openUrl(method, uri);
    if (body != null) {
      final payload = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.headers.contentLength = payload.length;
      request.add(payload);
    }
    final response = await request.close();
    if (response.statusCode >= 400 && response.statusCode != HttpStatus.notFound) {
      final text = await response.transform(utf8.decoder).join();
      throw HttpException(
        'Firestore REST $method $uri failed: ${response.statusCode} $text',
      );
    }
    return response;
  }

  Future<Map<String, dynamic>> _readJson(HttpClientResponse response) async {
    final text = await response.transform(utf8.decoder).join();
    if (text.trim().isEmpty) {
      return <String, dynamic>{};
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  WindowsFirestoreRestDocument _decodeDocument(Map<String, dynamic> document) {
    final name = document['name'] as String? ?? '';
    final path = name.split('/documents/').last;
    final id = path.split('/').last;
    final fields =
        (document['fields'] as Map<String, dynamic>? ?? const <String, dynamic>{})
            .map((key, value) => MapEntry(key, _decodeValue(value)));
    return WindowsFirestoreRestDocument(id: id, path: path, data: fields);
  }

  Map<String, dynamic> _encodeFields(Map<String, dynamic> data) {
    return data.map((key, value) => MapEntry(key, _encodeValue(value)));
  }

  dynamic _decodeValue(dynamic value) {
    if (value is! Map<String, dynamic> || value.isEmpty) {
      return null;
    }
    if (value.containsKey('stringValue')) {
      return value['stringValue'] as String? ?? '';
    }
    if (value.containsKey('integerValue')) {
      return int.tryParse('${value['integerValue']}') ?? 0;
    }
    if (value.containsKey('doubleValue')) {
      return (value['doubleValue'] as num?)?.toDouble() ?? 0;
    }
    if (value.containsKey('booleanValue')) {
      return value['booleanValue'] == true;
    }
    if (value.containsKey('nullValue')) {
      return null;
    }
    if (value.containsKey('timestampValue')) {
      return DateTime.parse(value['timestampValue'] as String).toUtc();
    }
    if (value.containsKey('mapValue')) {
      final fields =
          (value['mapValue'] as Map<String, dynamic>)['fields']
              as Map<String, dynamic>? ??
          const <String, dynamic>{};
      return fields.map(
        (key, nestedValue) => MapEntry(key, _decodeValue(nestedValue)),
      );
    }
    if (value.containsKey('arrayValue')) {
      final values =
          (value['arrayValue'] as Map<String, dynamic>)['values']
              as List<dynamic>? ??
          const [];
      return values.map(_decodeValue).toList();
    }
    return null;
  }

  Map<String, dynamic> _encodeValue(dynamic value) {
    if (value == null) {
      return const {'nullValue': null};
    }
    if (value is String) {
      return {'stringValue': value};
    }
    if (value is bool) {
      return {'booleanValue': value};
    }
    if (value is int) {
      return {'integerValue': value.toString()};
    }
    if (value is double) {
      return {'doubleValue': value};
    }
    if (value is num) {
      if (value % 1 == 0) {
        return {'integerValue': value.toInt().toString()};
      }
      return {'doubleValue': value.toDouble()};
    }
    if (value is Timestamp) {
      return {'timestampValue': value.toDate().toUtc().toIso8601String()};
    }
    if (value is DateTime) {
      return {'timestampValue': value.toUtc().toIso8601String()};
    }
    if (value is List) {
      return {
        'arrayValue': {
          'values': value.map(_encodeValue).toList(),
        },
      };
    }
    if (value is Map<String, dynamic>) {
      return {
        'mapValue': {
          'fields': _encodeFields(value),
        },
      };
    }
    throw UnsupportedError(
      'Unsupported Firestore REST value: ${value.runtimeType}',
    );
  }
}

class _CollectionWatchState {
  final StreamController<List<WindowsFirestoreRestDocument>> controller =
      StreamController<List<WindowsFirestoreRestDocument>>.broadcast();
  int subscriberCount = 0;
  DateTime? lastFetchedAt;
  List<WindowsFirestoreRestDocument>? documents;
  Future<List<WindowsFirestoreRestDocument>>? pendingFetch;
}
