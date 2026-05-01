import '../models/app_user.dart';
import '../models/user_role.dart';
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
    final doc = await _firestoreService.users.doc(userId).get();
    if (!doc.exists) {
      return null;
    }
    return AppUser.fromDoc(doc);
  }

  Stream<List<AppUser>> watchClients() {
    return _firestoreService.users
        .where('role', isEqualTo: UserRole.client.value)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .map(AppUser.fromDoc)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name)),
        );
  }

  Future<bool> hasAnyAdmin() async {
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
      throw const AuthException('Пользователь с таким номером уже существует');
    }
    final userRef = _firestoreService.users.doc();
    final user = AppUser(
      id: userRef.id,
      name: name.trim(),
      phone: normalizedPhone,
      role: role,
      password: password,
      createdAt: DateTime.now(),
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
    await _firestoreService.users.doc(user.id).update(updated.toMap());
    return updated;
  }

  Future<AppUser> signIn({
    required String phone,
    required String password,
  }) async {
    final result = await lookupByPhone(phone);
    final user = result.user;
    if (user == null || !user.hasPassword) {
      throw const AuthException('Пользователь не найден или пароль ещё не создан');
    }

    if (user.password != password) {
      throw const AuthException('Неверный пароль');
    }

    return user;
  }

  Future<void> deleteUser(String userId) async {
    await _firestoreService.users.doc(userId).delete();
  }
}

class AuthException implements Exception {
  const AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
