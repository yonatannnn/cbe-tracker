/// Reports tab: per-branch daily figures + PDF export (§8 Phase 8, FR-6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../services/report_service.dart';
import 'daily_bars_chart.dart';
import 'reports_providers.dart';

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(dailyReportProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: SafeArea(
        child: report.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) =>
              Center(child: Text("Couldn't build report: $error")),
          data: (data) => _Body(report: data),
        ),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.report});

  final DailyReport report;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _sharing = false;

  DailyReport get _report => widget.report;

  Future<void> _shareCombined() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final file = await ref.read(pdfServiceProvider).buildCombined(_report);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: 'Branch report — ${_longDate(_report.day)}',
        ),
      );
    } on Object {
      // Building the PDF loads fonts, writes a temp file and crosses a platform
      // channel — any of which can fail. Without this the exception went to the
      // console and she saw only the spinner blink: the report she needs at
      // closing time appears to do nothing, forever.
      _say("Couldn't build the report. Try again.");
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _sharePerBranch() async {
    if (_sharing) return;
    final branches = _report.activeBranches;
    if (branches.isEmpty) return;

    setState(() => _sharing = true);
    try {
      final pdf = ref.read(pdfServiceProvider);
      final files = <XFile>[];
      for (final branch in branches) {
        final file = await pdf.buildForBranch(branch, _report.day);
        files.add(XFile(file.path));
      }
      // One PDF per branch, shared together — she forwards each to the right
      // person from the share sheet.
      await SharePlus.instance.share(
        ShareParams(
          files: files,
          text: 'Per-branch reports — ${_longDate(_report.day)}',
        ),
      );
    } on Object {
      _say("Couldn't build the reports. Try again.");
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasAnything = _report.activeBranches.isNotEmpty;

    return Column(
      children: [
        _DayPicker(day: _report.day),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
            children: [
              const _WeekChart(),
              const Divider(height: 1),
              const SizedBox(height: 16),
              for (final branch in _report.branches) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _BranchCard(branch: branch),
                ),
                const SizedBox(height: 10),
              ],
              if (_report.branches.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'No active branches.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: _sharing
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: hasAnything ? _sharePerBranch : null,
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          label: const Text('Per branch'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: hasAnything ? _shareCombined : null,
                          icon: const Icon(Icons.share_outlined),
                          label: const Text('Share all'),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  static const List<String> _months = [
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

  static String _longDate(DateTime day) =>
      '${_months[day.month - 1]} ${day.day}, ${day.year}';
}

/// The seven-day chart; tapping a column moves the report to that day.
class _WeekChart extends ConsumerWidget {
  const _WeekChart();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = ref.watch(dailyBarsProvider).value;
    if (days == null) return const SizedBox(height: 180);
    return DailyBarsChart(
      days: days,
      selected: ref.watch(reportDayProvider),
      today: ref.watch(todayProvider),
      onSelect: (day) => ref.read(reportDayProvider.notifier).select(day),
    );
  }
}

class _DayPicker extends ConsumerWidget {
  const _DayPicker({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String two(int v) => v.toString().padLeft(2, '0');
    final today = DateTime.now();
    final isToday =
        day.year == today.year &&
        day.month == today.month &&
        day.day == today.day;

    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          onPressed: () => ref
              .read(reportDayProvider.notifier)
              .select(day.subtract(const Duration(days: 1))),
        ),
        Expanded(
          child: TextButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: day,
                firstDate: DateTime(2024),
                lastDate: today,
              );
              if (picked != null) {
                ref.read(reportDayProvider.notifier).select(picked);
              }
            },
            child: Text(
              isToday
                  ? 'Today'
                  : '${two(day.day)}/${two(day.month)}/${day.year}',
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          // A report for the future would be meaningless.
          onPressed: isToday
              ? null
              : () => ref
                    .read(reportDayProvider.notifier)
                    .select(day.add(const Duration(days: 1))),
        ),
      ],
    );
  }
}

class _BranchCard extends StatefulWidget {
  const _BranchCard({required this.branch});

  final BranchDayReport branch;

  @override
  State<_BranchCard> createState() => _BranchCardState();
}

class _BranchCardState extends State<_BranchCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branch = widget.branch;
    final summary = branch.summary;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: branch.hasTransactions
            ? () => setState(() => _expanded = !_expanded)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      branch.branch.name,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _Figure(label: 'Opening', cents: summary.openingCents),
              _Figure(
                label: 'Credited',
                cents: summary.creditedCents,
                color: AppColors.credit,
              ),
              _Figure(
                label: 'Debited',
                cents: summary.debitedCents,
                color: theme.colorScheme.error,
              ),
              const Divider(height: 18),
              _Figure(
                label: 'Closing',
                cents: summary.closingCents,
                bold: true,
              ),
              if (branch.hasTransactions) ...[
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      branch.totalCount == 1
                          ? '1 transaction'
                          : '${branch.totalCount} transactions',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  ],
                ),
              ],
              if (_expanded) ...[
                const Divider(height: 18),
                for (final row in branch.transactions)
                  _TransactionLine(row: row),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.cents,
    this.color,
    this.bold = false,
  });

  final String label;
  final int cents;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          Text(
            formatCents(cents),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
              // Digits line up down the column.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionLine extends ConsumerWidget {
  const _TransactionLine({required this.row});

  final Transaction row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tx = row;
    final isCredit = tx.type == TxType.credit;
    final signed = isCredit ? tx.amountCents : -tx.amountCents;
    String two(int v) => v.toString().padLeft(2, '0');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 42,
            child: Text(
              '${two(tx.transactionDate.hour)}:'
              '${two(tx.transactionDate.minute)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: Text(
              tx.reference,
              style: AppTextStyles.mono.copyWith(fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            formatSignedCents(signed),
            style: theme.textTheme.bodySmall?.copyWith(
              color: isCredit ? AppColors.credit : theme.colorScheme.error,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
