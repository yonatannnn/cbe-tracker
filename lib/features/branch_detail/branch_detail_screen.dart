/// Branch detail: balance, today's in/out, day-grouped history (§FR-7).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../data/db/tables.dart';
import 'branch_detail_providers.dart';
import 'day_grouping.dart';

/// Green for money in; money out uses the scheme's error colour.
const Color kCreditGreen = Color(0xFF1B7A43);

class BranchDetailScreen extends ConsumerWidget {
  const BranchDetailScreen({super.key, required this.branchId});

  final int branchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branch = ref.watch(branchByIdProvider(branchId));
    final rows = ref.watch(branchTransactionsProvider(branchId));

    return Scaffold(
      appBar: AppBar(
        title: Text(branch?.name ?? 'Branch'),
        actions: [
          if (branch != null)
            PopupMenuButton<String>(
              onSelected: (value) => switch (value) {
                'rename' => _rename(context, ref, branch),
                'archive' => _archive(context, ref, branch),
                _ => null,
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(value: 'archive', child: Text('Archive')),
              ],
            ),
        ],
      ),
      body: rows.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text("Couldn't load: $error")),
        data: (items) => _Body(branchId: branchId, items: items),
      ),
    );
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    Branch branch,
  ) async {
    final controller = TextEditingController(text: branch.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename branch'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Branch name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == branch.name) return;
    await ref.read(branchDaoProvider).renameBranch(branch.id, name);
  }

  Future<void> _archive(
    BuildContext context,
    WidgetRef ref,
    Branch branch,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Archive ${branch.name}?'),
        content: const Text(
          'It leaves the dashboard and reports. Its transactions are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    await ref.read(branchDaoProvider).archiveBranch(branch.id);
    if (context.mounted && context.canPop()) context.pop();
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.branchId, required this.items});

  final int branchId;
  final List<TransactionWithSms> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return _EmptyState(branchId: branchId);

    final sections = groupByDay<TransactionWithSms>(
      items: items,
      dateOf: (item) => item.transaction.transactionDate,
      now: DateTime.now(),
    );

    // Flatten to a single index space so the whole history can be a
    // ListView.builder — a Column would build every row up front.
    final flat = <Object>[];
    for (final section in sections) {
      flat.add(section.label);
      flat.addAll(section.items);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      // +1 for the summary card pinned at the top of the scroll.
      itemCount: flat.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _SummaryCard(branchId: branchId);
        final entry = flat[index - 1];
        if (entry is String) return _DayHeader(label: entry);
        return _TransactionRow(row: entry as TransactionWithSms);
      },
    );
  }
}

class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.branchId});

  final int branchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final balance = ref.watch(branchBalanceCentsProvider(branchId));
    final today = ref.watch(branchTodaySummaryProvider(branchId)).value;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current balance', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Text(
              balance.maybeWhen(data: formatCents, orElse: () => '—'),
              style: AppTextStyles.money,
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: _TodayFigure(
                    label: 'In today',
                    cents: today?.creditedCents ?? 0,
                    color: kCreditGreen,
                  ),
                ),
                Expanded(
                  child: _TodayFigure(
                    label: 'Out today',
                    cents: today?.debitedCents ?? 0,
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TodayFigure extends StatelessWidget {
  const _TodayFigure({
    required this.label,
    required this.cents,
    required this.color,
  });

  final String label;
  final int cents;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          formatCents(cents),
          style: theme.textTheme.titleMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 0, 6),
      child: Text(
        label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.outline,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({required this.row});

  final TransactionWithSms row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tx = row.transaction;
    final isCredit = tx.type == TxType.credit;
    final signed = isCredit ? tx.amountCents : -tx.amountCents;

    String two(int v) => v.toString().padLeft(2, '0');
    final time =
        '${two(tx.transactionDate.hour)}:${two(tx.transactionDate.minute)}';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/transaction/${tx.id}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _Thumbnail(path: tx.screenshotPath, source: tx.source),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatSignedCents(signed),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: isCredit ? kCreditGreen : theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      tx.reference,
                      style: AppTextStyles.mono.copyWith(
                        fontSize: 11,
                        color: theme.colorScheme.outline,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Verified = a CBE SMS corroborates this screenshot.
                  Icon(
                    row.isVerified ? Icons.verified : Icons.verified_outlined,
                    size: 16,
                    color: row.isVerified
                        ? kCreditGreen
                        : theme.colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    time,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Screenshot thumbnail, or a source-appropriate icon when there is none
/// (SMS-created and manual rows have no image).
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path, required this.source});

  final String? path;
  final TxSource source;

  static const double _size = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (path == null || path!.isEmpty) {
      return Container(
        width: _size,
        height: _size,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          source == TxSource.sms ? Icons.sms_outlined : Icons.edit_outlined,
          size: 18,
          color: scheme.outline,
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        File(path!),
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        // These are small; decode small (§2 — avoids list jank).
        cacheWidth: 120,
        errorBuilder: (context, _, _) => Container(
          width: _size,
          height: _size,
          color: scheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined, size: 18),
        ),
      ),
    );
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState({required this.branchId});

  final int branchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 44,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('No transactions yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Add a CBE screenshot from the dashboard and it will appear here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
