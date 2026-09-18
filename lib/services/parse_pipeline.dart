/// Orchestrates screenshot → OCR → local parse → (AI fallback) → outcome.
library;

import 'dart:async';
import 'dart:io';

import '../core/parser/cbe_parser.dart';
import 'gemini_fallback_service.dart';
import 'ocr_service.dart';
import 'parse_diagnostics.dart';

/// Result of running a screenshot through the pipeline.
sealed class ParseOutcome {
  const ParseOutcome();
}

/// The message was read confidently enough to show for confirmation.
class ParseSuccess extends ParseOutcome {
  const ParseSuccess(this.parsed);

  final ParsedCbeMessage parsed;
}

/// Nothing trustworthy could be read — the UI must ask the user to retake or
/// enter manually, and must never save silently (§FR-2).
class ParseUnreadable extends ParseOutcome {
  const ParseUnreadable(this.rawText, {this.aiFailure});

  /// Whatever OCR did manage to read; may be empty.
  final String rawText;

  /// Why the AI fallback could not help, when that is the story: out of
  /// quota, busy, offline. Null when it simply could not read the picture.
  final AiFailure? aiFailure;

  /// True when the picture may be perfectly readable and the AI service is
  /// what failed — so the UI says "try again later", not "retake".
  bool get aiUnavailable => switch (aiFailure) {
    AiFailure.quota ||
    AiFailure.busy ||
    AiFailure.offline ||
    AiFailure.noKey => true,
    _ => false,
  };
}

/// What to tell her when nothing could be read.
String unreadableMessage(AiFailure? failure) => switch (failure) {
  AiFailure.quota =>
    'AI reading limit reached for today — add it manually, or try again '
        'tomorrow',
  AiFailure.busy => 'The AI reader is busy right now — try again in a minute',
  AiFailure.offline => 'No internet — the AI reader needs a connection',
  AiFailure.noKey => 'The AI reader is not set up in this build',
  _ => "Couldn't read this picture",
};

class ParsePipeline {
  ParsePipeline({required this.ocr, required this.ai});

  final OcrService ocr;
  final CbeAiFallback ai;

  /// Bounds native OCR initialization and image preparation as well as reading.
  static const Duration ocrTimeout = Duration(seconds: 20);

  /// Runs [image] through OCR and the parsers.
  ///
  /// A HIGH-confidence local parse wins outright. A ParseException or a
  /// LOW-confidence parse escalates to the AI fallback; if that returns null
  /// (gate failure, timeout, or offline) the result is [ParseUnreadable] — we
  /// never present a guess (§4).
  Future<ParseOutcome> parse(File image) async {
    final watch = Stopwatch()..start();
    logParseDiagnostic('ocr started');
    final String rawText;
    try {
      rawText = await ocr.extractText(image).timeout(ocrTimeout);
      logParseDiagnostic(
        'ocr completed chars=${rawText.length} elapsed_ms=${watch.elapsedMilliseconds}',
      );
    } on Object catch (error) {
      logParseDiagnostic(
        'ocr failed reason=${error is TimeoutException ? 'timeout' : error.runtimeType} '
        'elapsed_ms=${watch.elapsedMilliseconds}',
      );
      // Native initialization, corrupt images, and stalled OCR must finish
      // the current row so bulk processing can continue to the next image.
      // With no OCR text there is nothing trustworthy to send to Gemini.
      return const ParseUnreadable('');
    }

    // The picture goes to the fallback too: a photo of a phone screen or
    // another bank's layout is what OCR text alone can't carry. A missing or
    // unsupported file just means text-only, as before.
    AiImage? aiImage;
    final mimeType = AiImage.mimeTypeFor(image.path);
    if (mimeType != null) {
      try {
        aiImage = AiImage(bytes: await image.readAsBytes(), mimeType: mimeType);
      } on Object {
        aiImage = null;
      }
    }

    try {
      final local = parseCbeText(rawText);
      if (local.confidence == Confidence.high) {
        logParseDiagnostic('regex accepted; gemini skipped');
        return ParseSuccess(local);
      }
      logParseDiagnostic('regex low_confidence; trying gemini');
    } on ParseException {
      logParseDiagnostic('regex failed; trying gemini');
    }

    // Offline/network failures surface as null from the fallback itself, so no
    // separate connectivity check is needed.
    final aiParsed = await ai.parse(rawText, image: aiImage);
    if (aiParsed != null) return ParseSuccess(aiParsed);

    logParseDiagnostic('receipt unreadable');
    return ParseUnreadable(rawText, aiFailure: ai.lastFailure);
  }
}
