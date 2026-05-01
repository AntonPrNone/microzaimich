import 'package:intl/intl.dart';

class Formatters {
  const Formatters._();

  static final NumberFormat _money = NumberFormat.currency(
    locale: 'ru_RU',
    symbol: '₽',
    decimalDigits: 2,
  );

  static final DateFormat _date = DateFormat('d MMM yyyy', 'ru_RU');
  static final DateFormat _dateTime = DateFormat('d MMM yyyy, HH:mm', 'ru_RU');
  static final DateFormat _dateCompact = DateFormat('dd.MM.yyyy', 'ru_RU');

  static String money(num value) => _money.format(value);

  static double parseDecimal(String value) {
    final normalized = value.replaceAll(' ', '').replaceAll(',', '.');
    return double.tryParse(normalized) ?? 0;
  }

  static String decimalInput(num value) {
    return value.toStringAsFixed(2).replaceAll('.', ',');
  }

  static double cents(num value) {
    return double.parse(value.toStringAsFixed(2));
  }

  static double centsUp(num value) {
    return (value * 100).ceil() / 100;
  }

  static String date(DateTime date) => _date.format(date);

  static String dateCompact(DateTime date) => _dateCompact.format(date);

  static String dateTime(DateTime date) => _dateTime.format(date);

  static String phone(String value) {
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11) {
      return value;
    }
    return '+${digits[0]} (${digits.substring(1, 4)}) '
        '${digits.substring(4, 7)}-${digits.substring(7, 9)}-${digits.substring(9)}';
  }
}
