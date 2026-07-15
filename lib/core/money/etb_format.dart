/// Integer-cents money helpers and ETB formatting (§2, §6).
///
/// All formatting is integer arithmetic — cents never pass through a double
/// (CLAUDE.md). Pure Dart, no package dependency.
library;

const String _currency = 'ETB';

/// U+2212 MINUS SIGN — typographically correct, not an ASCII hyphen.
const String _minus = '−';

/// Groups an integer with thousands separators: 1250000 → "1,250,000".
String _group(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// Splits [cents] into a grouped "145,200.00" body, ignoring sign.
String _body(int cents) {
  final abs = cents.abs();
  final birr = abs ~/ 100;
  final fraction = abs % 100;
  return '${_group(birr)}.${fraction.toString().padLeft(2, '0')}';
}

/// Formats cents as ETB: `formatCents(14520000)` → "ETB 145,200.00".
///
/// Negative balances keep the sign attached: "−ETB 5,000.00".
String formatCents(int cents) {
  final body = '$_currency ${_body(cents)}';
  return cents < 0 ? '$_minus$body' : body;
}

/// Formats a delta with an explicit sign: "+ ETB 5,000.00" /
/// "− ETB 5,000.00". Zero is unsigned: "ETB 0.00".
String formatSignedCents(int cents) {
  if (cents == 0) return formatCents(0);
  final sign = cents > 0 ? '+' : _minus;
  return '$sign $_currency ${_body(cents)}';
}
