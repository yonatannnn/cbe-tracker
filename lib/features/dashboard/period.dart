/// The date window the dashboard is showing, resolved against the live day.
///
/// The old code baked `DateTime.now()` into each provider at first watch, so
/// "today" froze at whatever day the app was launched — leave it open overnight
/// and the dashboard reported yesterday — and there was no way to ask "how did
/// this month go?". Both come down to reading the day as a live value:
/// [todayProvider] (in the providers hub) is that value, [Period] turns it into
/// a window, and [activePeriodProvider] is the window the page renders.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database_provider.dart';

/// Which window the dashboard headline and branch cards cover.
enum PeriodKind { today, thisWeek, thisMonth, allTime, day, range }

/// A resolved date window, half-open: [start] inclusive, [end] exclusive.
///
/// A null bound is unbounded — null [start] reaches the first transaction, null
/// [end] runs to now — so `allTime` is `(null, null)`. `isMovement` is false
/// only for `allTime`, where the figure is a standing balance rather than
/// money that moved inside a window; the UI signs and colours the two
/// differently on that basis.
class Period {
  const Period({required this.kind, required this.label, this.start, this.end});

  final PeriodKind kind;
  final String label;
  final DateTime? start;
  final DateTime? end;

  bool get isMovement => kind != PeriodKind.allTime;

  @override
  bool operator ==(Object other) =>
      other is Period &&
      other.kind == kind &&
      other.label == label &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(kind, label, start, end);
}

/// The user's choice, before it's resolved against the live day.
///
/// Holds the [kind] plus the picked date(s) for `day`/`range`, but never
/// concrete week/month bounds — those are derived from [todayProvider] so they
/// stay correct across midnight. Defaults to `allTime`, which resolves to the
/// same total balance the dashboard showed before this existed: the page looks
/// unchanged until she picks a window.
class PeriodSelection {
  const PeriodSelection(this.kind, {this.anchor, this.rangeEnd});

  final PeriodKind kind;

  /// `day` → the chosen day. `range` → its first day.
  final DateTime? anchor;

  /// `range` → its last day (inclusive; resolved to an exclusive bound).
  final DateTime? rangeEnd;
}

class SelectedPeriod extends Notifier<PeriodSelection> {
  @override
  PeriodSelection build() => const PeriodSelection(PeriodKind.allTime);

  void choose(PeriodKind kind) => state = PeriodSelection(kind);

  void chooseDay(DateTime day) =>
      state = PeriodSelection(PeriodKind.day, anchor: _dateOnly(day));

  void chooseRange(DateTime first, DateTime last) {
    // Order defensively so a backwards pick still yields a valid window.
    final a = _dateOnly(first);
    final b = _dateOnly(last);
    final lo = a.isAfter(b) ? b : a;
    final hi = a.isAfter(b) ? a : b;
    state = PeriodSelection(PeriodKind.range, anchor: lo, rangeEnd: hi);
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
}

final selectedPeriodProvider =
    NotifierProvider<SelectedPeriod, PeriodSelection>(SelectedPeriod.new);

/// The window actually rendered: the selection resolved against today.
///
/// Watches [todayProvider], so a "This week" view re-resolves when the day
/// rolls — the whole point of not storing concrete bounds in the selection.
final activePeriodProvider = Provider<Period>((ref) {
  final today = ref.watch(todayProvider);
  final selection = ref.watch(selectedPeriodProvider);
  return resolvePeriod(selection, today);
});

/// Turns a [selection] into a concrete [Period] against [today]. Pure, so the
/// bound arithmetic (week starts Monday; month from the 1st) is unit-testable
/// without a container.
Period resolvePeriod(PeriodSelection selection, DateTime today) {
  final tomorrow = today.add(const Duration(days: 1));
  switch (selection.kind) {
    case PeriodKind.today:
      return Period(
        kind: PeriodKind.today,
        label: 'Today',
        start: today,
        end: tomorrow,
      );
    case PeriodKind.thisWeek:
      // Monday-based: DateTime.weekday is 1 (Mon) … 7 (Sun).
      final monday = today.subtract(Duration(days: today.weekday - 1));
      return Period(
        kind: PeriodKind.thisWeek,
        label: 'This week',
        start: monday,
        end: tomorrow,
      );
    case PeriodKind.thisMonth:
      return Period(
        kind: PeriodKind.thisMonth,
        label: 'This month',
        start: DateTime(today.year, today.month),
        end: tomorrow,
      );
    case PeriodKind.allTime:
      return const Period(kind: PeriodKind.allTime, label: 'All time');
    case PeriodKind.day:
      final day = selection.anchor ?? today;
      return Period(
        kind: PeriodKind.day,
        label: _formatDay(day),
        start: day,
        end: day.add(const Duration(days: 1)),
      );
    case PeriodKind.range:
      final first = selection.anchor ?? today;
      final last = selection.rangeEnd ?? first;
      return Period(
        kind: PeriodKind.range,
        label: '${_formatDay(first)} – ${_formatDay(last)}',
        start: first,
        // Inclusive last day → exclusive next-midnight bound.
        end: last.add(const Duration(days: 1)),
      );
  }
}

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

String _formatDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

// ── period-scoped dashboard figures ──────────────────────────────────────────
//
// autoDispose so switching period tears down the previous window's Drift
// subscriptions instead of leaving one live stream per period she ever tapped.
// Each watches activePeriodProvider, so they re-resolve when the day rolls or
// the selection changes, and Drift re-emits on every write within the window.

/// Credits − debits across active branches for the selected window. When the
/// window is "all time" this is the total balance the dashboard always showed.
final periodDeltaCentsProvider = StreamProvider.autoDispose<int>((ref) {
  final period = ref.watch(activePeriodProvider);
  return ref
      .watch(transactionDaoProvider)
      .watchDeltaCentsInRange(period.start, period.end);
});

/// One branch's credits − debits for the selected window (its balance when the
/// window is "all time").
final branchPeriodDeltaProvider = StreamProvider.autoDispose.family<int, int>((
  ref,
  branchId,
) {
  final period = ref.watch(activePeriodProvider);
  return ref
      .watch(transactionDaoProvider)
      .watchBranchDeltaCentsInRange(branchId, period.start, period.end);
});

/// One branch's transaction count for the selected window.
final branchPeriodCountProvider = StreamProvider.autoDispose.family<int, int>((
  ref,
  branchId,
) {
  final period = ref.watch(activePeriodProvider);
  return ref
      .watch(transactionDaoProvider)
      .watchBranchCountInRange(branchId, period.start, period.end);
});
