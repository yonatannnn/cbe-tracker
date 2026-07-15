import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../reconcile/reconcile_providers.dart';

/// Home tab — total balance, SMS warning, branch cards, FAB (§FR-8).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(activeBranchesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('CBE Tracker'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showAddMethodSheet(context),
        tooltip: 'Add transaction',
        child: const Icon(Icons.add),
      ),
      body: branches.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text("Couldn't load branches: $error")),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            const _TotalCard(),
            const SizedBox(height: 12),
            const _SmsWarningBanner(),
            const SizedBox(height: 4),
            for (final branch in list) ...[
              _BranchCard(branch: branch),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

/// Total across active branches + today's delta.
class _TotalCard extends ConsumerWidget {
  const _TotalCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final total = ref.watch(totalBalanceCentsProvider);
    final delta = ref.watch(todayDeltaCentsProvider).value ?? 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Total balance', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Text(
              total.maybeWhen(data: formatCents, orElse: () => '—'),
              style: AppTextStyles.money.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
            // Hidden entirely when today's delta is zero.
            if (delta != 0) ...[
              const SizedBox(height: 6),
              Text(
                '${formatSignedCents(delta)} today',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: delta > 0 ? _positive : theme.colorScheme.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Green for money in. Red for money out comes from the scheme's error color.
const Color _positive = Color(0xFF1B7A43);

/// Unmatched-SMS warning (§FR-8). Driven by a provider stubbed to 0 until
/// Phase 6, so it stays hidden for now.
class _SmsWarningBanner extends ConsumerWidget {
  const _SmsWarningBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(unmatchedSmsCountProvider).value ?? 0;
    if (count == 0) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.go('/reconcile'),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    count == 1
                        ? '1 SMS not matched to a screenshot today'
                        : '$count SMS not matched to a screenshot today',
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onErrorContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One branch: name, today's count, live balance.
class _BranchCard extends ConsumerWidget {
  const _BranchCard({required this.branch});

  final Branch branch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final balance = ref.watch(branchBalanceCentsProvider(branch.id));
    final todayCount = ref.watch(branchTodayCountProvider(branch.id));
    final count = todayCount.value ?? 0;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/branch/${branch.id}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(branch.name, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      count == 1
                          ? '1 transaction today'
                          : '$count transactions today',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                balance.maybeWhen(data: formatCents, orElse: () => '—'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// FAB → add-method chooser (§7 sheets).
Future<void> _showAddMethodSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Single screenshot'),
            onTap: () {
              Navigator.pop(sheetContext);
              context.push('/add-single');
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Bulk upload'),
            onTap: () {
              Navigator.pop(sheetContext);
              context.push('/add-bulk');
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}
