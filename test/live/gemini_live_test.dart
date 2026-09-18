// LIVE probe — talks to the real Gemini model. Skipped unless a key is given:
//
//   flutter test --dart-define=GEMINI_API_KEY=... \
//       --dart-define=RECEIPT_IMAGE=/path/to/photo.png test/live/gemini_live_test.dart
//
// Sends the image through the real GeminiFallbackService with no OCR text
// (a photo the OCR could not read) and prints what the gates accept. Meant for
// checking a new receipt layout before wiring it into the local parser.

import 'dart:io';

import 'package:cbe_tracker/services/gemini_fallback_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _key = String.fromEnvironment('GEMINI_API_KEY');
const _imagePath = String.fromEnvironment('RECEIPT_IMAGE');
const _ocrText = String.fromEnvironment('RECEIPT_OCR');

void main() {
  test(
    'live: the model reads the receipt image and the gates accept it',
    () async {
      final file = File(_imagePath);
      final mime = AiImage.mimeTypeFor(file.path)!;
      final image = AiImage(bytes: await file.readAsBytes(), mimeType: mime);

      final events = <String>[];
      final service = GeminiFallbackService(
        apiKey: _key,
        diagnostic: events.add,
      );
      final parsed = await service.parse(_ocrText, image: image);

      // ignore: avoid_print
      print(events.join('\n'));
      expect(parsed, isNotNull, reason: 'rejected: ${events.join(' | ')}');
      // ignore: avoid_print
      print(
        'ACCEPTED bank=${parsed!.bank} cents=${parsed.amountCents} '
        'type=${parsed.type.name} ref=${parsed.reference} date=${parsed.date} '
        'counterparty=${parsed.counterparty}',
      );
    },
    skip: _key.isEmpty || _imagePath.isEmpty
        ? 'needs --dart-define GEMINI_API_KEY and RECEIPT_IMAGE'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
