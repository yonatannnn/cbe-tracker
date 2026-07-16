/// Branch detail: balance, today's in/out, day-grouped history (§FR-7).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../data/db/tables.dart';
import '../../services/service_providers.dart';
import '../reconcile/reconcile_providers.dart';
import 'branch_detail_providers.dart';
import 'day_grouping.dart';


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

    // Flatten to a single index space so a long history can be a
    // ListView.builder — a Column would build every day up front. Each day's
    // rows travel together as one entry, because they share one bordered card:
    // the eye runs down a continuous ledger instead of hopping between
    // floating cards.
    final flat = <Object>[];
    for (final section in sections) {
      flat.add(section.label);
      flat.add(section.items);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xl,
      ),
      // +1 for the balance panel at the top of the scroll.
      itemCount: flat.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) return _SummaryCard(branchId: branchId);
        final entry = flat[index - 1];
        if (entry is String) return _DayHeader(label: entry);
        final day = entry as List<TransactionWithSms>;
        return Card(
          child: Column(
            children: [
              for (var i = 0; i < day.length; i++)
                _TransactionRow(row: day[i], isLast: i == day.length - 1),
            ],
          ),
        );
      },
    );
  }
}

class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.branchId});

  final int branchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(branchBalanceCentsProvider(branchId));
    final today = ref.watch(branchTodaySummaryProvider(branchId)).value;

    final cents = balance.value;

    // Not a card — same reasoning as the dashboard total: the branch's balance
    // IS this page, not an item on it.
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CURRENT BALANCE', style: AppTextStyles.label),
          const SizedBox(height: AppSpacing.sm),
          Text(
            cents == null ? '—' : formatCents(cents),
            style: AppTextStyles.money.copyWith(
              color: (cents ?? 0) < 0 ? AppColors.debit : AppColors.ink,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: _TodayFigure(
                  label: 'IN TODAY',
                  cents: today?.creditedCents ?? 0,
                  color: AppColors.credit,
                ),
              ),
              Container(width: 1, height: 34, color: AppColors.line),
              Expanded(
                child: _TodayFigure(
                  label: 'OUT TODAY',
                  cents: today?.debitedCents ?? 0,
                  color: AppColors.debit,
                ),
              ),
            ],
          ),
        ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.label.copyWith(fontSize: 10)),
        const SizedBox(height: AppSpacing.xs),
        Text(
          formatCents(cents),
          style: AppTextStyles.moneyRow.copyWith(
            // A zero is not news; dim it so a real figure stands out.
            color: cents == 0 ? AppColors.muted : color,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, AppSpacing.xl, 0, AppSpacing.sm),
      child: Text(label.toUpperCase(), style: AppTextStyles.label),
    );
  }
}

class _TransactionRow extends ConsumerWidget {
  const _TransactionRow({required this.row, required this.isLast});

  final TransactionWithSms row;

  /// Rows share one bordered card per day, so only the last one skips its
  /// divider — a continuous ledger rather than a stack of floating cards.
  final bool isLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tx = row.transaction;
    final isCredit = tx.type == TxType.credit;
    final signed = isCredit ? tx.amountCents : -tx.amountCents;

    String two(int v) => v.toString().padLeft(2, '0');
    final time =
        '${two(tx.transactionDate.hour)}:${two(tx.transactionDate.minute)}';

    return Column(
      children: [
        InkWell(
          onTap: () => context.push('/transaction/${tx.id}'),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Row(
              children: [
                _Thumbnail(path: tx.screenshotPath, source: tx.source),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatSignedCents(signed),
                        style: AppTextStyles.moneyRow.copyWith(
                          color: isCredit ? AppColors.credit : AppColors.debit,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        tx.reference,
                        style: AppTextStyles.mono.copyWith(
                          fontSize: 10,
                          color: AppColors.muted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // The verification column. Every row reports its state in the
                // same place, so a GAP in the column is what catches the eye —
                // that gap is a payment with no CBE message behind it. Only
                // meaningful while the cross-check runs: on iOS or with SMS
                // skipped every row would show the gap, turning a signal into
                // permanent noise.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (ref.watch(smsCrossCheckActiveProvider))
                      Icon(
                        row.isVerified ? Icons.verified : Icons.remove,
                        size: 14,
                        color: row.isVerified
                            ? AppColors.credit
                            : AppColors.line,
                      ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      time,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.muted,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!isLast) const Divider(indent: 68),
      ],
    );
  }
}

/// Screenshot thumbnail, or a source-appropriate icon when there is none
/// (SMS-created and manual rows have no image).
class _Thumbnail extends ConsumerWidget {
  const _Thumbnail({required this.path, required this.source});

  final String? path;
  final TxSource source;

  static const double _size = 44;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    // Stored paths are relative to the documents dir (§2), so they survive the
    // reinstall or restore that changes the app's absolute sandbox path.
    final file = ref.watch(imageStoreProvider).resolve(path);

    if (file == null) {
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
        file,
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
