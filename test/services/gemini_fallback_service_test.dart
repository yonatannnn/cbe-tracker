// The model is untrusted input. These tests pin the three validation gates:
// nothing the model returns is accepted unless it's provable against the raw
// OCR text (§2 "LLM fallback").

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/services/gemini_fallback_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A realistic CBE message: transaction 5,000.00, balance 145,200.00.
  const rawText =
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '5,000.00 from ABEBE KEBEDE on 14/07/2026 at 10:42. Your Current '
      'Balance is ETB 145,200.00. Thank you for Banking with CBE! '
      'https://apps.cbe.com.et:100/?id=FT26195XKQ8T12341234';

  /// Builds a service whose "model" always returns [response].
  GeminiFallbackService serviceReturning(String? response) =>
      GeminiFallbackService(generator: (_) async => response);

  group('clean pass', () {
    test('valid response → aiParsed with parsed fields', () async {
      final service = serviceReturning('''
        {"amount": "5,000.00", "type": "credit",
         "reference": "FT26195XKQ8T", "date": "2026-07-14T10:42:00"}
      ''');

      final result = await service.parse(rawText);

      expect(result, isNotNull);
      expect(result!.amountCents, 500000);
      expect(result.type, TxType.credit);
      expect(result.reference, 'FT26195XKQ8T');
      expect(result.date, DateTime(2026, 7, 14, 10, 42));
      expect(result.confidence, Confidence.aiParsed);
      expect(result.rawText, rawText);
      expect(result.amountCents, isA<int>());
    });

    test('null reference is allowed (gate 3 only runs when present)', () async {
      final service = serviceReturning(
        '{"amount": "5000.00", "type": "credit", "reference": null, '
        '"date": null}',
      );

      final result = await service.parse(rawText);

      expect(result, isNotNull);
      expect(result!.reference, isNull);
      expect(result.date, isNull);
      expect(result.confidence, Confidence.aiParsed);
    });

    test('JSON wrapped in prose/fences is still read', () async {
      final service = serviceReturning(
        'Here you go:\n```json\n{"amount": "5,000.00", "type": "credit", '
        '"reference": null, "date": null}\n```',
      );
      expect(await service.parse(rawText), isNotNull);
    });
  });

  group('GATE 1 — amount must sit adjacent to a credited/debited keyword', () {
    test('hallucinated amount → null', () async {
      final service = serviceReturning(
        '{"amount": "7,777.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('returning the Current Balance figure → null', () async {
      // 145,200.00 IS verbatim in the text, so mere presence can't catch it.
      // Adjacency does: the balance sits far from "Credited" AND is preceded
      // by a balance cue.
      final service = serviceReturning(
        '{"amount": "145,200.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('balance figure is rejected even when it sits NEAR a keyword',
        () async {
      // Here the balance is only ~29 chars from "Credited" — inside the
      // adjacency window. Only the balance-cue rule rejects it, so this test
      // is what proves that rule earns its keep.
      const nearText =
          'Your account was Credited. Your Current Balance is ETB 145,200.00.';
      final service = serviceReturning(
        '{"amount": "145,200.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(nearText), isNull);
    });

    test('same value as both transaction and balance → adjacency wins, passes',
        () async {
      // Legal but rare: a 145,200.00 transaction that lands on a 145,200.00
      // balance. The keyword-adjacent occurrence must carry the parse.
      const equalText =
          'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
          '145,200.00 from ABEBE KEBEDE on 14/07/2026 at 10:42. Your Current '
          'Balance is ETB 145,200.00. Thank you for Banking with CBE!';
      final service = serviceReturning(
        '{"amount": "145,200.00", "type": "credit", "reference": null, '
        '"date": null}',
      );

      final result = await service.parse(equalText);

      expect(result, isNotNull);
      expect(result!.amountCents, 14520000);
      expect(result.confidence, Confidence.aiParsed);
    });

    test('an amount too far from any keyword → null', () async {
      // Present in the text but ~90 chars from "Credited": outside the window.
      const farText =
          'Your account was Credited with something today. Lorem ipsum dolor '
          'sit amet padding padding padding here. Fee note: ETB 9,999.00 '
          'applies to premium accounts.';
      final service = serviceReturning(
        '{"amount": "9,999.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(farText), isNull);
    });

    test('substring of a larger number is not a match', () async {
      // "5,000.00" appears inside "145,000.00" — must not satisfy the gate.
      const biggerText =
          'Your account was Credited with ETB 145,000.00 today.';
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(biggerText), isNull);
    });

    test('digit-transposed amount → null', () async {
      final service = serviceReturning(
        '{"amount": "5,600.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('non-numeric amount → null', () async {
      final service = serviceReturning(
        '{"amount": "five thousand", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('accepts an unseparated variant when the text has commas', () async {
      // "5000.00" is not literally in the text, but "5,000.00" is; the gate
      // checks all variants of the same cents value.
      final service = serviceReturning(
        '{"amount": "5000.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNotNull);
    });

    test('whole-birr variant matches text without decimals', () async {
      const wholeText = 'Your account has been Credited with ETB 850 today.';
      final service = serviceReturning(
        '{"amount": "850.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(wholeText), isNotNull);
    });

    test('gate compares on whitespace-stripped text (OCR line breaks)',
        () async {
      const brokenText = 'has been Credited with ETB 5,0\n00.00 from X';
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(brokenText), isNotNull);
    });
  });

  group('GATE 2 — a keyword matching the returned type must exist', () {
    test('type contradicts the text → null', () async {
      // Text says Credited; model claims debit.
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "debit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('unknown type value → null', () async {
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "transfer", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('synonyms are accepted: "deposited" counts as credit', () async {
      const depositText = 'ETB 5,000.00 was deposited to your account.';
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "credit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(depositText), isNotNull);
    });

    test('synonyms are accepted: "deducted" counts as debit', () async {
      const deductText = 'ETB 5,000.00 was deducted from your account.';
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "debit", "reference": null, '
        '"date": null}',
      );
      expect(await service.parse(deductText), isNotNull);
    });
  });

  group('GATE 3 — reference format and presence', () {
    test('bad reference format → null', () async {
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "credit", "reference": "XY123", '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('too-short FT reference → null', () async {
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "credit", "reference": "FT2619", '
        '"date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });

    test('well-formed but absent from the text → null', () async {
      final service = serviceReturning(
        '{"amount": "5,000.00", "type": "credit", '
        '"reference": "FTZZZZZZZZZZ", "date": null}',
      );
      expect(await service.parse(rawText), isNull);
    });
  });

  group('degrades silently', () {
    test('model reports unparseable → null', () async {
      expect(
        await serviceReturning('{"error": "unparseable"}').parse(rawText),
        isNull,
      );
    });

    test('null response → null', () async {
      expect(await serviceReturning(null).parse(rawText), isNull);
    });

    test('non-JSON response → null', () async {
      expect(await serviceReturning('I cannot help').parse(rawText), isNull);
    });

    test('missing fields → null', () async {
      expect(
        await serviceReturning('{"type": "credit"}').parse(rawText),
        isNull,
      );
    });

    test('a thrown exception → null, never rethrown', () async {
      final service = GeminiFallbackService(
        generator: (_) async => throw Exception('network down'),
      );
      expect(await service.parse(rawText), isNull);
    });

    test('a timeout → null', () async {
      final service = GeminiFallbackService(
        generator: (_) => Future.delayed(
          const Duration(seconds: 30),
          () => '{"amount": "5,000.00", "type": "credit"}',
        ),
      );
      expect(await service.parse(rawText), isNull);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('empty OCR text is never sent to the model', () async {
      var called = false;
      final service = GeminiFallbackService(
        generator: (_) async {
          called = true;
          return '{"amount": "1.00", "type": "credit"}';
        },
      );
      expect(await service.parse('   '), isNull);
      expect(called, isFalse);
    });
  });

  group('prompt', () {
    test('sends the OCR text and the adjacency/never-guess rules', () {
      final prompt = GeminiFallbackService.buildPrompt(rawText);
      expect(prompt, contains(rawText));
      expect(prompt, contains('NEVER return the "Current Balance" figure'));
      expect(prompt, contains('Never guess digits'));
      expect(prompt, contains('unparseable'));
    });
  });
}
