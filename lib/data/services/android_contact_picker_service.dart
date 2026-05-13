import 'package:flutter/services.dart';

import '../../core/utils/platform_utils.dart';

class AndroidPickedContact {
  const AndroidPickedContact({
    required this.name,
    required this.phone,
  });

  final String name;
  final String phone;
}

class AndroidContactPickerException implements Exception {
  const AndroidContactPickerException(this.code, [this.message]);

  final String code;
  final String? message;
}

class AndroidContactPickerService {
  AndroidContactPickerService._();

  static const MethodChannel _channel = MethodChannel('contact_import');

  static Future<AndroidPickedContact?> pickContact() async {
    if (!AppPlatform.isAndroid) {
      return null;
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'pickClientContact',
      );
      if (result == null) {
        return null;
      }

      final name = (result['name'] as String? ?? '').trim();
      final phone = (result['phone'] as String? ?? '').trim();

      return AndroidPickedContact(name: name, phone: phone);
    } on PlatformException catch (error) {
      throw AndroidContactPickerException(error.code, error.message);
    }
  }
}
