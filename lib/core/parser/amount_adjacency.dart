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
/// Phrases marking a figure as a balance, a fee, or a fee-inclusive total —
/// never the transaction itself.
///
/// FEES ARE EXCLUDED FROM THE TRANSACTION AMOUNT. Confirmed by the app owner,
/// and consistent with §4 ("the figure adjacent to the credited/debited
/// phrase"). CBE quotes both figures on every fee-bearing debit:
///
///   "You have successfully transferred ETB2.00 ... Service charge of ETB 0.50
///    and VAT(15%) of ETB0.08 ... with total of ETB2.61 .Your current balance
///    is ETB22,321.29."
///
/// We record 2.00. Consequence to be aware of: the account was actually
/// debited 2.61, so a branch balance drifts from the real CBE balance by the
/// fee on each outgoing transfer. Incoming payments carry no fees, so credits
/// are unaffected. To capture fees instead, the fix is here — not in the
/// caller.
const List<String> _balanceCues = [
  // SMS balance ("Your current balance is ETB31,897.92")
  'current balance',
  'balance is',
  // Fee-inclusive totals: the receipt's "Total Amount Debited: ETB1.61" and
  // the SMS's "with total of ETB2.61".
  'total amount debited',
  'total amount credited',
  'total amount',
  'total of',
  // Fee lines. CBE writes both "VAT (15%)" and "VAT(15%)".
  'service charge',
  'disaster recovery',
  'vat (',
  'vat(',
];

/// Wording the regex parser accepts.
///
/// Derived from 491 real CBE messages, not from §4's description — the live
/// formats are "You have received ETB x", "A debit transaction of ETB x", and
/// "You have successfully transferred ETB x", none of which say
/// credited/debited. Direction was verified against the corpus: `transferred`
/// was outgoing in 168/168 cases, `received` incoming in 96/96.
const Map<TxType, List<String>> _canonicalWords = {
  TxType.credit: ['credited', 'received'],
  TxType.debit: ['debited', 'debit', 'transferred', 'withdrawn'],
};

/// The above plus the synonyms the AI prompt is allowed to use.
const Map<TxType, List<String>> _extendedWords = {
  TxType.credit: ['credited', 'received', 'deposited'],
  TxType.debit: ['debited', 'debit', 'transferred', 'withdrawn', 'deducted', 'paid'],
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

  // Longest match first at any given position, so the dedupe below keeps
  // "debited" and drops the "debit" nested inside it.
  hits.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    return byStart != 0 ? byStart : b.end.compareTo(a.end);
  });

  // One hit per real occurrence: some vocabulary entries are prefixes of
  // others ("debit"/"debited"), which would otherwise double-count and skew
  // the gap measurement.
  final deduped = <KeywordHit>[];
  for (final hit in hits) {
    final swallowed = deduped.any(
      (kept) => kept.start <= hit.start && hit.end <= kept.end,
    );
    if (!swallowed) deduped.add(hit);
  }
  return deduped;
}

/// Every ETB-prefixed amount in [normalized] — the regex parser's candidate
/// set.
///
/// Decimals are OPTIONAL and may be one or two digits: across 491 real CBE
/// messages the amount was written with two decimals 1284 times, one decimal
/// 64 times ("ETB 2000.0") and none at all 4 times. Requiring `\.\d{2}` — as
/// §4 specifies — silently dropped every message in the latter two shapes.
///
/// The `\s*` also covers CBE's inconsistent spacing ("ETB2.00" vs "ETB 2.00"),
/// while account ids like "ETB-8402" are excluded because `-` isn't
/// whitespace.
List<AmountHit> findCurrencyAmounts(String normalized) {
  final re = RegExp(
    r'(?:ETB|Br)\s*([\d,]+(?:\.\d{1,2})?)',
    caseSensitive: false,
  );
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
    '$grouped.$twoDp', // 5,000.00
    '$plain.$twoDp', // 5000.00
    // CBE also writes a single decimal ("ETB 2000.0", "ETB 0.5").
    if (fraction % 10 == 0) '$grouped.${fraction ~/ 10}',
    if (fraction % 10 == 0) '$plain.${fraction ~/ 10}',
    if (fraction == 0) grouped, // 5,000
    if (fraction == 0) plain, // 5000
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
