/// Sequential bulk OCR processor (§6, FR-3).
///
/// Runs each image through the SAME pipeline the single-add flow uses, one at a
/// time, and reports progress so the UI can show "Processing 4 of 7…".
///
/// Writes NOTHING to the database — the duplicate lookup here is read-only and
/// exists purely so the review modal can grey those rows out. The real
/// duplicate guard stays `insertIfNew`'s UNIQUE reference at save time (§FR-2).
library;

import 'dart:io';

import '../core/parser/cbe_parser.dart';
import '../data/db/daos/transaction_dao.dart';
import '../data/db/database.dart';
import 'parse_pipeline.dart';

/// Outcome for one image in the batch.
enum BulkStatus {
  /// Parsed locally with HIGH confidence; reference not already recorded.
  ok,

  /// Parsed via the Gemini fallback — must be user-checked before saving.
  okAiParsed,

  /// Reference already exists in transactions; cannot be saved again.
  duplicate,

  /// Unreadable — nothing trustworthy came back.
  failed,
}

class BulkItem {
  const BulkItem({
    required this.image,
    required this.status,
    this.parsed,
    this.existing,
    this.rawText,
  });

  BulkItem.ok(this.image, ParsedCbeMessage this.parsed)
    : status = BulkStatus.ok,
      existing = null,
      rawText = null;

  BulkItem.okAiParsed(this.image, ParsedCbeMessage this.parsed)
    : status = BulkStatus.okAiParsed,
      existing = null,
      rawText = null;

  BulkItem.duplicate(this.image, this.parsed, Transaction this.existing)
    : status = BulkStatus.duplicate,
      rawText = null;

  BulkItem.failed(this.image, this.rawText)
    : status = BulkStatus.failed,
      parsed = null,
      existing = null;

  final File image;
  final BulkStatus status;

  /// Present for every status except [BulkStatus.failed].
  final ParsedCbeMessage? parsed;

  /// The already-recorded transaction, for "Already recorded on `<date>`".
  final Transaction? existing;

  /// Whatever OCR read, when the parse failed. May be empty.
  final String? rawText;
}

/// Progress snapshot: "[current] of [total]" plus everything finished so far.
class BulkProgress {
  const BulkProgress({
    required this.current,
    required this.total,
    required this.resultsSoFar,
  });

  /// 1-based index of the image just finished.
  final int current;
  final int total;
  final List<BulkItem> resultsSoFar;

  bool get isComplete => current == total;

  /// 0.0–1.0 for the LinearProgressIndicator.
  double get fraction => total == 0 ? 0 : current / total;
}

class BulkProcessor {
  BulkProcessor({required this.pipeline, required this.dao});

  final ParsePipeline pipeline;
  final TransactionDao dao;

  /// Hard cap from §FR-3.
  static const int maxImages = 10;

  /// Processes [images] one at a time, emitting after each.
  ///
  /// Sequential on purpose: ten concurrent ML Kit decodes would spike memory
  /// and thrash the recognizer. Anything past [maxImages] is ignored — the UI
  /// caps the selection before it gets here.
  Stream<BulkProgress> process(List<File> images) async* {
    final batch = images.take(maxImages).toList();
    final results = <BulkItem>[];

    for (var i = 0; i < batch.length; i++) {
      results.add(await _processOne(batch[i]));
      yield BulkProgress(
        current: i + 1,
        total: batch.length,
        resultsSoFar: List.unmodifiable(List<BulkItem>.of(results)),
      );
    }
  }

  Future<BulkItem> _processOne(File image) async {
    final outcome = await pipeline.parse(image);

    switch (outcome) {
      case ParseUnreadable(:final rawText):
        return BulkItem.failed(image, rawText);

      case ParseSuccess(:final parsed):
        final reference = parsed.reference;
        if (reference != null) {
          // Read-only: display only. insertIfNew remains the real guard.
          final existing = await dao.findByReference(reference);
          if (existing != null) {
            return BulkItem.duplicate(image, parsed, existing);
          }
        }
        return parsed.confidence == Confidence.aiParsed
            ? BulkItem.okAiParsed(image, parsed)
            : BulkItem.ok(image, parsed);
    }
  }
}
