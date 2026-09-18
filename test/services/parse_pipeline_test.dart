// Pipeline branching with a fake OCR service and a fake AI fallback — no ML
// Kit, no network.

import 'dart:async';
import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/services/gemini_fallback_service.dart';
import 'package:cbe_tracker/services/ocr_service.dart';
import 'package:cbe_tracker/services/parse_pipeline.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeOcr implements OcrService {
  _FakeOcr(this.text);

  final String text;
  var disposed = false;

  @override
  Future<String> extractText(File image) async => text;

  @override
  Future<void> dispose() async => disposed = true;
}

class _CallbackOcr implements OcrService {
  _CallbackOcr(this.read);
  final Future<String> Function() read;

  @override
  Future<String> extractText(File image) => read();

  @override
  Future<void> dispose() async {}
}

class _FakeAi implements CbeAiFallback {
  _FakeAi(this.result);

  final ParsedCbeMessage? result;
  var callCount = 0;
  String? sawText;
  AiImage? sawImage;

  @override
  AiFailure? lastFailure;

  @override
  Future<ParsedCbeMessage?> parse(String rawText, {AiImage? image}) async {
    callCount++;
    sawText = rawText;
    sawImage = image;
    return result;
  }
}

void main() {
  // Never read — the fake OCR ignores it.
  final image = File('does_not_exist.png');

  const highConfidenceText =
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '5,000.00 from ABEBE KEBEDE on 14/07/2026 at 10:42. Your Current '
      'Balance is ETB 145,200.00. Thank you for Banking with CBE! '
      'https://apps.cbe.com.et:100/?id=FT26195XKQ8T12341234';

  // Amount + type present, but the reference is truncated → LOW confidence.
  const lowConfidenceText =
      'Dear YONATAN your Account 1*****1234 has been Credited with ETB '
      '3,200.00 from SARA on 14/07/2026 at 12:30. '
      'https://apps.cbe.com.et:100/?id=FT2619';

  // No amount → parseCbeText throws.
  const unparseableText = 'Dear YONATAN, thank you for Banking with CBE!';

  final aiResult = ParsedCbeMessage(
    amountCents: 320000,
    type: TxType.credit,
    reference: 'FT26195XKQ8T',
    date: DateTime(2026, 7, 14, 12, 30),
    confidence: Confidence.aiParsed,
    rawText: lowConfidenceText,
  );

  test('HIGH confidence local parse wins — AI is never called', () async {
    final ai = _FakeAi(aiResult);
    final pipeline = ParsePipeline(ocr: _FakeOcr(highConfidenceText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseSuccess>());
    final parsed = (outcome as ParseSuccess).parsed;
    expect(parsed.confidence, Confidence.high);
    expect(parsed.amountCents, 500000);
    expect(ai.callCount, 0, reason: 'no network call when local parse is good');
  });

  test('LOW confidence escalates to AI; non-null → aiParsed success', () async {
    final ai = _FakeAi(aiResult);
    final pipeline = ParsePipeline(ocr: _FakeOcr(lowConfidenceText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseSuccess>());
    expect((outcome as ParseSuccess).parsed.confidence, Confidence.aiParsed);
    expect(ai.callCount, 1);
    expect(ai.sawText, lowConfidenceText, reason: 'AI gets the OCR text');
    expect(ai.sawImage, isNull, reason: 'the file does not exist → text only');
  });

  test('ParseException escalates to AI; non-null → aiParsed success', () async {
    final ai = _FakeAi(aiResult);
    final pipeline = ParsePipeline(ocr: _FakeOcr(unparseableText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseSuccess>());
    expect((outcome as ParseSuccess).parsed.confidence, Confidence.aiParsed);
    expect(ai.callCount, 1);
  });

  test('LOW confidence + AI null → the LOW read, flagged for review', () async {
    // A parsed amount and type with a missing reference is not a guess; it is
    // a real read with a gap. Throwing it away sent her to type the figures
    // by hand. It comes back LOW, so the row starts unchecked (§FR-3).
    final ai = _FakeAi(null);
    final pipeline = ParsePipeline(ocr: _FakeOcr(lowConfidenceText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseSuccess>());
    expect((outcome as ParseSuccess).parsed.confidence, Confidence.low);
    expect(ai.callCount, 1, reason: 'the model was still asked first');
  });

  test('a bank template read with a gap skips the model entirely', () async {
    // A telebirr "transferred" SMS: amount, reference and date all read, only
    // the direction unsettled. Nothing a model could add.
    const telebirr =
        'Dear Ephrem You have transferred ETB 600.00 to asefa aynalem on '
        '31/05/2026. Your transaction number is DEV6HKJX7K.';
    final ai = _FakeAi(null);
    final pipeline = ParsePipeline(ocr: _FakeOcr(telebirr), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseSuccess>());
    final parsed = (outcome as ParseSuccess).parsed;
    expect(parsed.bank, 'telebirr');
    expect(parsed.confidence, Confidence.low);
    expect(ai.callCount, 0);
  });

  test('the account suffix settles a CBE app receipt locally', () async {
    const receipt =
        'ETB 1,000.00 has been debited from Getu Tolosa Tola ETB-4351 for '
        'Sosina Tilahun Getachew ETB-7737 on Sep 15, 2026 03:38 PM with '
        'transaction ID: FT26258GYG1C. Reason: MB Transfer';
    final ai = _FakeAi(null);
    final pipeline = ParsePipeline(
      ocr: _FakeOcr(receipt),
      ai: ai,
      ownerAccountSuffix: () => '7737',
    );

    final outcome = await pipeline.parse(image);

    final parsed = (outcome as ParseSuccess).parsed;
    expect(parsed.type, TxType.credit);
    expect(parsed.confidence, Confidence.high);
    expect(ai.callCount, 0);
  });

  test('ParseException + AI null (offline) → Unreadable', () async {
    final ai = _FakeAi(null);
    final pipeline = ParsePipeline(ocr: _FakeOcr(unparseableText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseUnreadable>());
    expect((outcome as ParseUnreadable).rawText, unparseableText);
  });

  test(
    'regex failure uses validated Gemini extraction for unusual wording',
    () async {
      const text =
          'You received 5,000.00 Birr on 14/07/2026 at 10:42. '
          'Reference FT26195XKQ8T. Current Balance ETB 145,200.00.';
      expect(() => parseCbeText(text), throwsA(isA<ParseException>()));
      var calls = 0;
      final pipeline = ParsePipeline(
        ocr: _FakeOcr(text),
        ai: GeminiFallbackService(
          generator: (request) async {
            calls++;
            expect(request.prompt, contains(text));
            return '{"amount": "5,000.00", "type": "credit", '
                '"reference": "FT26195XKQ8T", "date": "2026-07-14T10:42:00", '
                '"error": null}';
          },
        ),
      );

      final outcome = await pipeline.parse(image);
      expect(outcome, isA<ParseSuccess>());
      final parsed = (outcome as ParseSuccess).parsed;
      expect(parsed.amountCents, 500000);
      expect(parsed.type, TxType.credit);
      expect(parsed.reference, 'FT26195XKQ8T');
      expect(parsed.confidence, Confidence.aiParsed);
      expect(calls, 1);
    },
  );

  test('regex failure and invented Gemini amount remain unreadable', () async {
    const text = 'You received 5,000.00 Birr.';
    final pipeline = ParsePipeline(
      ocr: _FakeOcr(text),
      ai: GeminiFallbackService(
        generator: (_) async => '{"amount": "9,000.00", "type": "credit"}',
      ),
    );

    final outcome = await pipeline.parse(image);
    expect(outcome, isA<ParseUnreadable>());
    expect((outcome as ParseUnreadable).rawText, text);
  });

  test(
    'native OCR failure is unreadable and the next image still works',
    () async {
      var calls = 0;
      final ai = _FakeAi(null);
      final pipeline = ParsePipeline(
        ocr: _CallbackOcr(() async {
          if (calls++ == 0) {
            throw PlatformException(
              code: 'error',
              message: 'ML Kit init failed',
            );
          }
          return highConfidenceText;
        }),
        ai: ai,
      );
      final failed = await pipeline.parse(image);
      expect(failed, isA<ParseUnreadable>());
      expect((failed as ParseUnreadable).rawText, isEmpty);
      expect(await pipeline.parse(image), isA<ParseSuccess>());
      expect(ai.callCount, 0);
    },
  );

  testWidgets('stalled OCR times out without calling Gemini', (tester) async {
    final pending = Completer<String>();
    final ai = _FakeAi(null);
    final pipeline = ParsePipeline(
      ocr: _CallbackOcr(() => pending.future),
      ai: ai,
    );
    ParseOutcome? outcome;
    unawaited(pipeline.parse(image).then((value) => outcome = value));
    await tester.pump(ParsePipeline.ocrTimeout);
    expect(outcome, isA<ParseUnreadable>());
    expect(ai.callCount, 0);

    // A late native response must not replace the already returned outcome.
    pending.complete(highConfidenceText);
    await tester.pump();
    expect(outcome, isA<ParseUnreadable>());
  });

  test('empty OCR text → Unreadable', () async {
    final pipeline = ParsePipeline(ocr: _FakeOcr(''), ai: _FakeAi(null));
    expect(await pipeline.parse(image), isA<ParseUnreadable>());
  });

  test(
    'a real image file is sent to the fallback with its MIME type',
    () async {
      final temp = await Directory.systemTemp.createTemp('cbe_pipeline');
      addTearDown(() => temp.deleteSync(recursive: true));
      final jpg = File('${temp.path}/receipt.jpg')..writeAsBytesSync([1, 2, 3]);

      final ai = _FakeAi(null);
      final pipeline = ParsePipeline(ocr: _FakeOcr(''), ai: ai);
      await pipeline.parse(jpg);

      expect(ai.callCount, 1);
      expect(ai.sawImage?.mimeType, 'image/jpeg');
      expect(ai.sawImage?.bytes, [1, 2, 3]);
    },
  );
}
