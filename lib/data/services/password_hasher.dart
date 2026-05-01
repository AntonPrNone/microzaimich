import 'dart:convert';

import 'package:crypto/crypto.dart';

class PasswordHasher {
  String hash(String rawPassword) {
    return sha256.convert(utf8.encode(rawPassword)).toString();
  }

  bool verify({
    required String rawPassword,
    required String passwordHash,
  }) {
    return hash(rawPassword) == passwordHash;
  }
}
