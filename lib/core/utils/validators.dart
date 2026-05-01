class Validators {
  const Validators._();

  static String? phone(String? value) {
    final digits = (value ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11 || !digits.startsWith('7')) {
      return 'Введите номер в формате +7 (999) 123-45-67';
    }
    return null;
  }

  static String? name(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) {
      return 'Введите имя';
    }
    if (!RegExp(r'^[A-Za-zА-Яа-яЁё\s]+$').hasMatch(text)) {
      return 'Имя может содержать только буквы и пробелы';
    }
    final lettersCount = text.replaceAll(RegExp(r'[^A-Za-zА-Яа-яЁё]'), '').length;
    if (lettersCount < 2) {
      return 'Имя должно содержать минимум две буквы';
    }
    return null;
  }
}
