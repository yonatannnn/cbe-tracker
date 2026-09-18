/// Orchestrates screenshot → OCR → local parse → (AI fallback) → outcome.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../core/parser/cbe_parser.dart';
import '../core/parser/receipt_parser.dart';
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

const bool _logOcr = bool.fromEnvironment('LOG_OCR');

class ParsePipeline {
  ParsePipeline({
    required this.ocr,
    required this.ai,
    FutureOr<String?> Function()? ownerAccountSuffix,
  }) : _ownerAccountSuffix = ownerAccountSuffix ?? (() => null);

  final OcrService ocr;
  final CbeAiFallback ai;

  /// Her CBE account's last digits, for direction on sender's-screen
  /// receipts (see receipt_parser.dart). Read fresh on every parse — a
  /// value captured when the pipeline was built could predate her typing it.
  final FutureOr<String?> Function() _ownerAccountSuffix;

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
      // Development only: the raw OCR text, for building new receipt
      // templates. Off unless the build says --dart-define=LOG_OCR=true AND
      // it is a debug build, so a release can never leak receipt text.
      if (kDebugMode && _logOcr) {
        debugPrint('[ReceiptOCR] ${rawText.replaceAll('\n', ' ⏎ ')}');
      }
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

    ParsedCbeMessage? low;
    try {
      final local = parseReceiptText(
        rawText,
        ownerAccountSuffix: await _ownerAccountSuffix(),
      );
      if (local.confidence == Confidence.high) {
        logParseDiagnostic('regex accepted; gemini skipped');
        return ParseSuccess(local);
      }
      // Read, but with a gap (no reference, no date) or an unsettled
      // direction. A bank template that reached this far knows the layout
      // better than the model would; only the CBE keyword parser's LOW
      // result (a message shape we don't fully know) is worth a model call.
      if (local.bank != null) {
        logParseDiagnostic('template low_confidence; for review');
        return ParseSuccess(local);
      }
      low = local;
      logParseDiagnostic('regex low_confidence; trying gemini');
    } on ParseException {
      logParseDiagnostic('regex failed; trying gemini');
    }

    // Offline/network failures surface as null from the fallback itself, so no
    // separate connectivity check is needed.
    final aiParsed = await ai.parse(rawText, image: aiImage);
    if (aiParsed != null) return ParseSuccess(aiParsed);

    // The model could not improve on it: a LOW local read beats nothing.
    // The row is flagged and starts unchecked, so she still looks (§FR-3).
    if (low != null) {
      logParseDiagnostic('gemini unavailable; keeping low_confidence read');
      return ParseSuccess(low);
    }

    logParseDiagnostic('receipt unreadable');
    return ParseUnreadable(rawText, aiFailure: ai.lastFailure);
  }
}
