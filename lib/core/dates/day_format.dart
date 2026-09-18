/// Calendar-day formatting shared by the add flow and the approval sheet.
library;

const _months = [
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

/// "17 Sep 2026".
String formatDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

/// "Today" / "Yesterday" for the two days she is most likely filing, and the
/// plain date for anything older.
String formatDayRelative(DateTime day, {required DateTime today}) {
  final d = DateTime(day.year, day.month, day.day);
  final t = DateTime(today.year, today.month, today.day);
  final diff = t.difference(d).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  return formatDay(d);
}
