// The add-screenshots screen opened from inside a branch: the branch step is
// skipped, the day defaults to today and can be changed, and nothing reads
// until she taps Read.

import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/database_provider.dart';
import 'package:cbe_tracker/features/bulk_add/bulk_add_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedToday extends Today {
  @override
  DateTime build() => DateTime(2026, 9, 17);
}

void main() {
  final bole = Branch(
    id: 1,
    name: 'Bole',
    archived: false,
    createdAt: DateTime(2026, 7, 15),
  );

  Future<void> pump(WidgetTester tester, {int? branchId}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todayProvider.overrideWith(_FixedToday.new),
          activeBranchesProvider.overrideWithValue(AsyncValue.data([bole])),
        ],
        child: MaterialApp(home: BulkAddScreen(initialBranchId: branchId)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('from a branch: opens on the image step, dated today', (
    tester,
  ) async {
    await pump(tester, branchId: 1);

    expect(find.widgetWithText(AppBar, 'Add screenshots'), findsOneWidget);
    expect(find.text('Which branch are these screenshots for?'), findsNothing);
    expect(find.text('Bole'), findsOneWidget);
    expect(find.text('Today, 17 Sep 2026'), findsOneWidget);
    // Nothing picked yet → nothing to read.
    final read = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Read 0 screenshots'),
    );
    expect(read.onPressed, isNull);
  });

  testWidgets('the day can be changed and reset to today', (tester) async {
    await pump(tester, branchId: 1);

    await tester.tap(find.text('Change day'));
    await tester.pumpAndSettle();
    expect(find.text('Day of these transactions'), findsOneWidget);
    await tester.tap(find.text('16'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Today, 17 Sep 2026'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Today'));
    await tester.pumpAndSettle();
    expect(find.text('Today, 17 Sep 2026'), findsOneWidget);
  });

  testWidgets('from the dashboard: still asks for the branch first', (
    tester,
  ) async {
    await pump(tester);
    expect(find.widgetWithText(AppBar, 'Bulk upload'), findsOneWidget);
    expect(
      find.text('Which branch are these screenshots for?'),
      findsOneWidget,
    );
  });
}
