// Pure day-grouping rules at a fixed "now" — no widgets, no database.

import 'package:cbe_tracker/features/branch_detail/day_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Fixed so Today/Yesterday can't drift with the wall clock.
  final now = DateTime(2026, 7, 15, 14, 30);

  // Named `sections`, not `group` — that would shadow the test framework's
  // own group().
  List<DaySection<DateTime>> sections(List<DateTime> dates) =>
      groupByDay<DateTime>(items: dates, dateOf: (d) => d, now: now);

  group('dayLabel', () {
    test('today, whatever the time of day', () {
      expect(dayLabel(DateTime(2026, 7, 15, 0, 0), now), 'Today');
      expect(dayLabel(DateTime(2026, 7, 15, 23, 59), now), 'Today');
    });

    test('yesterday', () {
      expect(dayLabel(DateTime(2026, 7, 14, 23, 59), now), 'Yesterday');
      expect(dayLabel(DateTime(2026, 7, 14, 0, 0), now), 'Yesterday');
    });

    test('older days use MMM d', () {
      expect(dayLabel(DateTime(2026, 7, 13, 12, 0), now), 'Jul 13');
      expect(dayLabel(DateTime(2026, 1, 1, 12, 0), now), 'Jan 1');
      expect(dayLabel(DateTime(2026, 12, 31, 12, 0), now), 'Dec 31');
    });

    test('a different year is disambiguated', () {
      // "Jul 13" alone would be a lie once history spans a new year.
      expect(dayLabel(DateTime(2025, 7, 13, 12, 0), now), 'Jul 13, 2025');
    });

    test('the today/yesterday edge is the local midnight boundary', () {
      // 00:10 today is Today; 23:50 yesterday is Yesterday — 20 minutes apart.
      expect(dayLabel(DateTime(2026, 7, 15, 0, 10), now), 'Today');
      expect(dayLabel(DateTime(2026, 7, 14, 23, 50), now), 'Yesterday');
    });
  });

  group('groupByDay', () {
    test('empty in, empty out', () {
      expect(sections([]), isEmpty);
    });

    test('groups by local day, newest day first', () {
      final result = sections([
        DateTime(2026, 7, 13, 9, 0),
        DateTime(2026, 7, 15, 9, 0),
        DateTime(2026, 7, 14, 9, 0),
      ]);

      expect(result.map((s) => s.label), ['Today', 'Yesterday', 'Jul 13']);
      expect(result.every((s) => s.items.length == 1), isTrue);
    });

    test('several rows on one day land in one section, newest first', () {
      final result = sections([
        DateTime(2026, 7, 15, 9, 0),
        DateTime(2026, 7, 15, 18, 0),
        DateTime(2026, 7, 15, 12, 0),
      ]);

      expect(result, hasLength(1));
      expect(result.single.label, 'Today');
      expect(result.single.items.map((d) => d.hour), [18, 12, 9]);
    });

    test('unsorted input still groups correctly', () {
      // The DAO orders these, but the function must not depend on it.
      final result = sections([
        DateTime(2026, 7, 13, 8, 0),
        DateTime(2026, 7, 15, 8, 0),
        DateTime(2026, 7, 13, 20, 0),
        DateTime(2026, 7, 14, 8, 0),
      ]);

      expect(result.map((s) => s.label), ['Today', 'Yesterday', 'Jul 13']);
      expect(result.last.items.map((d) => d.hour), [20, 8]);
    });

    test('section day is midnight, not the row time', () {
      final result = sections([DateTime(2026, 7, 15, 14, 22)]);
      expect(result.single.day, DateTime(2026, 7, 15));
    });

    test('every item survives the grouping', () {
      final dates = [
        for (var d = 1; d <= 15; d++) DateTime(2026, 7, d, 10, 0),
        for (var d = 1; d <= 15; d++) DateTime(2026, 7, d, 16, 0),
      ];
      final result = sections(dates);
      expect(result, hasLength(15));
      expect(
        result.fold<int>(0, (sum, s) => sum + s.items.length),
        dates.length,
      );
    });
  });
}
