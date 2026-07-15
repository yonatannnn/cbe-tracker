/// Reconcile tab — "in SMS but not in screenshots" (§8 Phase 6, FR-5).
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/ids.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/daos/settings_dao.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../data/db/tables.dart';
import 'reconcile_providers.dart';
import 'sms_permission_explainer.dart';

class ReconcileScreen extends ConsumerWidget {
  const ReconcileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sms = ref.watch(smsServiceProvider);
    final permission = ref.watch(smsPermissionStateProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reconcile'),
        actions: [
          if (sms.isSupported && permission == SmsPermissionState.granted)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Sync CBE messages',
              onPressed: () => ref.read(smsServiceProvider).syncInbox(),
            ),
        ],
      ),
      body: !sms.isSupported
          ? const _UnsupportedState()
          : switch (permission) {
              null => const Center(child: CircularProgressIndicator()),
              SmsPermissionState.unasked => const SmsPermissionExplainer(),
              SmsPermissionState.skipped => const _SkippedState(),
              SmsPermissionState.granted => const _DayView(),
            },
    );
  }
}

/// iOS: the feature simply isn't available; everything else still works (§FR-4).
class _UnsupportedState extends StatelessWidget {
  const _UnsupportedState();

  @override
  Widget build(BuildContext context) {
    return _EmptyCard(
      icon: Icons.phone_iphone,
      title: 'SMS sync is available on Android',
      body:
          'Screenshots work exactly the same here — only the automatic '
          'cross-check with CBE messages is missing.',
    );
  }
}

/// Skipped or denied — offer a way back in.
class _SkippedState extends ConsumerWidget {
  const _SkippedState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _EmptyCard(
              icon: Icons.sms_failed_outlined,
              title: 'SMS sync is off',
              body:
                  'Turn it on to be told when a payment arrived by SMS but '
                  'no screenshot was added.',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => ref
                  .read(settingsDaoProvider)
                  .setSmsPermissionState(SmsPermissionState.unasked),
              child: const Text('Turn on SMS sync'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayView extends ConsumerWidget {
  const _DayView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final day = ref.watch(reconcileDayProvider);
    final unmatched = ref.watch(unmatchedSmsForDayProvider);
    final ignored = ref.watch(ignoredSmsForDayProvider).value ?? const [];
    final counts = ref.watch(smsCountsForDayProvider).value;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _DayPicker(day: day),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _SummaryCard(
                label: 'SMS received',
                value: '${counts?.received ?? 0}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _SummaryCard(
                label: 'Matched',
                value: '${counts?.matched ?? 0}',
                color: const Color(0xFF1B7A43),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        unmatched.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Could not load: $e'),
          data: (rows) => rows.isEmpty
              ? _EmptyCard(
                  icon: Icons.check_circle_outline,
                  title: 'Everything matched',
                  body: 'Every CBE message this day has a screenshot.',
                )
              : Column(
                  children: [for (final sms in rows) _UnmatchedRow(sms: sms)],
                ),
        ),
        if (ignored.isNotEmpty) ...[
          const SizedBox(height: 12),
          _IgnoredSection(rows: ignored),
        ],
      ],
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
              .read(reconcileDayProvider.notifier)
              .select(day.subtract(const Duration(days: 1))),
        ),
        Expanded(
          child: TextButton(
            onPressed: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: day,
                firstDate: DateTime(2024),
                lastDate: DateTime(today.year + 1),
              );
              if (picked != null) {
                ref.read(reconcileDayProvider.notifier).select(picked);
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
          // Never navigate into the future.
          onPressed: isToday
              ? null
              : () => ref
                    .read(reconcileDayProvider.notifier)
                    .select(day.add(const Duration(days: 1))),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnmatchedRow extends ConsumerWidget {
  const _UnmatchedRow({required this.sms});

  final SmsTransaction sms;

  String get _time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(sms.receivedAt.hour)}:${two(sms.receivedAt.minute)}';
  }

  String get _snippet {
    final oneLine = sms.smsBody.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 90 ? oneLine : '${oneLine.substring(0, 90)}…';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isCredit = sms.type == TxType.credit;
    final signed = isCredit ? sms.amountCents : -sms.amountCents;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  formatSignedCents(signed),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: isCredit
                        ? const Color(0xFF1B7A43)
                        : theme.colorScheme.error,
                  ),
                ),
                const SizedBox(width: 8),
                if (sms.type != null) _TypeBadge(isCredit: isCredit),
                const Spacer(),
                Text(
                  _time,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _snippet,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: () => _addToBranch(context, ref),
                  child: const Text('Add to branch'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => _ignore(context, ref),
                  child: const Text('Ignore (personal)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Creates a real transaction from the SMS data and links it (§FR-5).
  Future<void> _addToBranch(BuildContext context, WidgetRef ref) async {
    final branches = ref.read(activeBranchesProvider).value ?? const <Branch>[];
    if (branches.isEmpty) return;

    final branch = await showModalBottomSheet<Branch>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Add to which branch?',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final b in branches)
              ListTile(
                title: Text(b.name),
                onTap: () => Navigator.pop(sheetContext, b),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (branch == null || !context.mounted) return;

    final txDao = ref.read(transactionDaoProvider);
    final reference = sms.reference ?? manualReference();
    await txDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: branch.id,
        amountCents: sms.amountCents,
        type: sms.type ?? TxType.credit,
        reference: reference,
        // Came from the shadow ledger, not a screenshot.
        source: TxSource.sms,
        transactionDate: sms.receivedAt,
        ocrText: Value(sms.smsBody),
      ),
    );
    // Link it straight away rather than waiting for the next sweep.
    await ref.read(reconcileServiceProvider).reconcile();

    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Added to ${branch.name}')));
  }

  Future<void> _ignore(BuildContext context, WidgetRef ref) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Mark as personal?',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text("It won't appear in reports."),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(sheetContext, true),
                child: const Text('Mark as personal'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(sheetContext, false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;

    final dao = ref.read(smsDaoProvider);
    await dao.setIgnored(sms.id, true);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Marked personal'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => dao.setIgnored(sms.id, false),
        ),
      ),
    );
  }
}

/// Collapsed "Ignored today (n)" with an unignore action (§FR-5).
class _IgnoredSection extends ConsumerWidget {
  const _IgnoredSection({required this.rows});

  final List<SmsTransaction> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        title: Text('Ignored (${rows.length})'),
        shape: const Border(),
        children: [
          for (final sms in rows)
            ListTile(
              dense: true,
              title: Text(
                formatSignedCents(
                  sms.type == TxType.credit
                      ? sms.amountCents
                      : -sms.amountCents,
                ),
              ),
              subtitle: Text(
                sms.reference ?? 'no reference',
                style: AppTextStyles.mono.copyWith(fontSize: 11),
              ),
              trailing: TextButton(
                onPressed: () =>
                    ref.read(smsDaoProvider).setIgnored(sms.id, false),
                child: const Text('Unignore'),
              ),
            ),
        ],
      ),
    );
  }
}

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.isCredit});

  final bool isCredit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: isCredit ? scheme.primaryContainer : scheme.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isCredit ? 'CREDIT' : 'DEBIT',
        style: TextStyle(
          color: isCredit ? scheme.onPrimaryContainer : scheme.onErrorContainer,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              body,
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
