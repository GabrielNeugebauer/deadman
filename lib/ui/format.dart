import 'package:intl/intl.dart';

const lamportsPerSol = 1000000000;

String sol(int lamports, {int digits = 3}) =>
    (lamports / lamportsPerSol).toStringAsFixed(digits);

int? parseSol(String input) {
  final v = double.tryParse(input.trim().replaceAll(',', '.'));
  if (v == null || v < 0) return null;
  return (v * lamportsPerSol).round();
}

String short(String address) => address.length <= 10
    ? address
    : '${address.substring(0, 4)}…${address.substring(address.length - 4)}';

/// "6d 23h", "4h 12m", "42s".
String span(int secs) {
  final s = secs.abs();
  if (s >= 86400) return '${s ~/ 86400}d ${(s % 86400) ~/ 3600}h';
  if (s >= 3600) return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  if (s >= 60) return '${s ~/ 60}m ${s % 60}s';
  return '${s}s';
}

String ago(int unixSecs, int now) => '${span(now - unixSecs)} ago';

/// "Oct 4, 2027" for unix seconds [secs], local time.
String dateText(int secs) =>
    DateFormat.yMMMd().format(DateTime.fromMillisecondsSinceEpoch(secs * 1000));

/// "Oct 4, 2027, 14:05" for unix seconds [secs], local time.
String dateTimeText(int secs) => DateFormat.yMMMd().add_Hm().format(
  DateTime.fromMillisecondsSinceEpoch(secs * 1000),
);

/// When an installment unlocks: the date, with the time when installments
/// come more often than daily.
String installmentDate(int secs, int periodSecs) =>
    periodSecs > 0 && periodSecs < 86400 ? dateTimeText(secs) : dateText(secs);
