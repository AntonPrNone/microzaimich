import 'package:flutter/foundation.dart';

abstract final class AppPlatform {
  static bool get isWeb => kIsWeb;

  static bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  static bool get isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static bool get isIOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  static bool get isLinux => !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
  static bool get isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get isDesktop => isWindows || isLinux || isMacOS;
  static bool get isMobile => isAndroid || isIOS;
}
