/// The "transaction amount sits next to the credited/debited keyword, and is
/// never the Current Balance figure" rule (§4, fixture 7).
///
/// ONE implementation, used by both callers:
///  * the local regex parser, to FIND the transaction amount;
///  * the Gemini gate, to VERIFY an amount the model returned.
///
/// Pure Dart — no Flutter imports (CLAUDE.md).
library;

import 'dart:math' as math;

import 'cbe_parser.dart' show TxType;

/// Which keyword vocabulary to accept.
enum KeywordSet {
  /// Only the canonical CBE wording — what the regex parser accepts (§4).
  canonical,

  /// Canonical plus the synonyms the AI prompt permits.
  extended,
}

/// A located amount within normalized text. [start]/[end] bracket the digits
/// only (not any "ETB" prefix), so offsets are comparable across callers.
class AmountHit {
  const AmountHit({
    required this.cents,
    required this.start,
    required this.end,
  });

  final int cents;
  final int start;
  final int end;
}

/// A located credited/debited-family keyword.
class KeywordHit {
  const KeywordHit({
    required this.type,
    required this.start,
    required this.end,
  });

  final TxType type;
  final int start;
  final int end;
}

/// An amount proven to sit next to a keyword.
class AmountAdjacency {
  const AmountAdjacency({required this.amount, required this.keyword, required this.gap});

  final AmountHit amount;
  final KeywordHit keyword;

  /// Characters between the amount and the keyword in normalized text.
  final int gap;

  int get cents => amount.cents;
  TxType get type => keyword.type;
}

/// Max characters between amount and keyword for the AI gate (§ follow-up).
const int kAdjacencyMaxGap = 60;

/// How far back to look for a decoy cue before an amount.
const int kBalanceLookback = 25;

/// Phrases that mark a figure as a SUMMARY or FEE, not the transaction.
///
/// Two real shapes are covered:
///  * the SMS "Your Current Balance is ETB 145,200.00";
///  * the app receipt "Total Amount Debited: ETB1.61 with Service Charge of
///    ETB0.50, VAT (15%) of ETB0.08 and Disaster Recovery (5%) of ETB0.03".
///
/// The receipt line is especially dangerous: "Total Amount Debited" CONTAINS
/// the keyword "Debited", so without this list the fee-inclusive total sits
/// closer to a keyword than the real amount and wins.
const List<String> _balanceCues = [
  // SMS balance
  'current balance',
  'balance is',
  // Receipt summary total
  'total amount debited',
  'total amount credited',
  'total amount',
  // Receipt fee lines
  'service charge',
  'disaster recovery',
  'vat (',
];

const Map<TxType, List<String>> _canonicalWords = {
  TxType.credit: ['credited'],
  TxType.debit: ['debited'],
};

const Map<TxType, List<String>> _extendedWords = {
  TxType.credit: ['credited', 'received', 'deposited'],
  TxType.debit: ['debited', 'deducted', 'paid'],
};

/// Collapses every whitespace run to a single space. All offsets used by this
/// library are indices into the result.
String normalizeCbeText(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Builds a whitespace-tolerant matcher, so an OCR line break inside a word or
/// a number ("Cred ited", "5,0 00.00") still matches once normalized.
RegExp _loose(String literal) =>
    RegExp(literal.split('').map(RegExp.escape).join(r'\s*'), caseSensitive: false);

/// All credited/debited-family keyword occurrences in [normalized].
List<KeywordHit> findTypeKeywords(
  String normalized, {
  KeywordSet set = KeywordSet.canonical,
}) {
  final words = set == KeywordSet.canonical ? _canonicalWords : _extendedWords;
  final hits = <KeywordHit>[];
  for (final entry in words.entries) {
    for (final word in entry.value) {
      for (final match in _loose(word).allMatches(normalized)) {
        hits.add(
          KeywordHit(type: entry.key, start: match.start, end: match.end),
        );
      }
    }
  }
  hits.sort((a, b) => a.start.compareTo(b.start));
  return hits;
}

/// Every "ETB 5,000.00"-style amount in [normalized] — the regex parser's
/// candidate set.
List<AmountHit> findCurrencyAmounts(String normalized) {
  final re = RegExp(r'(?:ETB|Br)\s*([\d,]+\.\d{2})', caseSensitive: false);
  final hits = <AmountHit>[];
  for (final match in re.allMatches(normalized)) {
    final digits = match.group(1)!;
    final cents = centsFromText(digits);
    if (cents == null) continue;
    // Bracket the digits only, so gaps are measured the same way as in
    // findAmountOccurrences.
    hits.add(
      AmountHit(
        cents: cents,
        start: match.end - digits.length,
        end: match.end,
      ),
    );
  }
  return hits;
}

/// Every occurrence of the exact value [cents] in [normalized], written any of
/// the ways CBE renders it ("5,000.00", "5000.00", and for whole birr "5,000"
/// / "5000") — the AI gate's candidate set.
List<AmountHit> findAmountOccurrences(String normalized, int cents) {
  final birr = cents ~/ 100;
  final fraction = cents % 100;
  final plain = birr.toString();
  final grouped = _group(birr);
  final twoDp = fraction.toString().padLeft(2, '0');

  final variants = <String>{
    '$grouped.$twoDp',
    '$plain.$twoDp',
    if (fraction == 0) grouped,
    if (fraction == 0) plain,
  };

  final hits = <AmountHit>[];
  final seen = <int>{};
  for (final variant in variants) {
    for (final match in _loose(variant).allMatches(normalized)) {
      if (!_hasNumericBoundary(normalized, match.start, match.end)) continue;
      if (!seen.add(match.start)) continue; // same spot via another variant
      hits.add(
        AmountHit(cents: cents, start: match.start, end: match.end),
      );
    }
  }
  hits.sort((a, b) => a.start.compareTo(b.start));
  return hits;
}

/// Rejects a match that is really part of a larger number: "5,000.00" inside
/// "145,000.00", or "5000" inside "5000.50".
bool _hasNumericBoundary(String text, int start, int end) {
  if (start > 0 && RegExp(r'[\d,.]').hasMatch(text[start - 1])) return false;
  if (end < text.length) {
    final after = text[end];
    if (RegExp(r'\d').hasMatch(after)) return false;
    // "5000" must not be the whole-birr part of "5000.50".
    if (after == '.' &&
        end + 1 < text.length &&
        RegExp(r'\d').hasMatch(text[end + 1])) {
      return false;
    }
  }
  return true;
}

/// True when [amount] is preceded within [kBalanceLookback] characters by a
/// balance cue — i.e. it is the Current Balance figure, not the transaction.
bool isBalanceFigure(String normalized, AmountHit amount) {
  final from = math.max(0, amount.start - kBalanceLookback);
  final before = normalized.substring(from, amount.start).toLowerCase();
  return _balanceCues.any(before.contains);
}

/// Picks the amount nearest a keyword, skipping balance figures.
///
/// This is the shared rule. [maxGap] bounds how far the amount may sit from the
/// keyword (the AI gate passes [kAdjacencyMaxGap]; the regex parser passes null
/// and simply takes the nearest).
///
/// When the same value appears both next to the keyword and in the balance
/// clause, the keyword-adjacent occurrence wins — the balance one is skipped,
/// so adjacency decides.
AmountAdjacency? selectAmountNearKeyword({
  required String normalized,
  required List<AmountHit> amounts,
  required List<KeywordHit> keywords,
  int? maxGap,
}) {
  AmountAdjacency? best;
  for (final amount in amounts) {
    if (isBalanceFigure(normalized, amount)) continue;
    for (final keyword in keywords) {
      final gap = _gap(amount, keyword);
      if (maxGap != null && gap > maxGap) continue;
      if (best == null || gap < best.gap) {
        best = AmountAdjacency(amount: amount, keyword: keyword, gap: gap);
      }
    }
  }
  return best;
}

/// One-call convenience over [selectAmountNearKeyword].
///
/// Pass [candidateCents] to verify a specific value (AI gate); omit it to find
/// whichever ETB amount sits nearest a keyword (regex parser).
AmountAdjacency? findTransactionAmountNear(
  String rawText, {
  int? candidateCents,
  int? maxGap,
  KeywordSet keywordSet = KeywordSet.canonical,
}) {
  final normalized = normalizeCbeText(rawText);
  if (normalized.isEmpty) return null;
  return selectAmountNearKeyword(
    normalized: normalized,
    amounts: candidateCents == null
        ? findCurrencyAmounts(normalized)
        : findAmountOccurrences(normalized, candidateCents),
    keywords: findTypeKeywords(normalized, set: keywordSet),
    maxGap: maxGap,
  );
}

/// Characters between an amount and a keyword; 0 when they overlap.
int _gap(AmountHit amount, KeywordHit keyword) {
  if (amount.start >= keyword.end) return amount.start - keyword.end;
  if (keyword.start >= amount.end) return keyword.start - amount.end;
  return 0;
}

/// "1,250,000.00" / "5000" → integer cents. Null when not a plain amount.
/// Integer math only — money never touches a double (CLAUDE.md).
int? centsFromText(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[,\s]'), '');
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(cleaned);
  if (match == null) return null;
  final fraction = (match.group(2) ?? '0').padRight(2, '0');
  return int.parse(match.group(1)!) * 100 + int.parse(fraction);
}

String _group(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}
