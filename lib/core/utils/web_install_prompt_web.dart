import 'dart:html' as html;

class WebInstallPrompt {
  static dynamic _deferredPrompt;
  static bool _initialized = false;

  static bool get isStandalone {
    return html.window.matchMedia('(display-mode: standalone)').matches;
  }

  static bool get isIos {
    final userAgent = html.window.navigator.userAgent.toLowerCase();
    return userAgent.contains('iphone') ||
        userAgent.contains('ipad') ||
        userAgent.contains('ipod');
  }

  static bool get isAndroid {
    final userAgent = html.window.navigator.userAgent.toLowerCase();
    return userAgent.contains('android');
  }

  static bool get canPrompt => _deferredPrompt != null && !isIos;

  static Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;

    html.window.on['beforeinstallprompt'].listen((event) {
      event.preventDefault();
      _deferredPrompt = event;
    });
  }

  static Future<bool> promptInstall() async {
    final prompt = _deferredPrompt;
    if (prompt == null || isIos) {
      return false;
    }

    _deferredPrompt = null;
    prompt.prompt();
    final userChoice = await prompt.userChoice as dynamic;
    return userChoice?.outcome == 'accepted';
  }
}
