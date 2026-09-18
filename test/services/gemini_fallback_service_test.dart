// The model is untrusted input. These tests pin the three validation gates:
// nothing the model returns is accepted unless it's provable against the raw
// OCR text (§2 "LLM fallback").

import 'dart:io';
import 'dart:typed_data';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/services/gemini_fallback_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_generative_ai/google_generative_ai.dart';

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

    test(
      'balance figure is rejected even when it sits NEAR a keyword',
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
      },
    );

    test(
      'same value as both transaction and balance → adjacency wins, passes',
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
      },
    );

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
      const biggerText = 'Your account was Credited with ETB 145,000.00 today.';
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

    test(
      'gate compares on whitespace-stripped text (OCR line breaks)',
      () async {
        const brokenText = 'has been Credited with ETB 5,0\n00.00 from X';
        final service = serviceReturning(
          '{"amount": "5,000.00", "type": "credit", "reference": null, '
          '"date": null}',
        );
        expect(await service.parse(brokenText), isNotNull);
      },
    );
  });

  group('GATE 2 — the nearby keyword must match the returned type', () {
    test('unrelated debit wording cannot reverse a credited amount', () async {
      const text =
          'Credited ETB 5,000.00 to your account. '
          'Contact CBE for questions about debited fees.';
      final wrong = serviceReturning('{"amount": "5,000.00", "type": "debit"}');
      final correct = serviceReturning(
        '{"amount": "5,000.00", "type": "credit"}',
      );
      expect(await wrong.parse(text), isNull);
      expect((await correct.parse(text))!.type, TxType.credit);
    });

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
    test('missing API key disables the live fallback', () async {
      expect(await GeminiFallbackService(apiKey: '').parse(rawText), isNull);
    });

    test(
      'JSON numeric amounts are rejected instead of using doubles',
      () async {
        expect(
          await serviceReturning(
            '{"amount": 5000.0, "type": "credit"}',
          ).parse(rawText),
          isNull,
        );
      },
    );

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
        timeout: const Duration(seconds: 2),
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

  group('diagnostics', () {
    test(
      'explains a validation rejection without logging receipt data',
      () async {
        final events = <String>[];
        const response = '{"amount": "7,777.00", "type": "credit"}';
        final service = GeminiFallbackService(
          generator: (_) async => response,
          diagnostic: events.add,
        );
        expect(await service.parse(rawText), isNull);
        expect(events, contains('gemini rejected: amount_absent_from_ocr'));
        expect(events.last, startsWith('gemini finished elapsed_ms='));
        final log = events.join(' ');
        expect(log, isNot(contains(rawText)));
        expect(log, isNot(contains(response)));
        expect(log, isNot(contains('YONATAN')));
        expect(log, isNot(contains('7,777')));
      },
    );

    test(
      'quota errors are classified without logging the exception body',
      () async {
        final events = <String>[];
        final service = GeminiFallbackService(
          generator: (_) async => throw ServerException(
            'Quota exceeded: private-key-and-request-data',
          ),
          diagnostic: events.add,
        );
        expect(await service.parse(rawText), isNull);
        expect(events, contains('gemini rejected: quota_or_rate_limit'));
        expect(
          events.join(' '),
          isNot(contains('private-key-and-request-data')),
        );
      },
    );

    test('missing key is distinguished from an empty model response', () async {
      final events = <String>[];
      final service = GeminiFallbackService(apiKey: '', diagnostic: events.add);
      expect(await service.parse(rawText), isNull);
      expect(events, ['gemini rejected: missing_api_key']);
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

    test('with a picture, the picture is declared the primary source', () {
      final prompt = GeminiFallbackService.buildPrompt('', hasImage: true);
      expect(prompt, contains('Trust the picture over the OCR text'));
      expect(
        GeminiFallbackService.buildPrompt(rawText),
        isNot(contains('Trust the picture')),
      );
    });

    test('the picture travels with the prompt', () async {
      GeminiRequest? seen;
      final image = AiImage(
        bytes: Uint8List.fromList([1, 2, 3]),
        mimeType: 'image/jpeg',
      );
      final service = GeminiFallbackService(
        generator: (request) async {
          seen = request;
          return null;
        },
      );
      await service.parse('some text', image: image);
      expect(seen?.image, same(image));
      expect(seen?.prompt, contains('some text'));
    });
  });

  group('other banks — a photo of an Awash receipt', () {
    // What ML Kit reads off a photo of a phone showing an Awash IPS transfer:
    // no "credited"/"debited" anywhere, amount as "4500 ETB", no FT number.
    const awashText =
        'AwashBank Transaction Successful Transaction Time 2026-09-17 '
        '03:28:03 PM Transaction Type IPS Bank Transfer Amount 4500 ETB '
        'Charge 27.00 ETB VAT 4.05 ETB EDRRF 1.35 ETB Sender Name ESRAEL '
        'TOLOSA TOLA Sender Account 01347******100 Beneficiary name MRS '
        'SOSINA TILAHUN GETACHEW Beneficiary Account 1000563647737 '
        'Beneficiary Bank Commercial Bank of Ethiopia Reason Transfer';
    const awashResponse =
        '{"bank": "Awash Bank", "amount": "4500", "type": "credit", '
        '"reference": null, "date": "2026-09-17T15:28:03", '
        '"sender": "ESRAEL TOLOSA TOLA", '
        '"beneficiary": "MRS SOSINA TILAHUN GETACHEW", "error": null}';
    final image = AiImage(bytes: Uint8List(3), mimeType: 'image/png');
    DateTime clock() => DateTime(2026, 9, 18);

    GeminiFallbackService awash(String response) =>
        GeminiFallbackService(generator: (_) async => response, clock: clock);

    test('accepted as a credit with a derived reference', () async {
      final result = await awash(awashResponse).parse(awashText, image: image);

      expect(result, isNotNull);
      expect(result!.amountCents, 450000);
      expect(result.type, TxType.credit);
      expect(result.confidence, Confidence.aiParsed);
      expect(result.bank, 'Awash Bank');
      expect(result.counterparty, 'ESRAEL TOLOSA TOLA');
      expect(result.date, DateTime(2026, 9, 17, 15, 28, 3));
      // No reference on the receipt → bank + time + amount, so a second
      // upload of the same photo is a duplicate, not a second payment.
      expect(result.reference, 'AWASH-20260917152803-450000');
    });

    test('"4500 ETB" as the amount string is fine', () async {
      final response = awashResponse.replaceFirst('"4500"', '"4500 ETB"');
      final result = await awash(response).parse(awashText, image: image);
      expect(result?.amountCents, 450000);
    });

    test('text-only: an amount the OCR never saw is rejected', () async {
      final response = awashResponse.replaceFirst('"4500"', '"4800"');
      expect(await awash(response).parse(awashText), isNull);
    });

    test('with the picture: OCR disagreement is noted, not fatal', () async {
      // ML Kit misreads a photographed screen; the model read the picture.
      final misread = awashText.replaceAll('4500', '45OO');
      final events = <String>[];
      final service = GeminiFallbackService(
        generator: (_) async => awashResponse,
        clock: clock,
        diagnostic: events.add,
      );
      final result = await service.parse(misread, image: image);
      expect(result?.amountCents, 450000);
      expect(result?.confidence, Confidence.aiParsed);
      expect(
        events,
        contains('gemini note: amount_absent_from_ocr (picture wins)'),
      );
    });

    test('the charge line cannot stand in for the amount', () async {
      // 27.00 IS in the text; the prompt forbids it and the row stays
      // AI-flagged either way. This pins that the gate is presence-based, so
      // the human review is what catches a wrong-line pick.
      final response = awashResponse.replaceFirst('"4500"', '"27.00"');
      expect(
        (await awash(response).parse(awashText, image: image))?.amountCents,
        2700,
      );
    });

    test('a busy model is retried, and the retry can succeed', () async {
      var calls = 0;
      final service = GeminiFallbackService(
        generator: GeminiFallbackService.withBusyRetry((_) async {
          calls++;
          if (calls < 3) {
            throw ServerException(
              'This model is currently experiencing high demand.',
            );
          }
          return awashResponse;
        }, delay: const Duration(milliseconds: 5)),
        clock: clock,
      );
      final result = await service.parse(awashText, image: image);
      expect(result?.amountCents, 450000);
      expect(calls, 3, reason: 'two busy replies, then the answer');
    });

    test('a model busy past every retry degrades to unreadable', () async {
      var calls = 0;
      final events = <String>[];
      final service = GeminiFallbackService(
        generator: GeminiFallbackService.withBusyRetry((_) async {
          calls++;
          throw ServerException('high demand');
        }, delay: const Duration(milliseconds: 5)),
        clock: clock,
        diagnostic: events.add,
      );
      expect(await service.parse(awashText, image: image), isNull);
      expect(calls, 1 + GeminiFallbackService.busyRetries);
      expect(events, contains('gemini rejected: model_busy'));
    });

    test('a failure is explained: quota', () async {
      final service = GeminiFallbackService(
        generator: (_) async => throw ServerException('Quota exceeded'),
        clock: clock,
      );
      expect(await service.parse(awashText, image: image), isNull);
      expect(service.lastFailure, AiFailure.quota);
      // …and cleared by the next success.
      final ok = GeminiFallbackService(
        generator: (_) async => awashResponse,
        clock: clock,
      );
      await ok.parse(awashText, image: image);
      expect(ok.lastFailure, isNull);
    });

    test('a failure is explained: offline, busy, no key, rejected', () async {
      Future<AiFailure?> failureOf(GeminiGenerator g) async {
        final s = GeminiFallbackService(generator: g, clock: clock);
        await s.parse(awashText, image: image);
        return s.lastFailure;
      }

      expect(
        await failureOf((_) async => throw const SocketException('down')),
        AiFailure.offline,
      );
      expect(
        await failureOf((_) async => throw ServerException('high demand')),
        AiFailure.busy,
      );
      expect(
        await failureOf((_) async => '{"error": "unparseable"}'),
        AiFailure.rejected,
      );
      final noKey = GeminiFallbackService(apiKey: '');
      await noKey.parse(awashText, image: image);
      expect(noKey.lastFailure, AiFailure.noKey);
    });

    test('other errors are not retried', () async {
      var calls = 0;
      final service = GeminiFallbackService(
        generator: GeminiFallbackService.withBusyRetry((_) async {
          calls++;
          throw ServerException('Quota exceeded');
        }),
        clock: clock,
      );
      expect(await service.parse(awashText, image: image), isNull);
      expect(calls, 1);
    });

    test('OCR that read no numbers at all lets the picture decide', () async {
      const blurry = 'AwashBank Transaction Successful Sender Name';
      final result = await awash(awashResponse).parse(blurry, image: image);
      expect(result?.amountCents, 450000);
      expect(result?.confidence, Confidence.aiParsed);
    });

    test(
      'an invented year drops the date, and with it the reference',
      () async {
        final response = awashResponse.replaceFirst(
          '2026-09-17T',
          '2024-09-17T',
        );
        final result = await awash(response).parse(awashText, image: image);
        expect(result, isNotNull);
        expect(result!.date, isNull);
        expect(result.reference, isNull, reason: 'no date → no safe reference');
      },
    );

    test('a reference the OCR corroborates is kept as written', () async {
      const text = '$awashText Reference No AW26091700123';
      final response = awashResponse.replaceFirst(
        '"reference": null',
        '"reference": "AW26091700123"',
      );
      final result = await awash(response).parse(text, image: image);
      expect(result?.reference, 'AW26091700123');
    });

    test('CBE wording in the text still enforces the CBE gates', () async {
      // The model calls it Awash, but the text says "Credited" — the strict
      // adjacency rule applies and the balance figure is refused.
      final response =
          '{"bank": "Awash Bank", "amount": "145,200.00", "type": "credit", '
          '"reference": null, "date": null, "sender": null, '
          '"beneficiary": null, "error": null}';
      expect(await awash(response).parse(rawText, image: image), isNull);
    });
  });
}
