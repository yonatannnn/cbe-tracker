import 'dart:io';

import 'package:cbe_tracker/core/parser/amount_adjacency.dart';
import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fixtures/cbe_messages.dart';

void main() {
  group('parseCbeText — clean cases (1–5)', () {
    for (final f in cleanFixtures) {
      test(f.name, () => _verify(f));
    }
  });

  group('parseCbeText — edge cases (6–12)', () {
    for (final f in edgeFixtures) {
      test(f.name, () => _verify(f));
    }
  });

  group('parseCbeText — real screenshots (13+)', () {
    for (final f in realFixtures) {
      test(f.name, () => _verify(f));
    }

    test('real receipt: the fee-inclusive total never wins', () {
      // "Total Amount Debited: ETB1.61" puts a keyword 5 chars from 1.61,
      // while the real "ETB 1.00 has been debited" is 10 chars away. Without
      // the summary-cue rule the parser silently records 1.61.
      final result = parseCbeText(fixtureRealReceiptDebit.raw);
      expect(result.amountCents, 100);
      expect(result.amountCents, isNot(161), reason: 'fee-inclusive total');
      expect(result.amountCents, isNot(50), reason: 'service charge');
    });

    test('real receipt: month-name date parses to HIGH confidence', () {
      // "on Jul 15, 2026 11:45 AM" — 12-hour clock, month name, no "at".
      final result = parseCbeText(fixtureRealReceiptDebit.raw);
      expect(result.date, DateTime(2026, 7, 15, 11, 45));
      expect(result.confidence, Confidence.high);
    });

    test('real receipt: account ids like ETB-8402 are not amounts', () {
      final result = parseCbeText(fixtureRealReceiptDebit.raw);
      expect(result.amountCents, isNot(840200));
      expect(result.amountCents, isNot(348700));
    });
  });

  group('fees are excluded from the transaction amount', () {
    // Settled business rule (confirmed by the app owner, consistent with §4):
    // record what was transferred, NOT what left the account. CBE quotes both
    // on every fee-bearing debit, so this must never drift.
    test('receipt: records 1.00, not the 1.61 total', () {
      expect(parseCbeText(fixtureRealReceiptDebit.raw).amountCents, 100);
    });

    test('SMS "debit transaction": records 2000.0, not the 2012.00 total', () {
      final result = parseCbeText(fixtureSmsDebitTransaction.raw);
      expect(result.amountCents, 200000);
      expect(result.amountCents, isNot(201200), reason: 'fee-inclusive total');
      expect(result.amountCents, isNot(1000), reason: 'service charge');
      expect(result.amountCents, isNot(2248112), reason: 'current balance');
    });

    test('SMS "transferred": records 2.00, not the 2.61 total', () {
      final result = parseCbeText(fixtureSmsTransferred.raw);
      expect(result.amountCents, 200);
      expect(result.amountCents, isNot(261), reason: 'fee-inclusive total');
      expect(result.amountCents, isNot(50), reason: 'service charge');
      expect(result.amountCents, isNot(8), reason: 'VAT');
      expect(result.amountCents, isNot(2232129), reason: 'current balance');
    });

    test('credits are unaffected — no fee lines on incoming money', () {
      final result = parseCbeText(fixtureSmsReceived.raw);
      expect(result.amountCents, 400000);
      expect(result.amountCents, isNot(3189792), reason: 'current balance');
    });
  });

  group('date formats', () {
    ParsedCbeMessage parseWithDate(String dateText) => parseCbeText(
      'ETB 5,000.00 has been credited $dateText with transaction ID: '
      'FT26196FZHT2.',
    );

    test('12-hour AM/PM conversion', () {
      expect(parseWithDate('on Jul 15, 2026 11:45 AM').date,
          DateTime(2026, 7, 15, 11, 45));
      expect(parseWithDate('on Jul 15, 2026 1:05 PM').date,
          DateTime(2026, 7, 15, 13, 5));
      expect(parseWithDate('on Jan 1, 2026 12:00 AM').date,
          DateTime(2026, 1, 1, 0, 0), reason: 'midnight is 00:00');
      expect(parseWithDate('on Dec 31, 2026 12:30 PM').date,
          DateTime(2026, 12, 31, 12, 30), reason: 'noon stays 12');
    });

    test('the SMS slash format still works', () {
      expect(parseWithDate('on 14/07/2026 at 10:42').date,
          DateTime(2026, 7, 14, 10, 42));
    });

    test('an unknown date shape leaves date null (LOW, never a guess)', () {
      expect(parseWithDate('sometime last Tuesday').date, isNull);
    });
  });

  group('money is integer cents (no double math)', () {
    test('amountCents is an int for every parsable fixture', () {
      for (final f in allFixtures.where((f) => !f.expectThrows)) {
        final result = parseCbeText(f.raw);
        expect(result.amountCents, isA<int>(), reason: f.name);
      }
    });

    test('large amount parses exactly, no floating-point drift', () {
      // 1,250,000.00 must be exactly 125000000 cents.
      final result = parseCbeText(fixtureLargeAmount.raw);
      expect(result.amountCents, 125000000);
      expect(result.amountCents, isA<int>());
    });
  });

  group('fixture 7 — nearest-amount selection', () {
    test('picks the amount adjacent to the keyword, not Current Balance', () {
      final result = parseCbeText(fixtureTwoAmounts.raw);
      expect(result.amountCents, 750000);
      expect(result.amountCents, isNot(14520000)); // the Current Balance
    });

    test('parser and the shared helper agree on the same amount', () {
      // parseCbeText delegates selection to findTransactionAmountNear, which
      // the Gemini gate also calls — one rule, verified from both directions.
      // See amount_adjacency_test.dart for the rule's own tests.
      final viaParser = parseCbeText(fixtureTwoAmounts.raw);
      final viaHelper = findTransactionAmountNear(fixtureTwoAmounts.raw);

      expect(viaHelper, isNotNull);
      expect(viaHelper!.cents, viaParser.amountCents);
      expect(viaHelper.type, viaParser.type);
    });
  });

  group('parser purity', () {
    test('every file in core/parser/ is pure Dart (no Flutter imports)', () {
      // CLAUDE.md: the CBE parser stays pure Dart — no Flutter imports in
      // core/parser/. Scans the whole directory so new files can't drift.
      final files = Directory('lib/core/parser')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));

      expect(files, isNotEmpty);
      for (final file in files) {
        final source = file.readAsStringSync();
        expect(
          source.contains('package:flutter/'),
          isFalse,
          reason: '${file.path} imports Flutter',
        );
        expect(
          source.contains('dart:ui'),
          isFalse,
          reason: '${file.path} imports dart:ui',
        );
        expect(
          source.contains('package:flutter_test/'),
          isFalse,
          reason: '${file.path} imports flutter_test',
        );
      }
    });
  });
}

/// Verifies a single fixture: either it throws [ParseException], or it parses
/// to exactly the expected fields.
void _verify(CbeFixture f) {
  if (f.expectThrows) {
    expect(
      () => parseCbeText(f.raw),
      throwsA(isA<ParseException>()),
      reason: f.name,
    );
    return;
  }

  final result = parseCbeText(f.raw);
  expect(result.type, f.type, reason: '${f.name}: type');
  expect(result.amountCents, f.amountCents, reason: '${f.name}: amountCents');
  expect(result.amountCents, isA<int>(), reason: '${f.name}: cents is int');
  expect(result.reference, f.reference, reason: '${f.name}: reference');
  expect(result.date, f.date, reason: '${f.name}: date');
  expect(result.confidence, f.confidence, reason: '${f.name}: confidence');
  expect(result.rawText, f.raw, reason: '${f.name}: rawText preserved');
}
