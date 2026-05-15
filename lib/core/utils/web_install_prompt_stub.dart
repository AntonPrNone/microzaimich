class WebInstallPrompt {
  static bool get isStandalone => false;

  static bool get isIos => false;

  static bool get isAndroid => false;

  static bool get canPrompt => false;

  static Future<void> initialize() async {}

  static Future<bool> promptInstall() async => false;
}
