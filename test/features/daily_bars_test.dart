// The Reports bar chart's numbers: seven local days, every day present, cents
// summed by type, and the window's scale.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/features/reports/daily_bars.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final end = DateTime(2026, 9, 17);

  LedgerEntry entry(DateTime date, int cents, [TxType type = TxType.credit]) =>
      LedgerEntry(date: date, amountCents: cents, type: type);

  test('the window is seven days ending on the chosen day', () {
    expect(chartWindowStart(end), DateTime(2026, 9, 11));
    expect(chartWindowEnd(end), DateTime(2026, 9, 18));
    // Across a month boundary too.
    expect(chartWindowStart(DateTime(2026, 10, 2)), DateTime(2026, 9, 26));
  });

  test('every day is present, empty ones included, oldest first', () {
    final days = totalsByDay(const [], end);
    expect(days.map((d) => d.day.day), [11, 12, 13, 14, 15, 16, 17]);
    expect(days.every((d) => d.isEmpty), isTrue);
  });

  test('credits and debits are summed apart, by local day', () {
    final days = totalsByDay([
      entry(DateTime(2026, 9, 15, 9, 0), 100000),
      entry(DateTime(2026, 9, 15, 23, 59), 25000, TxType.debit),
      entry(DateTime(2026, 9, 15, 0, 0), 5000),
      entry(DateTime(2026, 9, 17, 12, 0), 70000, TxType.debit),
    ], end);

    final d15 = days[4];
    expect(d15.day, DateTime(2026, 9, 15));
    expect(d15.creditCents, 105000);
    expect(d15.debitCents, 25000);
    expect(d15.netCents, 80000);
    expect(d15.count, 3);

    final d17 = days.last;
    expect(d17.creditCents, 0);
    expect(d17.debitCents, 70000);
    expect(d17.count, 1);
  });

  test('entries outside the window are ignored', () {
    final days = totalsByDay([
      entry(DateTime(2026, 9, 10, 23, 59), 999999), // the day before
      entry(DateTime(2026, 9, 18, 0, 0), 999999), // the day after
    ], end);
    expect(days.every((d) => d.isEmpty), isTrue);
  });

  test('the scale is the tallest single bar, not the tallest net', () {
    final days = totalsByDay([
      entry(DateTime(2026, 9, 16), 30000),
      entry(DateTime(2026, 9, 16), 80000, TxType.debit),
    ], end);
    expect(maxBarCents(days), 80000);
    expect(maxBarCents(totalsByDay(const [], end)), 0);
  });
}
