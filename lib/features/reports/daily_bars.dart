/// Per-day totals for the Reports bar chart (§FR-6). Pure Dart.
///
/// The chart shows the seven days ending on the selected day: money in and
/// money out per day, across every active branch. Grouping by LOCAL calendar
/// day is done here rather than in SQL, because SQLite has no idea what day a
/// timestamp falls on in Addis Ababa and the window is only a week of rows.
library;

import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';

export '../../data/db/database.dart' show LedgerEntry;

/// One day's column in the chart. Integer cents only.
class DayTotals {
  const DayTotals({
    required this.day,
    this.creditCents = 0,
    this.debitCents = 0,
    this.count = 0,
  });

  /// Midnight, local time.
  final DateTime day;
  final int creditCents;
  final int debitCents;
  final int count;

  int get netCents => creditCents - debitCents;

  bool get isEmpty => count == 0;

  DayTotals _plus(LedgerEntry entry) => DayTotals(
    day: day,
    creditCents:
        creditCents + (entry.type == TxType.credit ? entry.amountCents : 0),
    debitCents:
        debitCents + (entry.type == TxType.debit ? entry.amountCents : 0),
    count: count + 1,
  );
}

/// How many days the chart covers.
const int chartDays = 7;

/// Midnight of the first day in a [chartDays]-long window ending on [day].
DateTime chartWindowStart(DateTime day) =>
    DateTime(day.year, day.month, day.day - (chartDays - 1));

/// Midnight after [day] — the exclusive end of the window.
DateTime chartWindowEnd(DateTime day) =>
    DateTime(day.year, day.month, day.day + 1);

/// Buckets [entries] into the [chartDays] days ending on [endDay].
///
/// Every day in the window is present, empty days included — a chart column
/// with no bar is information ("nothing happened Tuesday"); a missing column
/// is a bug. Entries outside the window are ignored, so a caller can pass a
/// wider slice without harm.
List<DayTotals> totalsByDay(Iterable<LedgerEntry> entries, DateTime endDay) {
  final start = chartWindowStart(endDay);
  final days = [
    for (var i = 0; i < chartDays; i++)
      DayTotals(day: DateTime(start.year, start.month, start.day + i)),
  ];
  final index = <DateTime, int>{
    for (var i = 0; i < days.length; i++) days[i].day: i,
  };
  for (final entry in entries) {
    final key = DateTime(entry.date.year, entry.date.month, entry.date.day);
    final i = index[key];
    if (i == null) continue;
    days[i] = days[i]._plus(entry);
  }
  return List.unmodifiable(days);
}

/// The tallest bar in the window, for scaling. Zero when nothing happened.
/// Only money received is charted — every receipt she files is a payment in.
int maxBarCents(List<DayTotals> days) {
  var max = 0;
  for (final d in days) {
    if (d.creditCents > max) max = d.creditCents;
  }
  return max;
}
