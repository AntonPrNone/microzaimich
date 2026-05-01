import 'package:shared_preferences/shared_preferences.dart';

class SessionService {
  static const _userIdKey = 'session_user_id';
  static const _lastPhoneKey = 'last_phone_input';
  static const _lastPasswordKey = 'last_password_input';

  Future<String?> readUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_userIdKey);
  }

  Future<void> saveUserId(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userIdKey, userId);
  }

  Future<String?> readLastPhoneInput() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastPhoneKey);
  }

  Future<void> saveLastPhoneInput(String phone) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPhoneKey, phone);
  }

  Future<String?> readLastPasswordInput() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastPasswordKey);
  }

  Future<void> saveLastPasswordInput(String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastPasswordKey, password);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userIdKey);
  }
}
