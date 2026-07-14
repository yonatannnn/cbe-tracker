import 'dart:io';

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
  });

  group('parser purity', () {
    test('cbe_parser.dart has no Flutter/UI imports (pure Dart)', () {
      final source = File(
        'lib/core/parser/cbe_parser.dart',
      ).readAsStringSync();
      expect(source.contains('package:flutter/'), isFalse);
      expect(source.contains('dart:ui'), isFalse);
      expect(source.contains('package:flutter_test/'), isFalse);
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
