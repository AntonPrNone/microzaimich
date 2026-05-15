import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/utils/platform_utils.dart';
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
  final Random _random = Random.secure();

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
    if (AppPlatform.isWindows) {
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
      final user = AppUser.fromMap(match.id, match.data);
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
    if (AppPlatform.isWindows) {
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

  Stream<AppUser?> watchUserById(String userId) {
    if (AppPlatform.isWindows) {
      return _firestoreService.windowsStream!
          .watchDocument('users/$userId')
          .map((doc) {
            if (doc == null) {
              return null;
            }
            return AppUser.fromMap(doc.id, doc.data);
          });
    }

    return _firestoreService.users.doc(userId).snapshots().map((doc) {
      if (!doc.exists) {
        return null;
      }
      return AppUser.fromDoc(doc);
    });
  }

  Stream<List<AppUser>> watchClients() {
    if (AppPlatform.isWindows) {
      return _firestoreService.windowsStream!
          .watchCollectionWhereEqual(
            'users',
            fieldPath: 'role',
            isEqualTo: UserRole.client.value,
          )
          .map((docs) {
            final usersById = <String, AppUser>{};
            for (final doc in docs) {
              usersById[doc.id] = AppUser.fromMap(doc.id, doc.data);
            }
            final users = usersById.values.toList()
              ..sort((a, b) => a.name.compareTo(b.name));
            return users;
          });
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
    if (AppPlatform.isWindows) {
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
      throw const AuthException(
        'Пользователь с таким номером уже существует',
      );
    }

    if (AppPlatform.isWindows) {
      final created = await _firestoreService.windowsStream!.createDocument(
        'users',
        {
          'name': name.trim(),
          'phone': normalizedPhone,
          'role': role.value,
          'password': password,
          'reminderHour': 18,
          'reminderMinute': 0,
          'telegramNotificationsEnabled': false,
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
      reminderHour: 18,
      reminderMinute: 0,
      telegramNotificationsEnabled: false,
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
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.updateDocument(
        'users/${user.id}',
        updated.toMap(),
      );
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
    if (AppPlatform.isWindows) {
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
      throw const AuthException(
        'Пользователь не найден или пароль ещё не создан',
      );
    }

    if (user.password != password) {
      throw const AuthException('Неверный пароль');
    }

    return user;
  }

  Future<void> deleteUser(String userId) async {
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.deleteDocument('users/$userId');
      return;
    }
    await _firestoreService.users.doc(userId).delete();
  }

  Future<AppUser> updateReminderTime({
    required AppUser user,
    required int hour,
    required int minute,
  }) async {
    final updated = user.copyWith(
      reminderHour: hour.clamp(0, 23),
      reminderMinute: minute.clamp(0, 59),
    );
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.updateDocument('users/${user.id}', {
        'reminderHour': updated.reminderHour,
        'reminderMinute': updated.reminderMinute,
      });
      return updated;
    }
    await _firestoreService.users.doc(user.id).update({
      'reminderHour': updated.reminderHour,
      'reminderMinute': updated.reminderMinute,
    });
    return updated;
  }

  Future<AppUser> refreshTelegramLinkCode({
    required AppUser user,
  }) async {
    String code;
    do {
      code = _generateTelegramLinkCode();
    } while (await _telegramLinkCodeExists(code));

    final updated = user.copyWith(telegramLinkCode: code);
    const field = 'telegramLinkCode';

    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.updateDocument('users/${user.id}', {
        field: code,
      });
      return updated;
    }

    await _firestoreService.users.doc(user.id).update({field: code});
    return updated;
  }

  Future<AppUser> updateTelegramNotifications({
    required AppUser user,
    required bool enabled,
  }) async {
    final updated = user.copyWith(telegramNotificationsEnabled: enabled);
    const field = 'telegramNotificationsEnabled';

    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.updateDocument('users/${user.id}', {
        field: enabled,
      });
      return updated;
    }

    await _firestoreService.users.doc(user.id).update({field: enabled});
    return updated;
  }

  Future<AppUser> disconnectTelegram({
    required AppUser user,
  }) async {
    final updated = AppUser(
      id: user.id,
      name: user.name,
      phone: user.phone,
      role: user.role,
      password: user.password,
      reminderHour: user.reminderHour,
      reminderMinute: user.reminderMinute,
      telegramChatId: '',
      telegramUsername: '',
      telegramLinkCode: user.telegramLinkCode,
      telegramLinkedAt: null,
      telegramNotificationsEnabled: false,
      createdAt: user.createdAt,
    );
    final payload = {
      'telegramChatId': null,
      'telegramUsername': null,
      'telegramLinkedAt': null,
      'telegramNotificationsEnabled': false,
    };

    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!.updateDocument(
        'users/${user.id}',
        payload,
      );
      return updated;
    }

    await _firestoreService.users.doc(user.id).update(payload);
    return updated;
  }

  String _generateTelegramLinkCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    return List.generate(
      8,
      (_) => alphabet[_random.nextInt(alphabet.length)],
    ).join();
  }

  Future<bool> _telegramLinkCodeExists(String code) async {
    if (AppPlatform.isWindows) {
      final docs = await _firestoreService.windowsStream!.queryDocuments(
        'users',
        whereField: 'telegramLinkCode',
        isEqualTo: code,
        limit: 1,
      );
      return docs.isNotEmpty;
    }

    final snapshot = await _firestoreService.users
        .where('telegramLinkCode', isEqualTo: code)
        .limit(1)
        .get();
    return snapshot.docs.isNotEmpty;
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
