import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../reconcile/reconcile_providers.dart';
import 'period.dart';

/// Home tab — the day's position and whether it's complete (§FR-8).
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
          const SizedBox(width: AppSpacing.xs),
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
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            96,
          ),
          children: [
            const _TotalPanel(),
            const SizedBox(height: AppSpacing.xl),
            const _SectionLabel('BRANCHES'),
            const SizedBox(height: AppSpacing.sm),
            _BranchList(branches: list),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: AppTextStyles.label);
}

/// The headline: what the branches add up to over the chosen window, and
/// whether today is accounted for. Deliberately not a card — it's the page, not
/// an item on it.
class _TotalPanel extends ConsumerWidget {
  const _TotalPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(activePeriodProvider);
    final amount = ref.watch(periodDeltaCentsProvider);
    // Only the default all-time view carries the "+X today" line: for any
    // bounded window the headline is already that window's movement, so the
    // line would either repeat it (Today) or distract from it.
    final showTodayLine = !period.isMovement;
    final todayDelta = ref.watch(todayDeltaCentsProvider).value ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(period.label.toUpperCase()),
        const SizedBox(height: AppSpacing.sm),
        Text(
          amount.maybeWhen(
            data: (cents) =>
                period.isMovement ? formatSignedCents(cents) : formatCents(cents),
            orElse: () => '—',
          ),
          style: AppTextStyles.money.copyWith(
            color: periodAmountColor(period, amount.value ?? 0),
          ),
        ),
        if (showTodayLine && todayDelta != 0) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${formatSignedCents(todayDelta)} today',
            style: AppTextStyles.moneyRow.copyWith(
              fontSize: 14,
              color: todayDelta > 0 ? AppColors.credit : AppColors.debit,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        const _PeriodSelector(),
        const SizedBox(height: AppSpacing.lg),
        const _ReconciliationStrip(),
      ],
    );
  }
}

/// The colour a period figure reads in. Movement is signed — green up, red
/// down, neutral at zero. An all-time balance is a standing figure: neutral ink
/// unless it's underwater, where red flags a debt. Shared with the branch rows
/// so the whole page speaks one colour language.
Color periodAmountColor(Period period, int cents) {
  if (!period.isMovement) return cents < 0 ? AppColors.debit : AppColors.ink;
  if (cents > 0) return AppColors.credit;
  if (cents < 0) return AppColors.debit;
  return AppColors.ink;
}

/// Retunes what the headline and branch cards measure: a preset window, or a
/// day / range picked from the calendar.
class _PeriodSelector extends ConsumerWidget {
  const _PeriodSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectedPeriodProvider);
    final period = ref.watch(activePeriodProvider);
    final custom =
        selection.kind == PeriodKind.day || selection.kind == PeriodKind.range;

    Widget preset(String label, PeriodKind kind) => Padding(
          padding: const EdgeInsets.only(right: AppSpacing.sm),
          child: ChoiceChip(
            label: Text(label),
            selected: selection.kind == kind,
            onSelected: (_) =>
                ref.read(selectedPeriodProvider.notifier).choose(kind),
          ),
        );

    return SizedBox(
      height: 38,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          preset('Today', PeriodKind.today),
          preset('This week', PeriodKind.thisWeek),
          preset('This month', PeriodKind.thisMonth),
          preset('All time', PeriodKind.allTime),
          ChoiceChip(
            avatar: Icon(
              Icons.event_outlined,
              size: 16,
              color: custom ? AppColors.credit : AppColors.muted,
            ),
            // A custom window names itself on the chip; otherwise it invites.
            label: Text(custom ? period.label : 'Pick dates'),
            selected: custom,
            onSelected: (_) => _pickCustom(context, ref),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustom(BuildContext context, WidgetRef ref) async {
    final mode = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.today_outlined),
              title: const Text('A single day'),
              onTap: () => Navigator.pop(sheetContext, 'day'),
            ),
            ListTile(
              leading: const Icon(Icons.date_range_outlined),
              title: const Text('A range of days'),
              onTap: () => Navigator.pop(sheetContext, 'range'),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
    if (mode == null || !context.mounted) return;

    // No transaction is dated in the future, so today caps every picker.
    final today = ref.read(todayProvider);
    final first = DateTime(2020);

    if (mode == 'day') {
      final day = await showDatePicker(
        context: context,
        initialDate: today,
        firstDate: first,
        lastDate: today,
      );
      if (day != null) ref.read(selectedPeriodProvider.notifier).chooseDay(day);
    } else {
      final range = await showDateRangePicker(
        context: context,
        firstDate: first,
        lastDate: today,
      );
      if (range != null) {
        ref
            .read(selectedPeriodProvider.notifier)
            .chooseRange(range.start, range.end);
      }
    }
  }
}

/// The signature.
///
/// Every money app can show a balance. This one knows what SHOULD have been
/// recorded — CBE texts on every movement — so it can say whether the day is
/// actually complete. That question ("did anything slip through?") is the
/// reason the app exists, so it sits directly under the number it qualifies.
class _ReconciliationStrip extends ConsumerWidget {
  const _ReconciliationStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The green tick is an affirmative claim — "the cross-check ran and found
    // nothing". It must never show when the check can't run (iOS, permission
    // skipped) or hasn't answered yet (stream still loading / errored): a
    // false all-clear here is the app lying about the one thing it exists for.
    if (!ref.watch(smsCrossCheckActiveProvider)) {
      return Material(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              const Icon(Icons.sms_outlined, size: 16, color: AppColors.muted),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'SMS cross-check is off — tracking screenshots only',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final count = ref.watch(unmatchedSmsCountProvider);
    if (!count.hasValue) return const SizedBox.shrink();
    final waiting = count.value ?? 0;
    final settled = waiting == 0;

    return Material(
      color: settled ? AppColors.creditWash : AppColors.pendingWash,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        // Nothing to resolve → nothing to tap.
        onTap: settled ? null : () => context.go('/reconcile'),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(
                settled ? Icons.check_circle : Icons.error_outline,
                size: 16,
                color: settled ? AppColors.credit : AppColors.pending,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  settled
                      ? 'Every CBE message today has a screenshot'
                      : waiting == 1
                      ? '1 payment texted today has no screenshot'
                      : '$waiting payments texted today have no screenshot',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: settled ? AppColors.credit : AppColors.pending,
                  ),
                ),
              ),
              if (!settled)
                Icon(
                  Icons.arrow_forward,
                  size: 14,
                  color: AppColors.pending,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Branches as one grouped list, not a stack of cards — they're rows in a
/// ledger, and a shared edge lets the eye run down the balance column.
class _BranchList extends StatelessWidget {
  const _BranchList({required this.branches});

  final List<Branch> branches;

  @override
  Widget build(BuildContext context) {
    if (branches.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Column(
        children: [
          for (var i = 0; i < branches.length; i++) ...[
            if (i > 0) const Divider(indent: AppSpacing.lg),
            _BranchRow(branch: branches[i]),
          ],
        ],
      ),
    );
  }
}

class _BranchRow extends ConsumerWidget {
  const _BranchRow({required this.branch});

  final Branch branch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(activePeriodProvider);
    final amount = ref.watch(branchPeriodDeltaProvider(branch.id));
    final count = ref.watch(branchPeriodCountProvider(branch.id)).value ?? 0;
    final cents = amount.value;

    return InkWell(
      onTap: () => context.push('/branch/${branch.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    branch.name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    count == 0
                        ? 'No activity'
                        : count == 1
                        ? '1 transaction'
                        : '$count transactions',
                    style: TextStyle(
                      fontSize: 12,
                      // A branch that moved in this window is worth noticing.
                      color: count == 0 ? AppColors.muted : AppColors.credit,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              cents == null
                  ? '—'
                  : period.isMovement
                  ? formatSignedCents(cents)
                  : formatCents(cents),
              style: AppTextStyles.moneyRow.copyWith(
                color: periodAmountColor(period, cents ?? 0),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.muted,
            ),
          ],
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
    backgroundColor: AppColors.card,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Single screenshot'),
            subtitle: const Text('Read one CBE receipt'),
            onTap: () {
              Navigator.pop(sheetContext);
              context.push('/add-single');
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Bulk upload'),
            subtitle: const Text('Up to 50 at once'),
            onTap: () {
              Navigator.pop(sheetContext);
              context.push('/add-bulk');
            },
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}
