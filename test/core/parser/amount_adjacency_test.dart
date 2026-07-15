// The shared "amount nearest a credited/debited keyword, never the balance"
// rule. Both the regex parser and the Gemini gate call this, so it is tested
// once, here.

import 'package:cbe_tracker/core/parser/amount_adjacency.dart';
import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fixtures/cbe_messages.dart';

void main() {
  group('normalizeCbeText', () {
    test('collapses every whitespace run to one space', () {
      expect(normalizeCbeText('a\n\n b\t\tc  '), 'a b c');
      expect(normalizeCbeText('   '), '');
    });
  });

  group('findTypeKeywords', () {
    test('canonical set accepts only credited/debited', () {
      final hits = findTypeKeywords('was credited and also deposited');
      expect(hits.map((h) => h.type), [TxType.credit]);
    });

    test('extended set accepts the AI synonyms', () {
      final hits = findTypeKeywords(
        'was deposited then deducted',
        set: KeywordSet.extended,
      );
      expect(hits.map((h) => h.type), [TxType.credit, TxType.debit]);
    });

    test('tolerates an OCR break inside the word', () {
      final hits = findTypeKeywords(normalizeCbeText('has been Cred\nited'));
      expect(hits, hasLength(1));
      expect(hits.single.type, TxType.credit);
    });

    test('finds every occurrence, in order', () {
      final hits = findTypeKeywords('credited then debited then credited');
      expect(hits.map((h) => h.type), [
        TxType.credit,
        TxType.debit,
        TxType.credit,
      ]);
    });
  });

  group('findAmountOccurrences', () {
    test('matches grouped, plain, and whole-birr variants', () {
      expect(findAmountOccurrences('ETB 5,000.00', 500000), hasLength(1));
      expect(findAmountOccurrences('ETB 5000.00', 500000), hasLength(1));
      expect(findAmountOccurrences('ETB 5000', 500000), hasLength(1));
      expect(findAmountOccurrences('ETB 5,000', 500000), hasLength(1));
    });

    test('rejects a substring of a larger number', () {
      // "5,000.00" inside "145,000.00" is not an occurrence of 5,000.00.
      expect(findAmountOccurrences('ETB 145,000.00', 500000), isEmpty);
      // "5000" inside "5000.50" is not an occurrence of 5000.00.
      expect(findAmountOccurrences('ETB 5000.50', 500000), isEmpty);
    });

    test('tolerates an OCR break inside the number', () {
      final hits = findAmountOccurrences(
        normalizeCbeText('ETB 5,0\n00.00'),
        500000,
      );
      expect(hits, hasLength(1));
    });

    test('finds the same value in two places', () {
      final text = normalizeCbeText(
        'Credited with ETB 145,200.00 . Current Balance is ETB 145,200.00',
      );
      expect(findAmountOccurrences(text, 14520000), hasLength(2));
    });
  });

  group('isBalanceFigure', () {
    test('flags a figure preceded by a balance cue', () {
      final text = normalizeCbeText('Your Current Balance is ETB 145,200.00');
      final hit = findAmountOccurrences(text, 14520000).single;
      expect(isBalanceFigure(text, hit), isTrue);
    });

    test('does not flag the transaction figure', () {
      final text = normalizeCbeText('has been Credited with ETB 5,000.00 from');
      final hit = findAmountOccurrences(text, 500000).single;
      expect(isBalanceFigure(text, hit), isFalse);
    });

    test('cue must be within the lookback window', () {
      // Balance cue pushed well beyond kBalanceLookback chars.
      final text = normalizeCbeText(
        'Current Balance follows after a long stretch of padding text ETB '
        '145,200.00',
      );
      final hit = findAmountOccurrences(text, 14520000).single;
      expect(isBalanceFigure(text, hit), isFalse);
    });
  });

  group('findTransactionAmountNear — the shared rule', () {
    test('fixture 7: picks the adjacent amount, never the Current Balance', () {
      // Same fixture the regex parser is pinned against (Phase 1, fixture 7).
      final located = findTransactionAmountNear(fixtureTwoAmounts.raw);

      expect(located, isNotNull);
      expect(located!.cents, 750000, reason: 'adjacent amount, not 14520000');
      expect(located.type, TxType.credit);
      expect(located.gap, lessThan(kAdjacencyMaxGap));
    });

    test('fixture 1: agrees with the parser', () {
      final located = findTransactionAmountNear(fixtureCreditClean.raw);
      expect(located!.cents, 500000);
      expect(located.type, TxType.credit);
    });

    test('fixture 2: reads the debit direction from the keyword', () {
      final located = findTransactionAmountNear(fixtureDebitClean.raw);
      expect(located!.cents, 1230000);
      expect(located.type, TxType.debit);
    });

    test('fixture 4: large amount beats the larger balance', () {
      final located = findTransactionAmountNear(fixtureLargeAmount.raw);
      expect(located!.cents, 125000000);
    });

    test('candidateCents verifies a specific value (the AI gate path)', () {
      final good = findTransactionAmountNear(
        fixtureTwoAmounts.raw,
        candidateCents: 750000,
        maxGap: kAdjacencyMaxGap,
      );
      expect(good, isNotNull);

      // The balance figure must not verify, even though it is in the text.
      final balance = findTransactionAmountNear(
        fixtureTwoAmounts.raw,
        candidateCents: 14520000,
        maxGap: kAdjacencyMaxGap,
      );
      expect(balance, isNull);
    });

    test('maxGap bounds how far the amount may sit from the keyword', () {
      const text =
          'Credited today. Padding padding padding padding padding padding '
          'padding. ETB 9,999.00';
      expect(
        findTransactionAmountNear(text, candidateCents: 999900),
        isNotNull,
        reason: 'no maxGap → nearest wins regardless of distance',
      );
      expect(
        findTransactionAmountNear(text, candidateCents: 999900, maxGap: 60),
        isNull,
        reason: 'outside the window',
      );
    });

    test('no keyword → null', () {
      expect(
        findTransactionAmountNear('A transaction of ETB 5,000.00 occurred'),
        isNull,
      );
    });

    test('empty text → null', () {
      expect(findTransactionAmountNear('   '), isNull);
    });
  });

  group('centsFromText', () {
    test('integer cents, no double arithmetic', () {
      expect(centsFromText('5,000.00'), 500000);
      expect(centsFromText('1,250,000.00'), 125000000);
      expect(centsFromText('850'), 85000);
      expect(centsFromText('0.05'), 5);
      expect(centsFromText('5,000.00'), isA<int>());
    });

    test('rejects junk', () {
      expect(centsFromText('five'), isNull);
      expect(centsFromText('5.000'), isNull);
      expect(centsFromText(''), isNull);
    });
  });
}
