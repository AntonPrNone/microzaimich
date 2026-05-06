import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' as cf;
import 'package:firedart/firedart.dart' as fd;
import 'package:firedart/firestore/type_util.dart';
import 'package:firedart/generated/google/firestore/v1/document.pb.dart' as fs;
import 'package:firedart/generated/google/firestore/v1/firestore.pbgrpc.dart';
import 'package:firedart/generated/google/firestore/v1/query.pb.dart';
import 'package:grpc/grpc.dart';

import '../../firebase_options.dart';
import 'windows_firestore_rest_service.dart';

class WindowsFirestoreStreamService {
  WindowsFirestoreStreamService._() {
    if (!fd.Firestore.initialized) {
      fd.Firestore.initialize(DefaultFirebaseOptions.currentPlatform.projectId);
    }
    _firestore = fd.Firestore.instance;
  }

  static final WindowsFirestoreStreamService instance =
      WindowsFirestoreStreamService._();

  late final fd.Firestore _firestore;
  late final ClientChannel _channel = ClientChannel(
    'firestore.googleapis.com',
    options: const ChannelOptions(),
  );
  late final FirestoreClient _client = FirestoreClient(_channel);

  String get _database =>
      'projects/${DefaultFirebaseOptions.currentPlatform.projectId}/databases/(default)/documents';

  Future<List<WindowsFirestoreRestDocument>> listDocuments(
    String collectionPath,
  ) async {
    final documents = <fd.Document>[];
    var nextPageToken = '';

    do {
      final page = await _firestore.collection(
        collectionPath,
      ).get(pageSize: 1024, nextPageToken: nextPageToken);
      documents.addAll(page);
      nextPageToken = page.nextPageToken;
    } while (nextPageToken.isNotEmpty);

    return documents
        .map(
          (doc) => WindowsFirestoreRestDocument(
            id: doc.id,
            path: doc.path,
            data: Map<String, dynamic>.from(doc.map),
          ),
        )
        .toList();
  }

  Future<List<WindowsFirestoreRestDocument>> queryDocuments(
    String collectionPath, {
    String? whereField,
    dynamic isEqualTo,
    int? limit,
  }) async {
    dynamic query = _firestore.collection(collectionPath);
    if (whereField != null) {
      query = query.where(whereField, isEqualTo: isEqualTo);
    }
    if (limit != null) {
      query = query.limit(limit);
    }

    final documents = List<fd.Document>.from(await query.get() as Iterable);
    return documents
        .map(
          (doc) => WindowsFirestoreRestDocument(
            id: doc.id,
            path: doc.path,
            data: Map<String, dynamic>.from(doc.map),
          ),
        )
        .toList();
  }

  Future<WindowsFirestoreRestDocument?> getDocument(String documentPath) async {
    try {
      final doc = await _firestore.document(documentPath).get();
      return WindowsFirestoreRestDocument(
        id: doc.id,
        path: doc.path,
        data: Map<String, dynamic>.from(doc.map),
      );
    } on GrpcError catch (error) {
      if (error.code == StatusCode.notFound) {
        return null;
      }
      rethrow;
    }
  }

  Future<WindowsFirestoreRestDocument> createDocument(
    String collectionPath,
    Map<String, dynamic> data,
  ) async {
    final doc = await _firestore.collection(collectionPath).add(
          _normalizeMapForWrite(data),
        );
    return WindowsFirestoreRestDocument(
      id: doc.id,
      path: doc.path,
      data: Map<String, dynamic>.from(doc.map),
    );
  }

  Future<void> setDocument(
    String documentPath,
    Map<String, dynamic> data,
  ) {
    return _firestore.document(documentPath).set(_normalizeMapForWrite(data));
  }

  Future<void> updateDocument(
    String documentPath,
    Map<String, dynamic> data,
  ) {
    return _firestore.document(documentPath).update(_normalizeMapForWrite(data));
  }

  Future<void> deleteDocument(String documentPath) {
    return _firestore.document(documentPath).delete();
  }

  Stream<List<WindowsFirestoreRestDocument>> watchCollection(
    String collectionPath,
  ) {
    return Stream.multi((controller) {
      () async {
        try {
          controller.add(await listDocuments(collectionPath));
          await for (final docs in _firestore.collection(collectionPath).stream) {
            controller.add(
              List<fd.Document>.from(docs)
                  .map(
                    (doc) => WindowsFirestoreRestDocument(
                      id: doc.id,
                      path: doc.path,
                      data: Map<String, dynamic>.from(doc.map),
                    ),
                  )
                  .toList(),
            );
          }
        } catch (error, stackTrace) {
          controller.addError(error, stackTrace);
        } finally {
          await controller.close();
        }
      }();
    });
  }

  Stream<WindowsFirestoreRestDocument?> watchDocument(String documentPath) {
    return Stream.multi((controller) {
      () async {
        try {
          controller.add(await getDocument(documentPath));
          await for (final doc in _firestore.document(documentPath).stream) {
            if (doc == null) {
              controller.add(null);
              continue;
            }
            controller.add(
              WindowsFirestoreRestDocument(
                id: doc.id,
                path: doc.path,
                data: Map<String, dynamic>.from(doc.map),
              ),
            );
          }
        } catch (error, stackTrace) {
          controller.addError(error, stackTrace);
        } finally {
          await controller.close();
        }
      }();
    });
  }

  Stream<List<WindowsFirestoreRestDocument>> watchCollectionWhereEqual(
    String collectionPath, {
    required String fieldPath,
    required dynamic isEqualTo,
  }) {
    return Stream.multi((controller) {
      () async {
        try {
          final initialDocuments = await queryDocuments(
            collectionPath,
            whereField: fieldPath,
            isEqualTo: isEqualTo,
          );
          controller.add(initialDocuments);
          await for (final docs in _rawWhereEqualStream(
            collectionPath,
            fieldPath: fieldPath,
            isEqualTo: isEqualTo,
            seedDocuments: initialDocuments,
          )) {
            controller.add(docs);
          }
        } catch (error, stackTrace) {
          controller.addError(error, stackTrace);
        } finally {
          await controller.close();
        }
      }();
    });
  }

  Stream<List<WindowsFirestoreRestDocument>> _rawWhereEqualStream(
    String collectionPath, {
    required String fieldPath,
    required dynamic isEqualTo,
    List<WindowsFirestoreRestDocument> seedDocuments = const [],
  }) {
    final selector = StructuredQuery_CollectionSelector()
      ..collectionId = collectionPath.substring(
        collectionPath.lastIndexOf('/') + 1,
      );
    final fieldFilter = StructuredQuery_FieldFilter()
      ..field_1 = (StructuredQuery_FieldReference()..fieldPath = fieldPath)
      ..op = StructuredQuery_FieldFilter_Operator.EQUAL
      ..value = TypeUtil.encode(isEqualTo);
    final query = StructuredQuery()
      ..from.add(selector)
      ..where = (StructuredQuery_Filter()..fieldFilter = fieldFilter);
    final target = Target()
      ..query = (Target_QueryTarget()
        ..parent = _parentPath(collectionPath)
        ..structuredQuery = query);
    final request = ListenRequest()
      ..database = _database
      ..addTarget = target;

    final wrapper = _RawListenStreamWrapper.create(
      request,
      (requestStream) => _client.listen(
        requestStream,
        options: CallOptions(
          metadata: {'google-cloud-resource-prefix': _database},
        ),
      ),
    );
    for (final document in seedDocuments) {
      wrapper.documentMap['$_database/${document.path}'] = document;
    }

    return _mapCollectionStream(wrapper);
  }

  String _parentPath(String collectionPath) {
    final slashIndex = collectionPath.lastIndexOf('/');
    if (slashIndex == -1) {
      return _database;
    }
    return '$_database/${collectionPath.substring(0, slashIndex)}';
  }

  Stream<List<WindowsFirestoreRestDocument>> _mapCollectionStream(
    _RawListenStreamWrapper wrapper,
  ) {
    return wrapper.stream
        .where(
          (response) =>
              response.hasDocumentChange() ||
              response.hasDocumentRemove() ||
              response.hasDocumentDelete(),
        )
        .map((response) {
          if (response.hasDocumentChange()) {
            wrapper.documentMap[response.documentChange.document.name] =
                _fromRawDocument(response.documentChange.document);
          } else if (response.hasDocumentDelete()) {
            wrapper.documentMap.remove(response.documentDelete.document);
          } else {
            wrapper.documentMap.remove(response.documentRemove.document);
          }
          return wrapper.documentMap.values.toList();
        });
  }

  WindowsFirestoreRestDocument _fromRawDocument(fs.Document document) {
    final data = <String, dynamic>{};
    for (final entry in document.fields.entries) {
      data[entry.key] = _decodeValue(entry.value);
    }
    final path = document.name.substring(document.name.indexOf('/documents') + 11);
    return WindowsFirestoreRestDocument(
      id: path.substring(path.lastIndexOf('/') + 1),
      path: path,
      data: data,
    );
  }

  dynamic _decodeValue(fs.Value value) {
    switch (value.whichValueType()) {
      case fs.Value_ValueType.nullValue:
        return null;
      case fs.Value_ValueType.booleanValue:
        return value.booleanValue;
      case fs.Value_ValueType.doubleValue:
        return value.doubleValue;
      case fs.Value_ValueType.stringValue:
        return value.stringValue;
      case fs.Value_ValueType.integerValue:
        return value.integerValue.toInt();
      case fs.Value_ValueType.timestampValue:
        return value.timestampValue.toDateTime().toUtc();
      case fs.Value_ValueType.bytesValue:
        return value.bytesValue;
      case fs.Value_ValueType.referenceValue:
        return value.referenceValue;
      case fs.Value_ValueType.geoPointValue:
        return {
          'latitude': value.geoPointValue.latitude,
          'longitude': value.geoPointValue.longitude,
        };
      case fs.Value_ValueType.arrayValue:
        return value.arrayValue.values.map(_decodeValue).toList(growable: false);
      case fs.Value_ValueType.mapValue:
        return value.mapValue.fields.map(
          (key, nestedValue) => MapEntry(key, _decodeValue(nestedValue)),
        );
      default:
        return null;
    }
  }

  Map<String, dynamic> _normalizeMapForWrite(Map<String, dynamic> data) {
    return data.map((key, value) => MapEntry(key, _normalizeValueForWrite(value)));
  }

  dynamic _normalizeValueForWrite(dynamic value) {
    if (value == null ||
        value is bool ||
        value is num ||
        value is String ||
        value is DateTime) {
      return value;
    }

    if (value is cf.Timestamp) {
      return value.toDate().toUtc();
    }

    if (value is cf.FieldValue) {
      final marker = value.toString();
      if (marker.contains('ServerTimestamp')) {
        return DateTime.now().toUtc();
      }
      throw Exception('Unsupported FieldValue for Windows Firestore write: $marker');
    }

    if (value is List) {
      return value.map(_normalizeValueForWrite).toList(growable: false);
    }

    if (value is Map) {
      return value.map(
        (key, nestedValue) =>
            MapEntry(key.toString(), _normalizeValueForWrite(nestedValue)),
      );
    }

    throw Exception('Unknown type: ${value.runtimeType}');
  }
}

class _RawListenStreamWrapper {
  _RawListenStreamWrapper.create(
    this._listenRequest,
    this._responseStreamFactory,
  ) {
    _responseStreamController = StreamController<ListenResponse>.broadcast(
      onListen: _retry,
      onCancel: close,
    );
  }

  final _errors = <_ErrorAndStackTrace>[];
  final ListenRequest _listenRequest;
  final Stream<ListenResponse> Function(Stream<ListenRequest> requestStream)
      _responseStreamFactory;
  final Map<String, WindowsFirestoreRestDocument> documentMap = {};

  late StreamController<ListenResponse> _responseStreamController;
  StreamController<ListenRequest>? _requestStreamController;
  StreamSubscription<ListenResponse>? _responseSubscription;

  Stream<ListenResponse> get stream => _responseStreamController.stream;

  void _retry() {
    _requestStreamController = StreamController<ListenRequest>();
    final responseStream = _responseStreamFactory(
      _requestStreamController!.stream,
    );
    _responseSubscription = responseStream.listen(
      (value) {
        _errors.clear();
        _responseStreamController.add(value);
      },
      onDone: close,
      onError: (error, stackTrace) {
        _responseSubscription?.cancel();
        _responseSubscription = null;
        _errors.add(_ErrorAndStackTrace(error, stackTrace));
        if (_errors.length >= 5) {
          for (final item in _errors) {
            _responseStreamController.addError(item.error, item.stackTrace);
          }
          close();
        } else {
          _retry();
        }
      },
    );
    _requestStreamController!.add(_listenRequest);
  }

  void close() {
    _requestStreamController?.close();
    _requestStreamController = null;
    _responseSubscription?.cancel();
    _responseSubscription = null;
    if (!_responseStreamController.isClosed) {
      _responseStreamController.close();
    }
  }
}

class _ErrorAndStackTrace {
  const _ErrorAndStackTrace(this.error, this.stackTrace);

  final Object error;
  final StackTrace? stackTrace;
}
