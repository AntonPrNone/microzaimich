import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../../core/utils/platform_utils.dart';
import '../models/app_clock_settings.dart';
import '../models/loan_defaults_settings.dart';
import '../models/payment_settings.dart';
import '../services/firestore_service.dart';

class AppSettingsRepository {
  AppSettingsRepository({
    required FirestoreService firestoreService,
  }) : _firestoreService = firestoreService;

  final FirestoreService _firestoreService;
  final StreamController<AppClockSettings> _clockSettingsController =
      StreamController<AppClockSettings>.broadcast();
  static const String _clockDebugEnabledKey = 'local_clock_debug_enabled';
  static const String _clockDebugNowKey = 'local_clock_debug_now';
  AppClockSettings? _lastClockSettings;
  bool _clockSettingsLoaded = false;

  Stream<PaymentSettings> watchPaymentSettings() {
    if (AppPlatform.isWindows) {
      return _firestoreService.windowsStream!
          .watchDocument('app_settings/payment')
          .map((doc) => PaymentSettings.fromMap(doc?.data));
    }
    return _firestoreService.appSettings.doc('payment').snapshots().map(
          (snapshot) => PaymentSettings.fromMap(snapshot.data()),
        );
  }

  Future<void> savePaymentSettings(PaymentSettings settings) async {
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!
          .setDocument('app_settings/payment', settings.toMap());
      return;
    }
    await _firestoreService.appSettings.doc('payment').set(settings.toMap());
  }

  Stream<LoanDefaultsSettings> watchLoanDefaults() {
    if (AppPlatform.isWindows) {
      return _firestoreService.windowsStream!
          .watchDocument('app_settings/loan_defaults')
          .map((doc) => LoanDefaultsSettings.fromMap(doc?.data));
    }
    return _firestoreService.appSettings.doc('loan_defaults').snapshots().map(
          (snapshot) => LoanDefaultsSettings.fromMap(snapshot.data()),
        );
  }

  Future<void> saveLoanDefaults(LoanDefaultsSettings settings) async {
    if (AppPlatform.isWindows) {
      await _firestoreService.windowsStream!
          .setDocument('app_settings/loan_defaults', settings.toMap());
      return;
    }
    await _firestoreService.appSettings
        .doc('loan_defaults')
        .set(settings.toMap());
  }

  Stream<AppClockSettings> watchClockSettings() async* {
    await _ensureClockSettingsLoaded();
    yield _lastClockSettings ?? const AppClockSettings.disabled();
    yield* _clockSettingsController.stream;
  }

  Future<void> saveClockSettings(AppClockSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_clockDebugEnabledKey, settings.debugEnabled);
    if (settings.debugEnabled && settings.debugNow != null) {
      await prefs.setString(
        _clockDebugNowKey,
        settings.debugNow!.toIso8601String(),
      );
    } else {
      await prefs.remove(_clockDebugNowKey);
    }

    _lastClockSettings = settings.debugEnabled && settings.debugNow != null
        ? settings
        : const AppClockSettings.disabled();
    _clockSettingsLoaded = true;
    _clockSettingsController.add(_lastClockSettings!);
  }

  Future<void> _ensureClockSettingsLoaded() async {
    if (_clockSettingsLoaded) {
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final debugEnabled = prefs.getBool(_clockDebugEnabledKey) ?? false;
      final debugNowRaw = prefs.getString(_clockDebugNowKey);
      final debugNow = debugNowRaw == null ? null : DateTime.tryParse(debugNowRaw);

      _lastClockSettings = debugEnabled && debugNow != null
          ? AppClockSettings(
              debugEnabled: true,
              debugNow: debugNow,
              updatedAt: null,
            )
          : const AppClockSettings.disabled();
    } on Object {
      _lastClockSettings = const AppClockSettings.disabled();
    }

    _clockSettingsLoaded = true;
  }
}
