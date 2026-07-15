/// Bulk review modal — three row states plus an atomic save (§7, FR-3).
library;


import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../data/db/tables.dart';
import '../../services/bulk_processor.dart';
import '../shared/manual_entry_fields.dart';
import 'bulk_review_state.dart';

/// Shows the review sheet. Returns the number saved, or null if discarded.
Future<int?> showBulkReviewModal({
  required BuildContext context,
  required List<BulkItem> items,
  required int branchId,
  required String branchName,
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
    ),
  );
}

class BulkReviewModal extends ConsumerStatefulWidget {
  const BulkReviewModal({
    super.key,
    required this.items,
    required this.branchId,
    required this.branchName,
  });

  final List<BulkItem> items;
  final int branchId;
  final String branchName;

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
    final entries = [
      for (final row in rows)
        TransactionsCompanion.insert(
          branchId: widget.branchId,
          amountCents: row.effectiveCents!,
          type: row.effectiveType!,
          reference: row.effectiveReference(),
          source: TxSource.screenshot,
          transactionDate: row.item.parsed?.date ?? DateTime.now(),
          screenshotPath: Value(row.item.image.path),
          ocrText: Value(row.item.parsed?.rawText ?? row.item.rawText),
        ),
    ];

    try {
      // All-or-nothing (Phase 2). Duplicates were filtered into their own
      // rows, so one reaching here means the same reference was saved
      // elsewhere mid-review — a real error, and the whole batch rolls back.
      await ref.read(transactionDaoProvider).insertManyAtomic(entries);
      await ref.read(settingsDaoProvider).setLastBranchId(widget.branchId);
      if (!mounted) return;
      Navigator.pop(context, rows.length);
    } on Object {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error =
            'Nothing was saved — one of these was recorded somewhere else '
            'in the meantime. Nothing was half-applied; try again.';
      });
    }
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
                          widget.branchName,
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
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _state.rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) => _ReviewRowTile(
                  row: _state.rows[i],
                  onToggle: (checked) =>
                      setState(() => _state = _state.toggle(i, checked: checked)),
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
    required this.row,
    required this.onToggle,
    required this.onExpand,
    required this.onAmount,
    required this.onType,
    required this.onReference,
  });

  final ReviewRow row;
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
                              ? const Color(0xFF1B7A43)
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
                    row.item.parsed?.reference ?? 'No reference',
                    style: AppTextStyles.mono.copyWith(
                      fontSize: 12,
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
    return Opacity(
      opacity: 0.55,
      child: Row(
        children: [
          // No checkbox at all — a duplicate can never be saved.
          const SizedBox(width: 48),
          Icon(Icons.block, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    existing == null
                        ? 'Already recorded'
                        : 'Already recorded on '
                              '${_formatDate(existing.transactionDate)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    row.item.parsed?.reference ?? '',
                    style: AppTextStyles.mono.copyWith(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
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
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.file(
                row.item.image,
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
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Couldn't read",
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
    const amber = Color(0xFF8A5A00);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3D6),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 10, color: amber),
          SizedBox(width: 3),
          Text(
            'AI',
            style: TextStyle(
              color: amber,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
