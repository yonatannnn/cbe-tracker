// The seven-day chart renders at phone width without overflow, names the
// selected day in words, and a tapped column selects that day.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/features/reports/daily_bars.dart';
import 'package:cbe_tracker/features/reports/daily_bars_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = DateTime(2026, 9, 17);

  List<DayTotals> sample() => totalsByDay([
    LedgerEntry(
      date: DateTime(2026, 9, 15, 9),
      amountCents: 1250000,
      type: TxType.credit,
    ),
    LedgerEntry(
      date: DateTime(2026, 9, 15, 17),
      amountCents: 300000,
      type: TxType.debit,
    ),
    LedgerEntry(
      date: DateTime(2026, 9, 17, 11),
      amountCents: 100,
      type: TxType.debit,
    ),
  ], today);

  Future<DateTime?> pump(
    WidgetTester tester, {
    required DateTime selected,
    List<DayTotals>? days,
  }) async {
    DateTime? picked;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DailyBarsChart(
            days: days ?? sample(),
            selected: selected,
            today: today,
            onSelect: (d) => picked = d,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('renders seven columns with a legend and no overflow', (
    tester,
  ) async {
    await pump(tester, selected: today);

    expect(find.text('LAST 7 DAYS'), findsOneWidget);
    expect(find.text('In'), findsOneWidget);
    expect(find.text('Out'), findsOneWidget);
    for (final n in ['11', '12', '13', '14', '15', '16', '17']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(tester.takeException(), isNull, reason: 'no layout overflow');
  });

  testWidgets('the caption says the selected day in words', (tester) async {
    await pump(tester, selected: DateTime(2026, 9, 15));
    expect(
      find.text(
        '15 Sep 2026 · In ETB 12,500.00 · Out ETB 3,000.00 · 2 transactions',
      ),
      findsOneWidget,
    );

    await pump(tester, selected: today);
    expect(
      find.text('Today · In ETB 0.00 · Out ETB 1.00 · 1 transaction'),
      findsOneWidget,
    );

    await pump(tester, selected: DateTime(2026, 9, 12));
    expect(find.text('12 Sep 2026 · no transactions'), findsOneWidget);
  });

  testWidgets('an empty week says so instead of drawing nothing', (
    tester,
  ) async {
    await pump(tester, selected: today, days: totalsByDay(const [], today));
    expect(find.text('No transactions in the last 7 days'), findsOneWidget);
  });

  testWidgets('tapping a column selects that day', (tester) async {
    DateTime? picked;
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DailyBarsChart(
            days: sample(),
            selected: today,
            today: today,
            onSelect: (d) => picked = d,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('15'));
    expect(picked, DateTime(2026, 9, 15));
  });
}
