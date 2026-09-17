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
import 'package:cbe_tracker/data/db/database_provider.dart';
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
        overrides: [
          // Branch names for "already saved before — <branch>"; no database.
          activeBranchesProvider.overrideWithValue(
            AsyncValue.data([
              Branch(
                id: 1,
                name: 'Bole',
                archived: false,
                createdAt: DateTime(2026, 7, 1),
              ),
            ]),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: BulkReviewModal(
              items: items,
              branchId: 1,
              branchName: 'Bole',
              day: DateTime(2026, 7, 15),
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
    // The approval screen leads with how many were read, and the day.
    expect(
      find.text('2 of 3 read correctly · 1 duplicate not saved · 1 unreadable'),
      findsOneWidget,
    );
    expect(find.text('Bole · 15 Jul 2026'), findsOneWidget);
    // Only the clean parse starts checked → the button says exactly 1, and
    // the sum is that one row.
    expect(find.text('Approve 1 transaction'), findsOneWidget);
    expect(find.text('Sum of the 1 selected'), findsOneWidget);
    // The sum panel: the one checked credit in IN, nothing in OUT.
    expect(find.text('IN'), findsOneWidget);
    expect(find.text('ETB 5,000.00'), findsOneWidget);
    expect(find.text('ETB 0.00'), findsOneWidget);
    // The duplicate says so, with the original's date.
    expect(
      find.text('Already saved before — Bole, 10/07/2026 at 09:00'),
      findsOneWidget,
    );
    expect(find.text('DUPLICATE · NOT SAVED'), findsOneWidget);
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
    expect(find.text('Approve 1 transaction'), findsOneWidget);

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

    expect(find.text('Approve 2 transactions'), findsOneWidget);
  });

  testWidgets('unchecking every row disables the save button', (tester) async {
    await pump(tester, [
      BulkItem.ok(png, _parsed('FT26OK0001')),
    ]);
    expect(find.text('Approve 1 transaction'), findsOneWidget);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    expect(find.text('Approve 0 transactions'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Approve 0 transactions'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull, reason: 'nothing checked → nothing to save');
  });

  testWidgets('a repeat inside the batch names the screenshot it copies', (
    tester,
  ) async {
    await pump(tester, [
      BulkItem.ok(png, _parsed('FT26SAME001')),
      BulkItem.ok(png, _parsed('FT26OTHER01')),
      BulkItem.duplicateInBatch(png, _parsed('FT26SAME001'), 1),
    ]);

    expect(find.text('Same receipt as screenshot #1'), findsOneWidget);
    expect(find.text('DUPLICATE · NOT SAVED'), findsOneWidget);
    // Only the two distinct receipts are approvable.
    expect(find.text('Approve 2 transactions'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));
  });
}
