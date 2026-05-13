import 'package:flutter/material.dart';

import '../../../data/models/app_user.dart';
import '../../../data/repositories/auth_repository.dart';
import '../../../data/services/bootstrap_service.dart';
import '../../../data/services/local_notification_service.dart';
import '../../../data/services/session_service.dart';

class LoginController extends ChangeNotifier {
  LoginController.empty();

  LoginController({
    required AuthRepository authRepository,
    required SessionService sessionService,
    required BootstrapService bootstrapService,
  })  : _authRepository = authRepository,
        _sessionService = sessionService,
        _bootstrapService = bootstrapService;

  late AuthRepository _authRepository;
  late SessionService _sessionService;
  late BootstrapService _bootstrapService;

  AppUser? currentUser;
  AuthLookupResult? lookupResult;
  bool isBusy = false;
  String? errorText;
  String lastPhoneInput = '';
  String lastPasswordInput = '';

  LoginController rebind({
    required AuthRepository authRepository,
    required SessionService sessionService,
    required BootstrapService bootstrapService,
  }) {
    _authRepository = authRepository;
    _sessionService = sessionService;
    _bootstrapService = bootstrapService;
    return this;
  }

  Future<void> initialize() async {
    await _bootstrapService.seedIfNeeded();
    lastPhoneInput = await _sessionService.readLastPhoneInput() ?? '';
    lastPasswordInput = await _sessionService.readLastPasswordInput() ?? '';

    final sessionUserId = await _sessionService.readUserId();
    if (sessionUserId == null) {
      notifyListeners();
      return;
    }

    currentUser = await _authRepository.getUserById(sessionUserId);
    notifyListeners();
  }

  Future<void> lookupPhone(String phone) async {
    _setBusy(true);
    errorText = null;
    try {
      lookupResult = await _authRepository.lookupByPhone(phone);
    } on Object catch (error) {
      errorText = error.toString();
    } finally {
      _setBusy(false);
    }
  }

  Future<bool> submit({
    required String phone,
    required String password,
    String? name,
  }) async {
    _setBusy(true);
    errorText = null;
    try {
      final result = await _authRepository.lookupByPhone(phone);
      AppUser user;

      if (!result.exists) {
        final safeName = (name ?? '').trim();
        if (safeName.isEmpty) {
          throw const AuthException('Введите имя для регистрации');
        }
        user = await _authRepository.createUser(
          name: safeName,
          phone: phone,
          password: password,
        );
      } else if (result.requiresPasswordSetup) {
        user = await _authRepository.setPassword(
          user: result.user!,
          password: password,
          name: name,
        );
      } else {
        user = await _authRepository.signIn(phone: phone, password: password);
      }

      currentUser = user;
      lastPhoneInput = phone;
      lastPasswordInput = password;
      lookupResult = AuthLookupResult(
        user: user,
        exists: true,
        requiresPasswordSetup: false,
      );
      await _sessionService.saveUserId(user.id);
      await _sessionService.saveLastPhoneInput(phone);
      await _sessionService.saveLastPasswordInput(password);
      notifyListeners();
      return true;
    } on AuthException catch (error) {
      errorText = error.message;
      notifyListeners();
      return false;
    } on Object catch (error) {
      errorText = error.toString();
      notifyListeners();
      return false;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> logout() async {
    final user = currentUser;
    if (user != null) {
      await LocalNotificationService.clearUserReminders(user.id);
    }
    await LocalNotificationService.stopBackgroundNotifications();
    await _sessionService.clear();
    currentUser = null;
    lookupResult = null;
    errorText = null;
    notifyListeners();
  }

  Future<void> changePassword(String password) async {
    final user = currentUser;
    if (user == null) {
      return;
    }
    final updated = await _authRepository.changePassword(
      user: user,
      password: password,
    );
    currentUser = updated;
    lastPasswordInput = password;
    await _sessionService.saveLastPasswordInput(password);
    notifyListeners();
  }

  void resetLookup() {
    lookupResult = null;
    errorText = null;
    notifyListeners();
  }

  void _setBusy(bool value) {
    isBusy = value;
    notifyListeners();
  }
}
