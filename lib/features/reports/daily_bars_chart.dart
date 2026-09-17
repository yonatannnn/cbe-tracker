/// Seven-day bar chart for the Reports tab: money in and money out per day.
///
/// Plain widgets, no charting package (§5). Two series, so a legend is always
/// shown, and the two are told apart by fill as well as hue — IN is a solid
/// bar, OUT is an outlined one — because green against red alone is not
/// enough for red-green colour blindness. Tapping a column selects that day
/// for the report below, and the caption under the chart names the selected
/// day's figures in words, so no bar needs a number printed on it.
library;

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/dates/day_format.dart';
import '../../core/money/etb_format.dart';
import 'daily_bars.dart';

class DailyBarsChart extends StatelessWidget {
  const DailyBarsChart({
    super.key,
    required this.days,
    required this.selected,
    required this.today,
    required this.onSelect,
  });

  final List<DayTotals> days;

  /// Midnight of the day the report below is showing.
  final DateTime selected;
  final DateTime today;
  final ValueChanged<DateTime> onSelect;

  static const double _plotHeight = 120;
  static const double _barWidth = 10;
  static const double _barGap = 2;
  static const double _minBar = 3;

  @override
  Widget build(BuildContext context) {
    final max = maxBarCents(days);
    final selectedTotals = days.firstWhere(
      (d) => d.day == selected,
      orElse: () => DayTotals(day: selected),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('LAST 7 DAYS', style: AppTextStyles.label),
              ),
              const _LegendSwatch(label: 'In', solid: true),
              const SizedBox(width: 12),
              const _LegendSwatch(label: 'Out', solid: false),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: _plotHeight + 26,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final d in days)
                  Expanded(
                    child: _DayColumn(
                      totals: d,
                      max: max,
                      isSelected: d.day == selected,
                      isToday: d.day == today,
                      onTap: () => onSelect(d.day),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          _Caption(totals: selectedTotals, today: today, empty: max == 0),
        ],
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.totals,
    required this.max,
    required this.isSelected,
    required this.isToday,
    required this.onTap,
  });

  final DayTotals totals;
  final int max;
  final bool isSelected;
  final bool isToday;
  final VoidCallback onTap;

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  double _height(int cents) {
    if (cents <= 0 || max <= 0) return 0;
    final h = DailyBarsChart._plotHeight * cents / max;
    // A tiny amount still gets a visible sliver: "something happened".
    return h < DailyBarsChart._minBar ? DailyBarsChart._minBar : h;
  }

  @override
  Widget build(BuildContext context) {
    final label = _weekdays[totals.day.weekday - 1];

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? AppColors.line.withValues(alpha: 0.45) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _Bar(height: _height(totals.creditCents), solid: true),
                  const SizedBox(width: DailyBarsChart._barGap),
                  _Bar(height: _height(totals.debitCents), solid: false),
                ],
              ),
            ),
            // Baseline: one recessive rule the bars stand on.
            Container(height: 1, color: AppColors.line),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? AppColors.ink : AppColors.muted,
              ),
            ),
            Text(
              '${totals.day.day}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                color: isSelected ? AppColors.ink : AppColors.muted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One bar. IN is solid credit green; OUT is a debit-red outline over a wash,
/// so the pair reads apart without relying on hue.
class _Bar extends StatelessWidget {
  const _Bar({required this.height, required this.solid});

  final double height;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.vertical(top: Radius.circular(4));
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: DailyBarsChart._barWidth,
      height: height,
      decoration: solid
          ? const BoxDecoration(color: AppColors.credit, borderRadius: radius)
          : BoxDecoration(
              color: AppColors.debitWash,
              borderRadius: radius,
              border: height > 0
                  ? Border.all(color: AppColors.debit, width: 1.5)
                  : null,
            ),
    );
  }
}

class _LegendSwatch extends StatelessWidget {
  const _LegendSwatch({required this.label, required this.solid});

  final String label;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: solid
              ? BoxDecoration(
                  color: AppColors.credit,
                  borderRadius: BorderRadius.circular(2),
                )
              : BoxDecoration(
                  color: AppColors.debitWash,
                  border: Border.all(color: AppColors.debit, width: 1.5),
                  borderRadius: BorderRadius.circular(2),
                ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ],
    );
  }
}

/// The selected day in words — the chart's "tooltip".
class _Caption extends StatelessWidget {
  const _Caption({
    required this.totals,
    required this.today,
    required this.empty,
  });

  final DayTotals totals;
  final DateTime today;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final name = formatDayRelative(totals.day, today: today);
    final text = empty
        ? 'No transactions in the last 7 days'
        : totals.isEmpty
        ? '$name · no transactions'
        : '$name · In ${formatCents(totals.creditCents)} · '
              'Out ${formatCents(totals.debitCents)} · '
              '${totals.count} ${totals.count == 1 ? 'transaction' : 'transactions'}';
    return Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 12, color: AppColors.muted),
    );
  }
}
