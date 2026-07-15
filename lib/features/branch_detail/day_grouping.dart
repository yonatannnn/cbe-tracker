/// Groups a transaction list into day sections for the branch detail list
/// (§FR-7). Pure — no Flutter, no database, so the Today/Yesterday edges are
/// testable at a fixed "now".
library;

/// One day's worth of rows, with the header to show above them.
class DaySection<T> {
  const DaySection({
    required this.day,
    required this.label,
    required this.items,
  });

  /// Midnight, local.
  final DateTime day;

  /// "Today", "Yesterday", or "Jul 13".
  final String label;

  final List<T> items;
}

const List<String> _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

DateTime _startOfDay(DateTime moment) =>
    DateTime(moment.year, moment.month, moment.day);

/// The header for [day], relative to [now].
///
/// Falls back to "MMM d", plus the year when it isn't the current one — "Jul
/// 13" alone would be ambiguous once a history spans new year.
String dayLabel(DateTime day, DateTime now) {
  final today = _startOfDay(now);
  final target = _startOfDay(day);
  final diff = today.difference(target).inDays;

  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';

  final month = _monthNames[target.month - 1];
  return target.year == today.year
      ? '$month ${target.day}'
      : '$month ${target.day}, ${target.year}';
}

/// Groups [items] into day sections, newest day first and newest row first
/// within each day.
///
/// Grouping is on the LOCAL calendar day, matching how balances and reports
/// bracket a day elsewhere.
List<DaySection<T>> groupByDay<T>({
  required List<T> items,
  required DateTime Function(T item) dateOf,
  required DateTime now,
}) {
  if (items.isEmpty) return const [];

  final byDay = <DateTime, List<T>>{};
  for (final item in items) {
    byDay.putIfAbsent(_startOfDay(dateOf(item)), () => []).add(item);
  }

  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));

  return [
    for (final day in days)
      DaySection<T>(
        day: day,
        label: dayLabel(day, now),
        items: byDay[day]!..sort((a, b) => dateOf(b).compareTo(dateOf(a))),
      ),
  ];
}
