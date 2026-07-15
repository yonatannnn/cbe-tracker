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

/// Parses user-typed money ("5,000.00", "5000", "850.5") into integer cents.
///
/// Returns null when the input isn't a plain positive amount — the caller
/// shows a validation error rather than saving a guess. Integer math only.
int? parseCentsInput(String input) {
  final cleaned = input.replaceAll(RegExp(r'[,\s]'), '');
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) return null;
  final fraction = (match.group(2) ?? '0').padRight(2, '0');
  return int.parse(match.group(1)!) * 100 + int.parse(fraction);
}

/// Formats cents for an editable text field: "5000.00" (no currency, no
/// grouping) so it round-trips through [parseCentsInput].
String centsToInput(int cents) {
  final abs = cents.abs();
  return '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}
