// Widget test for the single-add confirm screen (§8 Phase 9).
//
// Drives the real screen with a faked picker and parse pipeline: the picker
// hands back a fixture PNG, the pipeline "reads" it, and the test asserts the
// confirm state — parsed figures on screen, a pre-selected branch, an enabled
// Confirm button, and the manual-edit escape hatch. Saving is not tapped (it
// needs a database, which deadlocks under testWidgets).

import 'dart:convert';
import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/database_provider.dart';
import 'package:cbe_tracker/features/add_single/add_single_screen.dart';
import 'package:cbe_tracker/services/parse_pipeline.dart';
import 'package:cbe_tracker/services/service_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
  'AAAADUlEQVR4nGIAAQAABQABDQottAAAAABJRU5ErkJggg==',
);

/// Hands the screen a fixture file instead of opening the system picker.
class _FakePicker extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  _FakePicker(this.path);

  final String path;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async => XFile(path);
}

/// A pipeline that "reads" every image as the given outcome.
class _FakePipeline implements ParsePipeline {
  _FakePipeline(this.outcome);

  final ParseOutcome outcome;

  @override
  Future<ParseOutcome> parse(File image) async => outcome;

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('cbe_confirm_test');
    final png = File('${temp.path}/shot.png')..writeAsBytesSync(_pngBytes);
    ImagePickerPlatform.instance = _FakePicker(png.path);
  });

  tearDown(() => temp.deleteSync(recursive: true));

  final bole = Branch(
    id: 1,
    name: 'Bole',
    archived: false,
    createdAt: DateTime(2026, 7, 15),
  );

  Widget app(ParseOutcome outcome) {
    return ProviderScope(
      overrides: [
        parsePipelineProvider.overrideWithValue(_FakePipeline(outcome)),
        activeBranchesProvider.overrideWithValue(AsyncValue.data([bole])),
        lastBranchIdProvider.overrideWithValue(const AsyncValue.data(1)),
      ],
      child: const MaterialApp(home: AddSingleScreen()),
    );
  }

  testWidgets('a clean parse lands on the confirm state, ready to save', (
    tester,
  ) async {
    final parsed = ParsedCbeMessage(
      amountCents: 500000,
      type: TxType.credit,
      reference: 'FT26TEST01',
      date: DateTime(2026, 7, 15, 10, 30),
      confidence: Confidence.high,
      rawText: 'raw',
    );
    await tester.pumpWidget(app(ParseSuccess(parsed)));
    await tester.pumpAndSettle();

    // The parsed figures, not a form: automation first (§FR-2).
    expect(find.textContaining('5,000.00'), findsOneWidget);
    expect(find.text('FT26TEST01'), findsOneWidget);

    // Her branch chip is there, and Confirm is live — the last-used branch was
    // pre-selected, so saving is one tap.
    expect(find.text('Bole'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Confirm'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(confirm.onPressed, isNotNull);

    // The escape hatch for a misread is offered, not forced.
    expect(find.text('Edit manually'), findsOneWidget);
  });

  testWidgets('an unreadable image offers manual entry instead of a dead end', (
    tester,
  ) async {
    await tester.pumpWidget(app(const ParseUnreadable('')));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't read"), findsOneWidget);
    expect(find.text('Try another image'), findsOneWidget);
  });
}
