/// Reports tab: per-branch daily figures + PDF export (§8 Phase 8, FR-6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../services/report_service.dart';
import 'reports_providers.dart';

const Color _creditGreen = Color(0xFF1B7A43);
const Color _amber = Color(0xFF8A5A00);

class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final report = ref.watch(dailyReportProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: report.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text("Couldn't build report: $error")),
        data: (data) => _Body(report: data),
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
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
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
        final file = await pdf.buildForBranch(
          branch,
          _report.day,
          _report.footer,
        );
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
            padding: const EdgeInsets.all(16),
            children: [
              for (final branch in _report.branches) ...[
                _BranchCard(branch: branch),
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
              const SizedBox(height: 8),
              // §FR-6 footer line.
              Text(
                '${_report.footer.personalCount} SMS marked personal · '
                '${_report.footer.unresolvedCount} unresolved',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
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
                  _VerificationBadge(branch: branch),
                ],
              ),
              const SizedBox(height: 12),
              _Figure(label: 'Opening', cents: summary.openingCents),
              _Figure(
                label: 'Credited',
                cents: summary.creditedCents,
                color: _creditGreen,
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

class _VerificationBadge extends StatelessWidget {
  const _VerificationBadge({required this.branch});

  final BranchDayReport branch;

  @override
  Widget build(BuildContext context) {
    // Green only when everything is vouched for; amber while any row isn't.
    final full = branch.isFullyVerified;
    final color = full ? _creditGreen : _amber;
    final background = full ? const Color(0xFFDCF0E4) : const Color(0xFFFFF3D6);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(full ? Icons.verified : Icons.info_outline, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '${branch.verificationLabel} verified',
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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

class _TransactionLine extends StatelessWidget {
  const _TransactionLine({required this.row});

  final TransactionWithSms row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tx = row.transaction;
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
          Icon(
            row.isVerified ? Icons.verified : Icons.verified_outlined,
            size: 12,
            color: row.isVerified
                ? _creditGreen
                : theme.colorScheme.outlineVariant,
          ),
          const SizedBox(width: 8),
          Text(
            formatSignedCents(signed),
            style: theme.textTheme.bodySmall?.copyWith(
              color: isCredit ? _creditGreen : theme.colorScheme.error,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
