// Pipeline branching with a fake OCR service and a fake AI fallback — no ML
// Kit, no network.

import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/services/gemini_fallback_service.dart';
import 'package:cbe_tracker/services/ocr_service.dart';
import 'package:cbe_tracker/services/parse_pipeline.dart';
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

class _FakeAi implements CbeAiFallback {
  _FakeAi(this.result);

  final ParsedCbeMessage? result;
  var callCount = 0;
  String? sawText;

  @override
  Future<ParsedCbeMessage?> parse(String rawText) async {
    callCount++;
    sawText = rawText;
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
    expect(ai.sawText, lowConfidenceText, reason: 'AI gets OCR text, no image');
  });

  test('ParseException escalates to AI; non-null → aiParsed success', () async {
    final ai = _FakeAi(aiResult);
    final pipeline = ParsePipeline(ocr: _FakeOcr(unparseableText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseSuccess>());
    expect((outcome as ParseSuccess).parsed.confidence, Confidence.aiParsed);
    expect(ai.callCount, 1);
  });

  test('LOW confidence + AI null → Unreadable (never a guess)', () async {
    final ai = _FakeAi(null);
    final pipeline = ParsePipeline(ocr: _FakeOcr(lowConfidenceText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseUnreadable>());
    expect((outcome as ParseUnreadable).rawText, lowConfidenceText);
  });

  test('ParseException + AI null (offline) → Unreadable', () async {
    final ai = _FakeAi(null);
    final pipeline = ParsePipeline(ocr: _FakeOcr(unparseableText), ai: ai);

    final outcome = await pipeline.parse(image);

    expect(outcome, isA<ParseUnreadable>());
    expect((outcome as ParseUnreadable).rawText, unparseableText);
  });

  test('empty OCR text → Unreadable', () async {
    final pipeline = ParsePipeline(ocr: _FakeOcr(''), ai: _FakeAi(null));
    expect(await pipeline.parse(image), isA<ParseUnreadable>());
  });
}
