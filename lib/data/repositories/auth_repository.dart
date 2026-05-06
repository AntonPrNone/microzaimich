import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/app_user.dart';
import '../models/user_role.dart';
import '../services/app_clock.dart';
import '../services/firestore_service.dart';

class AuthLookupResult {
  const AuthLookupResult({
    required this.user,
    required this.exists,
    required this.requiresPasswordSetup,
  });

  final AppUser? user;
  final bool exists;
  final bool requiresPasswordSetup;
}

class AuthRepository {
  AuthRepository({
    required FirestoreService firestoreService,
  }) : _firestoreService = firestoreService;

  final FirestoreService _firestoreService;

  String normalizePhone(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length == 10) {
      return '7$digits';
    }
    if (digits.startsWith('8') && digits.length == 11) {
      return '7${digits.substring(1)}';
    }
    return digits;
  }

  Future<AuthLookupResult> lookupByPhone(String phone) async {
    final normalizedPhone = normalizePhone(phone);
    if (Platform.isWindows) {
      final matches = await _firestoreService.windowsStream!.queryDocuments(
        'users',
        whereField: 'phone',
        isEqualTo: normalizedPhone,
        limit: 1,
      );
      if (matches.isEmpty) {
        return const AuthLookupResult(
          user: null,
          exists: false,
          requiresPasswordSetup: false,
        );
      }
      final match = matches.first;
      final user = AppUser.fromMap(
        match.id,
        match.data,
      );
      return AuthLookupResult(
        user: user,
        exists: true,
        requiresPasswordSetup: !user.hasPassword,
      );
    }

    final snapshot = await _firestoreService.users
        .where('phone', isEqualTo: normalizedPhone)
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) {
      return const AuthLookupResult(
        user: null,
        exists: false,
        requiresPasswordSetup: false,
      );
    }

    final user = AppUser.fromDoc(snapshot.docs.first);
    return AuthLookupResult(
      user: user,
      exists: true,
      requiresPasswordSetup: !user.hasPassword,
    );
  }

  Future<AppUser?> getUserById(String userId) async {
    if (Platform.isWindows) {
      final doc = await _firestoreService.windowsStream!.getDocument(
        'users/$userId',
      );
      if (doc == null) {
        return null;
      }
      return AppUser.fromMap(doc.id, doc.data);
    }

    final doc = await _firestoreService.users.doc(userId).get();
    if (!doc.exists) {
      return null;
    }
    return AppUser.fromDoc(doc);
  }

  Stream<List<AppUser>> watchClients() {
    if (Platform.isWindows) {
      return _firestoreService.windowsStream!
          .watchCollectionWhereEqual(
            'users',
            fieldPath: 'role',
            isEqualTo: UserRole.client.value,
          )
          .map(
            (docs) {
              final usersById = <String, AppUser>{};
              for (final doc in docs) {
                usersById[doc.id] = AppUser.fromMap(doc.id, doc.data);
              }
              final users = usersById.values.toList()
                ..sort((a, b) => a.name.compareTo(b.name));
              return users;
            },
          );
    }

    return _firestoreService.users
        .where('role', isEqualTo: UserRole.client.value)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(AppUser.fromDoc)
              .where((user) => user.role == UserRole.client)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name)),
        );
  }

  Future<bool> hasAnyAdmin() async {
    if (Platform.isWindows) {
      final docs = await _firestoreService.windowsStream!.queryDocuments(
        'users',
        whereField: 'role',
        isEqualTo: UserRole.admin.value,
        limit: 1,
      );
      return docs.any((doc) => doc.data['role'] == UserRole.admin.value);
    }

    final snapshot = await _firestoreService.users
        .where('role', isEqualTo: UserRole.admin.value)
        .limit(1)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  Future<AppUser> createUser({
    required String name,
    required String phone,
    String? password,
    UserRole role = UserRole.client,
  }) async {
    final normalizedPhone = normalizePhone(phone);
    final existingUser = await lookupByPhone(normalizedPhone);
    if (existingUser.user != null) {
      throw const AuthException('РџРѕР»СЊР·РѕРІР°С‚РµР»СЊ СЃ С‚Р°РєРёРј РЅРѕРјРµСЂРѕРј СѓР¶Рµ СЃСѓС‰РµСЃС‚РІСѓРµС‚');
    }

    if (Platform.isWindows) {
      final created = await _firestoreService.windowsStream!.createDocument(
        'users',
        {
          'name': name.trim(),
          'phone': normalizedPhone,
          'role': role.value,
          'password': password,
          'createdAt': Timestamp.fromDate(AppClock.nowForStorage()),
        },
      );
      return AppUser.fromMap(created.id, created.data);
    }

    final userRef = _firestoreService.users.doc();
    final user = AppUser(
      id: userRef.id,
      name: name.trim(),
      phone: normalizedPhone,
      role: role,
      password: password,
      createdAt: AppClock.nowForStorage(),
    );
    await userRef.set(user.toMap());
    return user;
  }

  Future<AppUser> setPassword({
    required AppUser user,
    required String password,
    String? name,
  }) async {
    final updated = user.copyWith(
      name: name?.trim().isNotEmpty == true ? name!.trim() : user.name,
      password: password,
    );
    if (Platform.isWindows) {
      await _firestoreService.windowsStream!
          .updateDocument('users/${user.id}', updated.toMap());
      return updated;
    }
    await _firestoreService.users.doc(user.id).update(updated.toMap());
    return updated;
  }

  Future<AppUser> changePassword({
    required AppUser user,
    required String password,
  }) async {
    final updated = user.copyWith(password: password);
    if (Platform.isWindows) {
      await _firestoreService.windowsStream!.updateDocument('users/${user.id}', {
        'password': password,
      });
      return updated;
    }
    await _firestoreService.users.doc(user.id).update({'password': password});
    return updated;
  }

  Future<AppUser> signIn({
    required String phone,
    required String password,
  }) async {
    final result = await lookupByPhone(phone);
    final user = result.user;
    if (user == null || !user.hasPassword) {
      throw const AuthException('РџРѕР»СЊР·РѕРІР°С‚РµР»СЊ РЅРµ РЅР°Р№РґРµРЅ РёР»Рё РїР°СЂРѕР»СЊ РµС‰С‘ РЅРµ СЃРѕР·РґР°РЅ');
    }

    if (user.password != password) {
      throw const AuthException('РќРµРІРµСЂРЅС‹Р№ РїР°СЂРѕР»СЊ');
    }

    return user;
  }

  Future<void> deleteUser(String userId) async {
    if (Platform.isWindows) {
      await _firestoreService.windowsStream!.deleteDocument('users/$userId');
      return;
    }
    await _firestoreService.users.doc(userId).delete();
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
