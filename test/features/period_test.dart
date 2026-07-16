// The period arithmetic decides which transactions land in the headline
// figure, so a wrong bound silently miscounts money. resolvePeriod is pure, so
// every window is checked here without a container or a clock.

import 'package:cbe_tracker/data/db/database_provider.dart';
import 'package:cbe_tracker/features/dashboard/period.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fixed day so the notifier resolves without a clock or a pending timer.
class _FixedToday extends Today {
  @override
  DateTime build() => DateTime(2026, 7, 15);
}

void main() {
  // A Wednesday, so "this week" has to reach back to Monday and the
  // Monday-vs-Sunday choice actually shows.
  final wed = DateTime(2026, 7, 15);

  Period resolve(PeriodKind kind, {DateTime? anchor, DateTime? rangeEnd}) =>
      resolvePeriod(
        PeriodSelection(kind, anchor: anchor, rangeEnd: rangeEnd),
        wed,
      );

  group('preset windows are half-open [start, end)', () {
    test('today is the single calendar day', () {
      final p = resolve(PeriodKind.today);
      expect(p.start, DateTime(2026, 7, 15));
      expect(p.end, DateTime(2026, 7, 16));
      expect(p.isMovement, isTrue);
    });

    test('this week starts Monday and ends tomorrow midnight', () {
      final p = resolve(PeriodKind.thisWeek);
      expect(p.start, DateTime(2026, 7, 13), reason: 'Monday of that week');
      expect(p.start!.weekday, DateTime.monday);
      expect(p.end, DateTime(2026, 7, 16));
    });

    test('this month starts on the 1st', () {
      final p = resolve(PeriodKind.thisMonth);
      expect(p.start, DateTime(2026, 7, 1));
      expect(p.end, DateTime(2026, 7, 16));
    });

    test('all time is unbounded and reads as a balance, not movement', () {
      final p = resolve(PeriodKind.allTime);
      expect(p.start, isNull);
      expect(p.end, isNull);
      expect(p.isMovement, isFalse);
    });
  });

  group('custom windows', () {
    test('a single day brackets exactly that day', () {
      final p = resolve(PeriodKind.day, anchor: DateTime(2026, 3, 4));
      expect(p.start, DateTime(2026, 3, 4));
      expect(p.end, DateTime(2026, 3, 5));
      expect(p.label, '4 Mar 2026');
    });

    test('a range is inclusive of its last day', () {
      final p = resolve(
        PeriodKind.range,
        anchor: DateTime(2026, 3, 1),
        rangeEnd: DateTime(2026, 3, 31),
      );
      expect(p.start, DateTime(2026, 3, 1));
      // 31 Mar inclusive → exclusive bound is 1 Apr midnight.
      expect(p.end, DateTime(2026, 4, 1));
    });
  });

  group('selection is defensive', () {
    test('chooseRange reorders a backwards pick into a valid window', () {
      final container = ProviderContainer(
        overrides: [todayProvider.overrideWith(_FixedToday.new)],
      );
      addTearDown(container.dispose);

      // Last day handed in before the first — a real date-picker outcome.
      container
          .read(selectedPeriodProvider.notifier)
          .chooseRange(DateTime(2026, 3, 31), DateTime(2026, 3, 1));

      final p = container.read(activePeriodProvider);
      expect(p.start, DateTime(2026, 3, 1));
      expect(p.end, DateTime(2026, 4, 1));
      expect(p.start!.isBefore(p.end!), isTrue);
    });
  });

  group('week boundary edges', () {
    test('on a Monday, this week is just that day so far', () {
      final monday = DateTime(2026, 7, 13);
      final p = resolvePeriod(
        const PeriodSelection(PeriodKind.thisWeek),
        monday,
      );
      expect(p.start, monday);
      expect(p.end, DateTime(2026, 7, 14));
    });

    test('on a Sunday, this week still reaches back to Monday', () {
      final sunday = DateTime(2026, 7, 19);
      expect(sunday.weekday, DateTime.sunday);
      final p = resolvePeriod(
        const PeriodSelection(PeriodKind.thisWeek),
        sunday,
      );
      expect(p.start, DateTime(2026, 7, 13));
      expect(p.end, DateTime(2026, 7, 20));
    });
  });
}
