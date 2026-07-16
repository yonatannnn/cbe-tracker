// Widget tests for the bulk review modal (§8 Phase 9).
//
// Render and interaction only — the three row states, the exact-count save
// button, and checking rows in and out. Save itself is never tapped: it needs
// a database, and Drift deadlocks inside testWidgets' fake-async zone; the
// atomic save is covered by the bulk_processor and DAO tests.

import 'dart:convert';
import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/features/bulk_add/bulk_review_modal.dart';
import 'package:cbe_tracker/services/bulk_processor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A real, decodable 1×1 PNG so Image.file thumbnails render without errors.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR4nGIAAQAABQABDQottAAAAABJRU5ErkJggg==',
);

ParsedCbeMessage _parsed(String reference, {int cents = 500000}) {
  return ParsedCbeMessage(
    amountCents: cents,
    type: TxType.credit,
    reference: reference,
    date: DateTime(2026, 7, 15, 10, 30),
    confidence: Confidence.high,
    rawText: 'raw',
  );
}

void main() {
  late Directory temp;
  late File png;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cbe_modal_test');
    png = File('${temp.path}/shot.png')..writeAsBytesSync(_pngBytes);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> pump(WidgetTester tester, List<BulkItem> items) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: BulkReviewModal(
              items: items,
              branchId: 1,
              branchName: 'Bole',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders all three row states and counts only saveable ones', (
    tester,
  ) async {
    final existing = Transaction(
      id: 7,
      branchId: 1,
      amountCents: 200000,
      type: TxType.credit,
      reference: 'FT26DUP001',
      source: TxSource.screenshot,
      transactionDate: DateTime(2026, 7, 10, 9, 0),
      createdAt: DateTime(2026, 7, 10, 9, 0),
    );
    await pump(tester, [
      BulkItem.ok(png, _parsed('FT26OK0001')),
      BulkItem.duplicate(png, _parsed('FT26DUP001'), existing),
      BulkItem.failed(png, 'garbled text'),
    ]);

    expect(find.textContaining('Review 3'), findsOneWidget);
    // Only the clean parse starts checked → the button says exactly 1.
    expect(find.text('Save 1 transaction'), findsOneWidget);
    // The duplicate says so, with the original's date.
    expect(find.textContaining('Already recorded'), findsOneWidget);
    // The unreadable row says so.
    expect(find.textContaining("Couldn't read"), findsOneWidget);
  });

  testWidgets('an AI-parsed row starts unchecked; checking it updates the count',
      (tester) async {
    await pump(tester, [
      BulkItem.ok(png, _parsed('FT26OK0001')),
      BulkItem.okAiParsed(png, _parsed('FT26AI0001')),
    ]);

    // §FR-3: trust the local parser, make the human vouch for the AI.
    expect(find.text('Save 1 transaction'), findsOneWidget);

    // Two checkboxes; the AI row's is the unchecked one.
    final boxes = find.byType(Checkbox);
    expect(boxes, findsNWidgets(2));
    final unchecked = tester
        .widgetList<Checkbox>(boxes)
        .toList()
        .indexWhere((c) => c.value == false);
    expect(unchecked, isNot(-1));
    await tester.tap(boxes.at(unchecked));
    await tester.pumpAndSettle();

    expect(find.text('Save 2 transactions'), findsOneWidget);
  });

  testWidgets('unchecking every row disables the save button', (tester) async {
    await pump(tester, [
      BulkItem.ok(png, _parsed('FT26OK0001')),
    ]);
    expect(find.text('Save 1 transaction'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    expect(find.text('Save 0 transactions'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Save 0 transactions'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull, reason: 'nothing checked → nothing to save');
  });
}
