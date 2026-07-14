/// Shared, pure-Dart CBE message parser (§4).
///
/// Used by BOTH the OCR path and the SMS path. MUST stay free of Flutter
/// imports (CLAUDE.md).
///
library;

/// Transaction direction.
enum TxType { credit, debit }

/// How much we trust the parse. [aiParsed] is reserved for the Gemini
/// fallback path; [parseCbeText] only ever returns [high] or [low].
enum Confidence { high, low, aiParsed }

/// Structured result of parsing a CBE SMS/screenshot text.
class ParsedCbeMessage {
  ParsedCbeMessage({
    required this.amountCents,
    required this.type,
    required this.reference,
    required this.date,
    required this.confidence,
    required this.rawText,
  });

  /// Money is integer cents everywhere — never double arithmetic (CLAUDE.md).
  final int amountCents;
  final TxType type;

  /// FT reference number, or null when missing/malformed (→ [Confidence.low]).
  final String? reference;

  /// Parsed transaction timestamp, or null when unreadable (→ [Confidence.low]).
  final DateTime? date;
  final Confidence confidence;

  /// The original, unmodified input (fed to the LLM fallback when needed).
  final String rawText;
}

/// Thrown when the text cannot be parsed with confidence — specifically when
/// the amount or the credited/debited keyword is absent. The parser never
/// guesses these (§4).
class ParseException implements Exception {
  ParseException(this.message);

  final String message;

  @override
  String toString() => 'ParseException: $message';
}

// ETB (also tolerate "Br") immediately preceding an amount like 5,000.00.
final _amountRe = RegExp(
  r'(?:ETB|Br)\s*([\d,]+\.\d{2})',
  caseSensitive: false,
);

// Keyword detection is whitespace-tolerant so OCR line breaks that split a
// word ("Cred\nited") still match once whitespace is collapsed to spaces.
final _creditRe = RegExp(
  r'c\s*r\s*e\s*d\s*i\s*t\s*e\s*d',
  caseSensitive: false,
);
final _debitRe = RegExp(r'd\s*e\s*b\s*i\s*t\s*e\s*d', caseSensitive: false);

// CBE FT references are exactly FT + 10 alphanumerics. The receipt URL appends
// the account suffix (…12341234), so we bound to 10 to avoid swallowing it.
final _refRe = RegExp(r'FT\w{10}');

// "on <dd/MM/yyyy> at <HH:mm>".
final _dateRe = RegExp(
  r'on\s+(\d{2})/(\d{2})/(\d{4})\s+at\s+(\d{2}):(\d{2})',
  caseSensitive: false,
);

/// Parses a raw CBE message into a [ParsedCbeMessage].
///
/// Throws [ParseException] when no amount or no credited/debited keyword is
/// found (§4: never guess these).
ParsedCbeMessage parseCbeText(String raw) {
  // Collapse every run of whitespace (incl. newlines) to a single space so
  // OCR line breaks don't defeat matching.
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) {
    throw ParseException('Empty message');
  }

  final amounts = _amountRe.allMatches(text).toList();
  if (amounts.isEmpty) {
    throw ParseException('No amount found');
  }

  // Direction: whichever keyword appears first (CBE messages carry only one).
  final creditMatch = _creditRe.firstMatch(text);
  final debitMatch = _debitRe.firstMatch(text);
  final Match keyword;
  final TxType type;
  if (creditMatch != null &&
      (debitMatch == null || creditMatch.start <= debitMatch.start)) {
    keyword = creditMatch;
    type = TxType.credit;
  } else if (debitMatch != null) {
    keyword = debitMatch;
    type = TxType.debit;
  } else {
    throw ParseException('No credited/debited keyword found');
  }

  // The transaction amount is the one nearest the keyword — never a later
  // "Current Balance" figure.
  var best = amounts.first;
  var bestGap = _gap(best, keyword);
  for (final m in amounts.skip(1)) {
    final gap = _gap(m, keyword);
    if (gap < bestGap) {
      best = m;
      bestGap = gap;
    }
  }
  final amountCents = _toCents(best.group(1)!);

  final reference = _refRe.firstMatch(text)?.group(0);

  final dateMatch = _dateRe.firstMatch(text);
  final DateTime? date = dateMatch == null
      ? null
      : DateTime(
          int.parse(dateMatch.group(3)!), // year
          int.parse(dateMatch.group(2)!), // month
          int.parse(dateMatch.group(1)!), // day
          int.parse(dateMatch.group(4)!), // hour
          int.parse(dateMatch.group(5)!), // minute
        );

  final confidence = (reference == null || date == null)
      ? Confidence.low
      : Confidence.high;

  return ParsedCbeMessage(
    amountCents: amountCents,
    type: type,
    reference: reference,
    date: date,
    confidence: confidence,
    rawText: raw,
  );
}

/// Character gap between an amount match and the keyword (0 if they overlap).
int _gap(RegExpMatch amount, Match keyword) {
  if (amount.start >= keyword.end) return amount.start - keyword.end;
  if (keyword.start >= amount.end) return keyword.start - amount.end;
  return 0;
}

/// Converts a "1,250,000.00" style amount to integer cents with no double
/// arithmetic: the regex guarantees exactly two fractional digits.
int _toCents(String amount) {
  final parts = amount.replaceAll(',', '').split('.');
  return int.parse(parts[0]) * 100 + int.parse(parts[1]);
}
