/// Gemini Flash fallback for OCR text the local parser can't read (§2 "LLM
/// fallback"). Input is OCR TEXT ONLY — never the image.
///
/// The model is treated as untrusted: every field it returns must be proven
/// against the raw text by three gates before we accept it. Any failure,
/// timeout, or exception degrades silently to null (→ couldn't-read state).
library;

import 'dart:convert';

import 'package:google_generative_ai/google_generative_ai.dart';

import '../core/parser/amount_adjacency.dart';
import '../core/parser/cbe_parser.dart';

/// Seam so the pipeline can be tested without a network call.
abstract class CbeAiFallback {
  Future<ParsedCbeMessage?> parse(String rawText);
}

/// Generates a completion for [prompt]; returns null when unavailable.
/// Injected so the validation gates can be tested with canned responses.
typedef GeminiGenerator = Future<String?> Function(String prompt);

class GeminiFallbackService implements CbeAiFallback {
  GeminiFallbackService({GeminiGenerator? generator, String? apiKey})
    : _generator = generator ?? _liveGenerator(apiKey ?? _envApiKey);

  final GeminiGenerator _generator;

  /// MVP: supplied at build time via --dart-define (§2).
  static const String _envApiKey = String.fromEnvironment('GEMINI_API_KEY');

  /// Pinned to a specific stable model, NOT a `-latest` alias: an alias is
  /// hot-swapped on each release and would change extraction behaviour under
  /// the app silently. Verified against Google's model list on 2026-07-15.
  static const String modelName = 'gemini-3.5-flash';

  static const Duration timeout = Duration(seconds: 10);

  static GeminiGenerator _liveGenerator(String apiKey) {
    return (prompt) async {
      if (apiKey.isEmpty) return null; // no key → silently unavailable
      final model = GenerativeModel(
        model: modelName,
        apiKey: apiKey,
        generationConfig: GenerationConfig(
          temperature: 0,
          responseMimeType: 'application/json',
        ),
      );
      final response = await model.generateContent([Content.text(prompt)]);
      return response.text;
    };
  }

  static String buildPrompt(String rawText) =>
      '''
You extract a single Commercial Bank of Ethiopia (CBE) transaction from OCR text.

Rules:
- "credited", "received", "deposited" => type "credit".
- "debited", "deducted", "paid" => type "debit".
- The transaction amount is the figure ADJACENT to the credited/debited
  phrase. NEVER return the "Current Balance" figure.
- Never guess digits. Copy them exactly as they appear.
- If the amount or the type is uncertain, return {"error": "unparseable"}.

Return STRICT JSON only, no prose:
{"amount": "<as written, e.g. 5,000.00>", "type": "credit|debit",
 "reference": "<FT reference or null>", "date": "<ISO 8601 or null>"}

OCR text:
"""
$rawText
"""''';

  @override
  Future<ParsedCbeMessage?> parse(String rawText) async {
    if (rawText.trim().isEmpty) return null;
    try {
      final response = await _generator(
        buildPrompt(rawText),
      ).timeout(timeout);
      if (response == null) return null;
      return _validate(response, rawText);
    } on Object {
      // Timeout, network error, bad key, malformed response — all degrade to
      // the couldn't-read state rather than surfacing an error.
      return null;
    }
  }

  /// Runs the three gates. Returns null unless ALL pass.
  ParsedCbeMessage? _validate(String response, String rawText) {
    final json = _decodeJson(response);
    if (json == null) return null;
    if (json['error'] != null) return null;

    final amountRaw = json['amount'];
    final typeRaw = json['type'];
    if (amountRaw == null || typeRaw == null) return null;

    final amountCents = centsFromText(amountRaw.toString());
    if (amountCents == null) return null;

    final type = switch (typeRaw.toString().toLowerCase().trim()) {
      'credit' => TxType.credit,
      'debit' => TxType.debit,
      _ => null,
    };
    if (type == null) return null;

    // Offsets below are indices into this normalized text.
    final normalized = normalizeCbeText(rawText);

    // GATE 1 — amount-adjacency, computed entirely locally (we never ask the
    // model where it found the figure; it could just as easily lie about that).
    // The returned value must occur within kAdjacencyMaxGap characters of a
    // credited/debited-family keyword, and must not be a Current Balance
    // figure. This is the same rule the regex parser uses (fixture 7), so a
    // model that returns the balance instead of the transaction is rejected.
    final adjacency = findTransactionAmountNear(
      rawText,
      candidateCents: amountCents,
      maxGap: kAdjacencyMaxGap,
      keywordSet: KeywordSet.extended,
    );
    if (adjacency == null) return null;

    // GATE 2 — a keyword matching the returned type must exist in the text.
    final keywords = findTypeKeywords(normalized, set: KeywordSet.extended);
    if (!keywords.any((k) => k.type == type)) return null;

    // GATE 3 — reference, if given, must look like an FT ref AND be present.
    final reference = _stringOrNull(json['reference']);
    if (reference != null) {
      if (!RegExp(r'^FT\w{10,}$').hasMatch(reference)) return null;
      if (!normalized.replaceAll(' ', '').contains(reference)) return null;
    }

    return ParsedCbeMessage(
      amountCents: amountCents,
      type: type,
      reference: reference,
      date: _parseDate(_stringOrNull(json['date'])),
      confidence: Confidence.aiParsed,
      rawText: rawText,
    );
  }

  static Map<String, dynamic>? _decodeJson(String response) {
    // Models sometimes wrap JSON in prose or fences; take the outermost object.
    final start = response.indexOf('{');
    final end = response.lastIndexOf('}');
    if (start == -1 || end <= start) return null;
    try {
      final decoded = jsonDecode(response.substring(start, end + 1));
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static String? _stringOrNull(Object? value) {
    if (value == null) return null;
    final text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return null;
    return text;
  }

  static DateTime? _parseDate(String? raw) =>
      raw == null ? null : DateTime.tryParse(raw);
}
