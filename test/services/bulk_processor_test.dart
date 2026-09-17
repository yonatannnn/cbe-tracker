// BulkProcessor against a scripted pipeline and a real in-memory DB (so the
// duplicate lookup is exercised for real, and "writes nothing" is provable).

import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/bulk_processor.dart';
import 'package:cbe_tracker/services/gemini_fallback_service.dart';
import 'package:cbe_tracker/services/ocr_service.dart';
import 'package:cbe_tracker/services/parse_pipeline.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns a scripted outcome per image path, and records the call order so we
/// can prove processing is sequential.
class _ScriptedPipeline implements ParsePipeline {
  _ScriptedPipeline(this.script);

  final Map<String, ParseOutcome> script;
  final calls = <String>[];
  var concurrent = 0;
  var maxConcurrent = 0;

  @override
  OcrService get ocr => throw UnimplementedError();

  @override
  CbeAiFallback get ai => throw UnimplementedError();

  @override
  Future<ParseOutcome> parse(File image) async {
    concurrent++;
    maxConcurrent = concurrent > maxConcurrent ? concurrent : maxConcurrent;
    calls.add(image.path);
    // Yield so any accidental parallelism would overlap here.
    await Future<void>.delayed(Duration.zero);
    concurrent--;
    return script[image.path]!;
  }
}

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  ParsedCbeMessage parsed({
    required String reference,
    int cents = 500000,
    Confidence confidence = Confidence.high,
  }) {
    return ParsedCbeMessage(
      amountCents: cents,
      type: TxType.credit,
      reference: reference,
      date: DateTime(2026, 7, 14, 10, 42),
      confidence: confidence,
      rawText: 'raw',
    );
  }

  BulkProcessor processorFor(Map<String, ParseOutcome> script) => BulkProcessor(
    pipeline: _ScriptedPipeline(script),
    dao: db.transactionDao,
  );

  test('10 images → correct statuses, no DB writes during processing', () async {
    final branch = await db.branchDao.createBranch('Main');
    // One reference already recorded, so image 3 must come back a duplicate.
    await db.transactionDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: branch,
        amountCents: 500000,
        type: TxType.credit,
        reference: 'FTEXISTING01',
        source: TxSource.screenshot,
        transactionDate: DateTime(2026, 7, 13, 9, 0),
      ),
    );
    final rowsBefore = (await db.select(db.transactions).get()).length;

    final script = <String, ParseOutcome>{
      for (var i = 1; i <= 10; i++)
        'img$i.png': switch (i) {
          3 => ParseSuccess(parsed(reference: 'FTEXISTING01')), // duplicate
          5 => ParseSuccess(
            parsed(reference: 'FTAI00000001', confidence: Confidence.aiParsed),
          ),
          7 => const ParseUnreadable('blurry'),
          _ => ParseSuccess(parsed(reference: 'FTOK$i')),
        },
    };
    final images = [for (var i = 1; i <= 10; i++) File('img$i.png')];

    final progress = await processorFor(script).process(images).toList();

    final items = progress.last.resultsSoFar;
    expect(items, hasLength(10));
    expect(items[2].status, BulkStatus.duplicate);
    expect(items[2].existing, isNotNull, reason: 'needs the recorded date');
    expect(items[2].existing!.transactionDate, DateTime(2026, 7, 13, 9, 0));
    expect(items[4].status, BulkStatus.okAiParsed);
    expect(items[6].status, BulkStatus.failed);
    expect(items[6].rawText, 'blurry');
    expect(items[0].status, BulkStatus.ok);
    expect(items[9].status, BulkStatus.ok);

    // The whole point: processing is a dry run.
    expect(
      (await db.select(db.transactions).get()).length,
      rowsBefore,
      reason: 'BulkProcessor must not write anything',
    );
  });

  test('emits progress 1..N in order, with results accumulating', () async {
    final script = <String, ParseOutcome>{
      for (var i = 1; i <= 10; i++)
        'img$i.png': ParseSuccess(parsed(reference: 'FTOK$i')),
    };
    final images = [for (var i = 1; i <= 10; i++) File('img$i.png')];

    final progress = await processorFor(script).process(images).toList();

    expect(progress, hasLength(10));
    expect(progress.map((p) => p.current), List.generate(10, (i) => i + 1));
    expect(progress.every((p) => p.total == 10), isTrue);
    // resultsSoFar grows by exactly one per emission.
    expect(
      progress.map((p) => p.resultsSoFar.length),
      List.generate(10, (i) => i + 1),
    );
    expect(progress.last.isComplete, isTrue);
    expect(progress.first.isComplete, isFalse);
    expect(progress.last.fraction, 1.0);
  });

  test('processes sequentially, never in parallel', () async {
    final script = <String, ParseOutcome>{
      for (var i = 1; i <= 5; i++)
        'img$i.png': ParseSuccess(parsed(reference: 'FTOK$i')),
    };
    final pipeline = _ScriptedPipeline(script);
    final processor = BulkProcessor(pipeline: pipeline, dao: db.transactionDao);

    await processor
        .process([for (var i = 1; i <= 5; i++) File('img$i.png')])
        .toList();

    expect(pipeline.maxConcurrent, 1, reason: 'ML Kit must not run 5 at once');
    expect(pipeline.calls, [
      'img1.png',
      'img2.png',
      'img3.png',
      'img4.png',
      'img5.png',
    ]);
  });

  test('caps the batch at maxImages', () async {
    // Feed a handful more than the cap so the test holds at any cap value.
    final over = BulkProcessor.maxImages + 5;
    final script = <String, ParseOutcome>{
      for (var i = 1; i <= over; i++)
        'img$i.png': ParseSuccess(parsed(reference: 'FTOK$i')),
    };
    final pipeline = _ScriptedPipeline(script);
    final processor = BulkProcessor(pipeline: pipeline, dao: db.transactionDao);

    final progress = await processor
        .process([for (var i = 1; i <= over; i++) File('img$i.png')])
        .toList();

    expect(progress, hasLength(BulkProcessor.maxImages));
    expect(progress.last.total, BulkProcessor.maxImages);
    expect(
      pipeline.calls,
      hasLength(BulkProcessor.maxImages),
      reason: 'images past the cap are never parsed',
    );
  });

  test('an unreferenced parse is ok, not duplicate', () async {
    // aiParsed with a null reference can't collide with anything.
    final script = <String, ParseOutcome>{
      'img1.png': ParseSuccess(
        ParsedCbeMessage(
          amountCents: 100,
          type: TxType.debit,
          reference: null,
          date: DateTime(2026, 7, 15, 11, 45),
          confidence: Confidence.aiParsed,
          rawText: 'raw',
        ),
      ),
    };

    final progress = await processorFor(script).process([File('img1.png')]).toList();

    expect(progress.single.resultsSoFar.single.status, BulkStatus.okAiParsed);
  });

  test('empty input emits nothing', () async {
    expect(await processorFor({}).process([]).toList(), isEmpty);
  });

  test('the same reference twice in one batch → the later one is a duplicate '
      'of the earlier, not saved and not blamed on the database', () async {
    final script = <String, ParseOutcome>{
      'a.png': ParseSuccess(parsed(reference: 'FT26196FZHT2', cents: 100)),
      'b.png': ParseSuccess(parsed(reference: 'FT26196KZKRR', cents: 200)),
      'c.png': ParseSuccess(parsed(reference: 'FT26196FZHT2', cents: 100)),
      'd.png': ParseSuccess(parsed(reference: 'FT26196FZHT2', cents: 100)),
    };
    final images = [for (final n in ['a', 'b', 'c', 'd']) File('$n.png')];

    final progress = await processorFor(script).process(images).toList();
    final items = progress.last.resultsSoFar;

    expect(items[0].status, BulkStatus.ok);
    expect(items[1].status, BulkStatus.ok);
    expect(items[2].status, BulkStatus.duplicate);
    expect(items[2].duplicateOf, 1, reason: 'points at the FIRST copy');
    expect(items[2].existing, isNull, reason: 'nothing in the database');
    expect(items[3].status, BulkStatus.duplicate);
    expect(items[3].duplicateOf, 1);
  });
}
