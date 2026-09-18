/// Shared, pure-Dart CBE message parser (§4).
///
/// Used by BOTH the OCR path and the SMS path. MUST stay free of Flutter
/// imports (CLAUDE.md).
///
library;

import 'amount_adjacency.dart';

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
    this.bank,
    this.counterparty,
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

  /// Which bank issued the receipt, when the AI fallback read it ("Awash
  /// Bank"). Null for the local CBE parser — it only knows CBE.
  final String? bank;

  /// Who the money came from (credit) or went to (debit), when read.
  final String? counterparty;
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

// Amount location and credited/debited keywords live in amount_adjacency.dart
// so the AI gate applies the identical rule.

// CBE FT references are exactly FT + 10 alphanumerics. The receipt URL appends
// the account suffix (…12341234), so we bound to 10 to avoid swallowing it.
final _refRe = RegExp(r'FT\w{10}');

// CBE writes dates two ways. Both are supported; whichever matches first wins.

// SMS style: "on 14/07/2026 at 10:42".
final _slashDateRe = RegExp(
  r'on\s+(\d{1,2})/(\d{1,2})/(\d{4})\s+at\s+(\d{1,2}):(\d{2})',
  caseSensitive: false,
);

// App receipt style: "on Jul 15, 2026 11:45 AM".
final _monthNameDateRe = RegExp(
  r'\b([A-Za-z]{3})[a-z]*\s+(\d{1,2}),\s*(\d{4})\s+(\d{1,2}):(\d{2})\s*([AP]M)',
  caseSensitive: false,
);

const Map<String, int> _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Parses either CBE date shape, or null when neither is present.
DateTime? _parseDate(String text) {
  final slash = _slashDateRe.firstMatch(text);
  if (slash != null) {
    return DateTime(
      int.parse(slash.group(3)!), // year
      int.parse(slash.group(2)!), // month
      int.parse(slash.group(1)!), // day
      int.parse(slash.group(4)!), // hour
      int.parse(slash.group(5)!), // minute
    );
  }

  final named = _monthNameDateRe.firstMatch(text);
  if (named != null) {
    final month = _months[named.group(1)!.toLowerCase()];
    if (month == null) return null;
    var hour = int.parse(named.group(4)!);
    final isPm = named.group(6)!.toUpperCase() == 'PM';
    // 12-hour → 24-hour: 12 AM is 00, 12 PM stays 12.
    if (isPm && hour != 12) hour += 12;
    if (!isPm && hour == 12) hour = 0;
    return DateTime(
      int.parse(named.group(3)!), // year
      month,
      int.parse(named.group(2)!), // day
      hour,
      int.parse(named.group(5)!), // minute
    );
  }

  return null;
}

/// Parses a raw CBE message into a [ParsedCbeMessage].
///
/// Throws [ParseException] when no amount or no credited/debited keyword is
/// found (§4: never guess these).
ParsedCbeMessage parseCbeText(String raw) {
  // Collapse every run of whitespace (incl. newlines) to a single space so
  // OCR line breaks don't defeat matching.
  final text = normalizeCbeText(raw);
  if (text.isEmpty) {
    throw ParseException('Empty message');
  }

  final amounts = findCurrencyAmounts(text);
  if (amounts.isEmpty) {
    throw ParseException('No amount found');
  }

  final keywords = findTypeKeywords(text);
  if (keywords.isEmpty) {
    throw ParseException('No credited/debited keyword found');
  }

  // The transaction amount is the one nearest the keyword, never a Current
  // Balance figure. Same shared rule the AI gate uses.
  final located = selectAmountNearKeyword(
    normalized: text,
    amounts: amounts,
    keywords: keywords,
  );
  if (located == null) {
    throw ParseException('No amount adjacent to a credited/debited keyword');
  }
  final amountCents = located.cents;
  final type = located.type;

  final reference = _refRe.firstMatch(text)?.group(0);

  final date = _parseDate(text);

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

// Gap measurement and cents conversion now live in amount_adjacency.dart.
