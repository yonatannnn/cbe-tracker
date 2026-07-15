/// Orchestrates screenshot → OCR → local parse → (AI fallback) → outcome.
library;

import 'dart:io';

import '../core/parser/cbe_parser.dart';
import 'gemini_fallback_service.dart';
import 'ocr_service.dart';

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
  const ParseUnreadable(this.rawText);

  /// Whatever OCR did manage to read; may be empty.
  final String rawText;
}

class ParsePipeline {
  ParsePipeline({required this.ocr, required this.ai});

  final OcrService ocr;
  final CbeAiFallback ai;

  /// Runs [image] through OCR and the parsers.
  ///
  /// A HIGH-confidence local parse wins outright. A ParseException or a
  /// LOW-confidence parse escalates to the AI fallback; if that returns null
  /// (gate failure, timeout, or offline) the result is [ParseUnreadable] — we
  /// never present a guess (§4).
  Future<ParseOutcome> parse(File image) async {
    final rawText = await ocr.extractText(image);

    try {
      final local = parseCbeText(rawText);
      if (local.confidence == Confidence.high) {
        return ParseSuccess(local);
      }
    } on ParseException {
      // No amount or no type — fall through to the AI fallback.
    }

    // Offline/network failures surface as null from the fallback itself, so no
    // separate connectivity check is needed.
    final aiParsed = await ai.parse(rawText);
    if (aiParsed != null) return ParseSuccess(aiParsed);

    return ParseUnreadable(rawText);
  }
}
