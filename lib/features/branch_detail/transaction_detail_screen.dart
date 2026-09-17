/// Transaction detail: full screenshot, parsed fields, raw OCR, edit, delete
/// (§FR-7).
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../services/service_providers.dart';
import '../shared/manual_entry_fields.dart';
import 'branch_detail_providers.dart';

class TransactionDetailScreen extends ConsumerWidget {
  const TransactionDetailScreen({super.key, required this.transactionId});

  final int transactionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = ref.watch(transactionByIdProvider(transactionId));

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction')),
      body: SafeArea(
        child: row.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(child: Text("Couldn't load: $error")),
          data: (found) => found == null
              ? const Center(child: Text('This transaction no longer exists.'))
              : _Body(row: found),
        ),
      ),
    );
  }
}

class _Body extends ConsumerStatefulWidget {
  const _Body({required this.row});

  final Transaction row;

  @override
  ConsumerState<_Body> createState() => _BodyState();
}

class _BodyState extends ConsumerState<_Body> {
  bool _editing = false;
  bool _showOcr = false;

  // Edit buffer, seeded from the stored values.
  late int? _cents = widget.row.amountCents;
  late TxType _type = widget.row.type;
  late String _reference = widget.row.reference;
  late int _branchId = widget.row.branchId;
  String? _error;

  Transaction get _tx => widget.row;

  /// Throws away an abandoned edit.
  ///
  /// The buffer fields are `late` initialisers, so they seed once and never
  /// again. Without this, cancelling kept the typed-but-rejected values: the
  /// header would show the stored 5,000.00 while re-opening Edit offered the
  /// abandoned 50,000.00, and Save would commit it as real money.
  void _resetBuffer() {
    _cents = _tx.amountCents;
    _type = _tx.type;
    _reference = _tx.reference;
    _branchId = _tx.branchId;
  }

  Future<void> _save() async {
    final cents = _cents;
    if (cents == null || cents == 0) {
      setState(() => _error = 'Enter an amount like 5,000.00');
      return;
    }
    final reference = _reference.trim();
    if (reference.isEmpty) {
      setState(() => _error = 'Reference cannot be empty');
      return;
    }

    try {
      await ref
          .read(transactionDaoProvider)
          .updateTransaction(
            _tx.id,
            TransactionsCompanion(
              amountCents: Value(cents),
              type: Value(_type),
              reference: Value(reference),
              branchId: Value(_branchId),
            ),
          );
    } on Object catch (error) {
      if (!mounted) return;
      // Only a UNIQUE violation means the reference is taken. Blaming the
      // reference for every failure (FK violation, disk full…) sends her to
      // "fix" a field that isn't broken.
      final text = '$error'.toUpperCase();
      setState(
        () => _error = text.contains('UNIQUE')
            ? 'Another transaction already uses that reference'
            : "Couldn't save the changes. Nothing was updated.",
      );
      return;
    }

    ref.read(transactionRevisionProvider.notifier).bump();
    if (!mounted) return;
    setState(() {
      _editing = false;
      _error = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this transaction?'),
        content: const Text(
          'The branch balance will be recalculated without it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false) || !mounted) return;

    await ref.read(transactionDaoProvider).deleteTransaction(_tx.id);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Transaction deleted')));
    if (context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branches =
        ref.watch(activeBranchesProvider).value ?? const <Branch>[];
    final isCredit = _tx.type == TxType.credit;
    final signed = isCredit ? _tx.amountCents : -_tx.amountCents;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_tx.screenshotPath != null && _tx.screenshotPath!.isNotEmpty)
          _FullScreenshot(path: _tx.screenshotPath!),
        const SizedBox(height: 16),

        Text(
          formatSignedCents(signed),
          style: AppTextStyles.money.copyWith(
            color: isCredit ? AppColors.credit : theme.colorScheme.error,
          ),
        ),
        const SizedBox(height: 12),

        _Field(label: 'Type', value: isCredit ? 'Credit' : 'Debit'),
        _Field(label: 'Reference', value: _tx.reference, mono: true),
        _Field(label: 'Date', value: _formatDateTime(_tx.transactionDate)),
        _Field(
          label: 'Branch',
          value:
              branches
                  .where((b) => b.id == _tx.branchId)
                  .map((b) => b.name)
                  .firstOrNull ??
              'Archived branch',
        ),
        _Field(label: 'Source', value: _tx.source.name),

        const Divider(height: 32),

        if (_tx.ocrText != null && _tx.ocrText!.isNotEmpty) ...[
          InkWell(
            onTap: () => setState(() => _showOcr = !_showOcr),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(_showOcr ? Icons.expand_less : Icons.expand_more),
                  const SizedBox(width: 6),
                  Text('Raw OCR text', style: theme.textTheme.titleSmall),
                ],
              ),
            ),
          ),
          if (_showOcr)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _tx.ocrText!,
                style: AppTextStyles.mono.copyWith(fontSize: 11),
              ),
            ),
          const SizedBox(height: 16),
        ],

        if (_editing) ...[
          ManualEntryFields(
            initialCents: _cents,
            initialType: _type,
            initialReference: _reference,
            amountError: _error,
            onAmountChanged: (cents) => setState(() {
              _cents = cents;
              _error = null;
            }),
            onTypeChanged: (type) => _type = type,
            onReferenceChanged: (reference) => _reference = reference,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _branchId,
            decoration: const InputDecoration(
              labelText: 'Branch',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final branch in branches)
                DropdownMenuItem(value: branch.id, child: Text(branch.name)),
              // A transaction can belong to a branch that was archived since.
              // The dropdown asserts that its value appears in items, so
              // without this entry, editing such a transaction crashes — and
              // silently reassigning it to some active branch would move money.
              if (!branches.any((b) => b.id == _branchId))
                DropdownMenuItem(
                  value: _branchId,
                  child: const Text('Archived branch'),
                ),
            ],
            // Changing this moves the transaction; both balances restream.
            onChanged: (id) => setState(() => _branchId = id ?? _branchId),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Save changes')),
          TextButton(
            onPressed: () => setState(() {
              _editing = false;
              _error = null;
              _resetBuffer();
            }),
            child: const Text('Cancel'),
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: () => setState(() => _editing = true),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _delete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
            style: TextButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  static String _formatDateTime(DateTime moment) =>
      '${_formatDate(moment)} at ${_formatTime(moment)}';

  static String _formatDate(DateTime moment) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(moment.day)}/${two(moment.month)}/${moment.year}';
  }

  static String _formatTime(DateTime moment) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(moment.hour)}:${two(moment.minute)}';
  }
}

class _FullScreenshot extends ConsumerWidget {
  const _FullScreenshot({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Relative to the documents dir (§2); resolved against wherever the app is
    // installed right now.
    final file = ref.watch(imageStoreProvider).resolve(path);
    if (file == null) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 420),
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (context, _, _) => Container(
              height: 160,
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Center(child: Text('Screenshot file is missing')),
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? AppTextStyles.mono.copyWith(fontSize: 13)
                  : theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
