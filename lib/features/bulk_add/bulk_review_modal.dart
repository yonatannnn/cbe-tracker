/// Bulk review modal — three row states plus an atomic save (§7, FR-3).
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/dates/day_format.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../data/db/tables.dart';
import '../../services/bulk_processor.dart';
import '../../services/parse_pipeline.dart' show unreadableMessage;
import '../../services/service_providers.dart';
import '../shared/manual_entry_fields.dart';
import 'bulk_review_state.dart';

/// Shows the approval sheet. Returns the number saved, or null if discarded.
///
/// [day] is the calendar day the batch is filed under (§FR-3: defaults to
/// today, changeable on the previous screen).
Future<int?> showBulkReviewModal({
  required BuildContext context,
  required List<BulkItem> items,
  required int branchId,
  required String branchName,
  required DateTime day,
}) {
  return showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    // Dismissal goes through our confirm dialog instead (§FR-3).
    isDismissible: false,
    enableDrag: false,
    builder: (_) => BulkReviewModal(
      items: items,
      branchId: branchId,
      branchName: branchName,
      day: day,
    ),
  );
}

class BulkReviewModal extends ConsumerStatefulWidget {
  const BulkReviewModal({
    super.key,
    required this.items,
    required this.branchId,
    required this.branchName,
    required this.day,
  });

  final List<BulkItem> items;
  final int branchId;
  final String branchName;

  /// The day every approved row is dated — see [transactionDateFor].
  final DateTime day;

  @override
  ConsumerState<BulkReviewModal> createState() => _BulkReviewModalState();
}

class _BulkReviewModalState extends ConsumerState<BulkReviewModal> {
  late ReviewState _state = ReviewState.initial(widget.items);
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (!_state.canSave || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final rows = _state.checkedRows;
    final store = ref.read(imageStoreProvider);

    final entries = <TransactionsCompanion>[];
    try {
      // Copy every picked image out of the cache before any row points at it
      // (§2) — image_picker hands back a path Android may delete at any time.
      for (final row in rows) {
        final storedPath = await store.save(row.item.image);
        entries.add(
          TransactionsCompanion.insert(
            branchId: widget.branchId,
            amountCents: row.effectiveCents!,
            type: row.effectiveType!,
            reference: row.effectiveReference(),
            source: TxSource.screenshot,
            transactionDate: transactionDateFor(
              day: widget.day,
              parsed: row.item.parsed?.date,
              now: DateTime.now(),
            ),
            screenshotPath: Value(storedPath),
            ocrText: Value(row.item.parsed?.rawText ?? row.item.rawText),
          ),
        );
      }
    } on Object {
      // ImageStore.save only swallows FileSystemException; anything else used
      // to escape this method entirely, leaving _saving stuck true — a spinner
      // that never stops and a Save button that never comes back.
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            "One of the pictures couldn't be opened, so nothing was saved. "
            'Please try again.';
      });
      return;
    }
    if (!mounted) return;

    try {
      // All-or-nothing (Phase 2). Duplicates were filtered into their own
      // rows, so one reaching here means the same reference was saved
      // elsewhere mid-review — a real error, and the whole batch rolls back.
      await ref.read(transactionDaoProvider).insertManyAtomic(entries);
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            'Nothing was saved: one of these receipts is already in the '
            'books. Close this and read the screenshots again so the app can '
            'mark it for you.';
      });
      return;
    }

    // Past this line the batch is committed, so nothing below may report
    // "nothing was saved" — that sentence on top of ten saved transactions
    // would send her to save them again, and every reference would then collide
    // as a duplicate, trapping her in a modal insisting nothing had saved.
    try {
      await ref.read(settingsDaoProvider).setLastBranchId(widget.branchId);
    } on Object {
      // Non-fatal: the money is recorded. Remembering the branch is a
      // convenience.
    }
    // The saved rows' picker cache copies are dead weight now — the durable
    // copies are in the documents dir. Only after the commit: a failed save
    // returns to this modal and retries from these very files.
    for (final row in rows) {
      try {
        await row.item.image.delete();
      } on FileSystemException {
        // Cache files are Android's to purge anyway.
      }
    }
    if (!mounted) return;
    Navigator.pop(context, rows.length);
  }

  Future<void> _confirmDiscard() async {
    final count = _state.checkedCount;
    if (count == 0) {
      Navigator.pop(context);
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          'Discard $count unsaved ${count == 1 ? 'transaction' : 'transactions'}?',
        ),
        content: const Text('The screenshots will not be recorded.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep reviewing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if ((discard ?? false) && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // For "already saved before": name the branch it went into, which may
    // not be this one.
    final branches = ref.watch(activeBranchesProvider).value ?? const [];
    String? branchNameOf(int id) {
      for (final b in branches) {
        if (b.id == id) return b.name;
      }
      return null;
    }

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Review ${widget.items.length} '
                          '${widget.items.length == 1 ? 'screenshot' : 'screenshots'}',
                          style: theme.textTheme.titleLarge,
                        ),
                        Text(
                          '${widget.branchName} · ${formatDay(widget.day)}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Discard',
                    onPressed: _confirmDiscard,
                  ),
                ],
              ),
            ),
            _ReadSummary(state: _state, total: widget.items.length),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _state.rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _ReviewRowTile(
                  number: i + 1,
                  row: _state.rows[i],
                  branchNameOf: branchNameOf,
                  onToggle: (checked) => setState(
                    () => _state = _state.toggle(i, checked: checked),
                  ),
                  onExpand: (expanded) => setState(
                    () => _state = _state.setExpanded(i, expanded: expanded),
                  ),
                  onAmount: (cents) =>
                      setState(() => _state = _state.editAmount(i, cents)),
                  onType: (type) =>
                      setState(() => _state = _state.editType(i, type)),
                  onReference: (ref) =>
                      setState(() => _state = _state.editReference(i, ref)),
                ),
              ),
            ),
            const Divider(height: 1),
            _SumPanel(state: _state),
            if (_state.conflictingReference != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Two selected rows have the same reference '
                  '${_state.conflictingReference}. Untick one of them to '
                  'continue.',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _state.canSave && !_saving ? _save : null,
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        // Live count (§FR-3).
                        : Text(_state.saveLabel),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReviewRowTile extends StatelessWidget {
  const _ReviewRowTile({
    required this.number,
    required this.row,
    required this.branchNameOf,
    required this.onToggle,
    required this.onExpand,
    required this.onAmount,
    required this.onType,
    required this.onReference,
  });

  /// 1-based position in the batch — what "same as screenshot 3" refers to.
  final int number;
  final ReviewRow row;
  final String? Function(int branchId) branchNameOf;
  final ValueChanged<bool> onToggle;
  final ValueChanged<bool> onExpand;
  final ValueChanged<int?> onAmount;
  final ValueChanged<TxType> onType;
  final ValueChanged<String> onReference;

  @override
  Widget build(BuildContext context) {
    return switch (row.status) {
      BulkStatus.duplicate => _buildDuplicate(context),
      BulkStatus.failed => _buildFailed(context),
      _ => _buildParsed(context),
    };
  }

  // ok + okAiParsed
  Widget _buildParsed(BuildContext context) {
    final theme = Theme.of(context);
    final isAi = row.status == BulkStatus.okAiParsed;
    final cents = row.effectiveCents ?? 0;
    final type = row.effectiveType ?? TxType.credit;
    final isCredit = type == TxType.credit;
    final signed = isCredit ? cents : -cents;

    return Column(
      children: [
        Row(
          children: [
            Checkbox(
              value: row.checked,
              onChanged: (v) => onToggle(v ?? false),
            ),
            // An AI reading is checked against the picture, so show it.
            if (isAi) ...[
              _Thumb(image: row.item.image),
              const SizedBox(width: 10),
            ],
            Expanded(
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
                              ? AppColors.credit
                              : theme.colorScheme.error,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _TypeBadge(isCredit: isCredit),
                      if (isAi) ...[const SizedBox(width: 6), const _AiBadge()],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '#$number · ${row.item.parsed?.reference ?? 'No reference'}',
                    style: AppTextStyles.mono.copyWith(
                      fontSize: 12,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  if (_origin(row.item.parsed) case final origin?)
                    Text(
                      origin,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                ],
              ),
            ),
            // Edit only on low-confidence rows (§FR-3) — a clean parse is
            // read-only.
            if (row.isEditable)
              IconButton(
                icon: Icon(row.expanded ? Icons.expand_less : Icons.edit),
                tooltip: 'Edit',
                onPressed: () => onExpand(!row.expanded),
              )
            else
              const SizedBox(width: 48),
          ],
        ),
        if (row.expanded) _buildEditor(context),
      ],
    );
  }

  Widget _buildDuplicate(BuildContext context) {
    final theme = Theme.of(context);
    final existing = row.item.existing;
    final earlier = row.item.duplicateOf;
    final cents = row.item.parsed?.amountCents ?? 0;
    final isCredit = row.item.parsed?.type == TxType.credit;

    final String reason;
    if (existing != null) {
      final branch = branchNameOf(existing.branchId);
      reason =
          'Already saved before — '
          '${branch == null ? '' : '$branch, '}'
          '${_formatDate(existing.transactionDate)}';
    } else if (earlier != null) {
      reason = 'Same receipt as screenshot #$earlier';
    } else {
      reason = 'Already saved before';
    }

    return Container(
      color: AppColors.pendingWash.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          // No checkbox at all — a duplicate can never be saved.
          const SizedBox(width: 48),
          _Thumb(image: row.item.image),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      formatSignedCents(isCredit ? cents : -cents),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.outline,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    const _NotSavedBadge(),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.pending,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  '#$number · ${row.item.parsed?.reference ?? ''}',
                  style: AppTextStyles.mono.copyWith(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  Widget _buildFailed(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Row(
          children: [
            SizedBox(
              width: 48,
              child: row.checked
                  ? Checkbox(
                      value: row.checked,
                      onChanged: (v) => onToggle(v ?? false),
                    )
                  : const SizedBox.shrink(),
            ),
            _Thumb(image: row.item.image),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '#$number · ${unreadableMessage(row.item.aiFailure)}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            if (!row.expanded)
              TextButton(
                onPressed: () => onExpand(true),
                child: const Text('Add manually'),
              )
            else
              IconButton(
                icon: const Icon(Icons.expand_less),
                onPressed: () => onExpand(false),
              ),
          ],
        ),
        if (row.expanded) _buildEditor(context),
      ],
    );
  }

  Widget _buildEditor(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 4, 16, 16),
      child: ManualEntryFields(
        dense: true,
        initialCents: row.effectiveCents,
        initialType: row.effectiveType ?? TxType.credit,
        initialReference: row.item.parsed?.reference ?? '',
        onAmountChanged: onAmount,
        onTypeChanged: onType,
        onReferenceChanged: onReference,
      ),
    );
  }

  /// "Awash Bank · from ESRAEL TOLOSA TOLA" — only the AI path knows these.
  static String? _origin(ParsedCbeMessage? parsed) {
    if (parsed == null) return null;
    final who = parsed.counterparty;
    final parts = <String>[
      ?parsed.bank,
      if (who != null) '${parsed.type == TxType.credit ? 'from' : 'to'} $who',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _formatDate(DateTime date) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} '
        'at ${two(date.hour)}:${two(date.minute)}';
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

class _AiBadge extends StatelessWidget {
  const _AiBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.pendingWash,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 10, color: AppColors.pending),
          SizedBox(width: 3),
          Text(
            'AI',
            style: TextStyle(
              color: AppColors.pending,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// "5 of 7 read correctly · 1 already recorded · 1 unreadable" — the first
/// thing she checks before looking at any row.
class _ReadSummary extends StatelessWidget {
  const _ReadSummary({required this.state, required this.total});

  final ReviewState state;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final read = state.readCount;
    final allRead = read == total;
    final parts = <String>[
      '$read of $total read correctly',
      if (state.duplicateCount > 0)
        '${state.duplicateCount} '
            '${state.duplicateCount == 1 ? 'duplicate' : 'duplicates'} '
            'not saved',
      if (state.failedCount > 0) '${state.failedCount} unreadable',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          Icon(
            allRead ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: allRead ? AppColors.credit : AppColors.pending,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              parts.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: allRead ? AppColors.credit : AppColors.pending,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What approving adds up to: money in, money out, and the net change to the
/// branch. Follows the checkboxes live, so unticking a row is visible in the
/// total before she approves.
class _SumPanel extends StatelessWidget {
  const _SumPanel({required this.state});

  final ReviewState state;

  @override
  Widget build(BuildContext context) {
    final net = state.netCents;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _SumCell(
                  label: 'IN',
                  value: formatCents(state.creditCents),
                  color: AppColors.credit,
                ),
              ),
              Expanded(
                child: _SumCell(
                  label: 'OUT',
                  value: formatCents(state.debitCents),
                  color: AppColors.debit,
                ),
              ),
              Expanded(
                child: _SumCell(
                  label: 'NET',
                  value: formatSignedCents(net),
                  color: net < 0 ? AppColors.debit : AppColors.credit,
                  alignEnd: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            state.checkedCount == 0
                ? 'Nothing selected'
                : 'Sum of the ${state.checkedCount} selected',
            style: AppTextStyles.label.copyWith(
              letterSpacing: 0,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

class _SumCell extends StatelessWidget {
  const _SumCell({
    required this.label,
    required this.value,
    required this.color,
    this.alignEnd = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.label),
        const SizedBox(height: 2),
        Text(value, style: AppTextStyles.moneyRow.copyWith(color: color)),
      ],
    );
  }
}

/// Small evidence thumbnail for rows she may need to recognise by eye.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.image});

  final File image;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.file(
        image,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        cacheWidth: 120,
        errorBuilder: (context, _, _) => Container(
          width: 40,
          height: 40,
          color: theme.colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined, size: 18),
        ),
      ),
    );
  }
}

class _NotSavedBadge extends StatelessWidget {
  const _NotSavedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.pendingWash,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'DUPLICATE · NOT SAVED',
        style: TextStyle(
          color: AppColors.pending,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
