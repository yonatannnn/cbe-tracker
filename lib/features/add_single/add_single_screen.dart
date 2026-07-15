/// Single-screenshot add flow (§8 Phase 4, FR-2).
///
/// Automation first: the user picks a branch and confirms. OCR fills the rest.
/// Manual editing exists only as a fallback for unreadable images.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/theme.dart';
import '../../core/ids.dart';
import '../../core/money/etb_format.dart';
import '../../core/parser/cbe_parser.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../data/db/tables.dart';
import '../../services/parse_pipeline.dart';
import '../../services/service_providers.dart';
import '../reconcile/reconcile_providers.dart';
import '../shared/branch_chips.dart';
import '../shared/manual_entry_fields.dart';

/// Add tab (§8 Phase 4, FR-2). Placeholder for Phase 0.
class AddScreen extends StatelessWidget {
  const AddScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add')),
      body: const Center(child: Text('Add')),
    );
  }
}

/// Picks a screenshot, runs the parse pipeline, and confirms the result.
class AddSingleScreen extends ConsumerStatefulWidget {
  const AddSingleScreen({super.key});

  @override
  ConsumerState<AddSingleScreen> createState() => _AddSingleScreenState();
}

class _AddSingleScreenState extends ConsumerState<AddSingleScreen> {
  File? _image;
  ParseOutcome? _outcome;
  bool _busy = true;
  int? _selectedBranchId;
  bool _manualOpen = false;
  String? _duplicateDate;

  // Manual-edit values, pre-filled from the parse when there is one.
  int? _manualCents;
  TxType _manualType = TxType.credit;
  String _manualReference = '';
  String? _amountError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pick());
  }

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _outcome = null;
      _duplicateDate = null;
    });
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) {
      // Cancelled the picker — leave the flow entirely.
      if (mounted && context.canPop()) context.pop();
      return;
    }
    final file = File(picked.path);
    setState(() => _image = file);

    final outcome = await ref.read(parsePipelineProvider).parse(file);
    if (!mounted) return;
    setState(() {
      _outcome = outcome;
      _busy = false;
      if (outcome is ParseSuccess) _prefillFrom(outcome.parsed);
    });
  }

  void _prefillFrom(ParsedCbeMessage parsed) {
    _manualCents = parsed.amountCents;
    _manualReference = parsed.reference ?? '';
    _manualType = parsed.type;
  }

  /// Amount/type/reference to save: the manual fields when the user opened the
  /// editor, otherwise exactly what was parsed.
  ({int cents, TxType type, String reference})? _resolveEntry() {
    final outcome = _outcome;
    final parsed = outcome is ParseSuccess ? outcome.parsed : null;

    if (!_manualOpen && parsed != null) {
      return (
        cents: parsed.amountCents,
        type: parsed.type,
        // aiParsed results can have an unreadable reference.
        reference: parsed.reference ?? manualReference(),
      );
    }

    final cents = _manualCents;
    if (cents == null || cents == 0) {
      setState(() => _amountError = 'Enter an amount like 5,000.00');
      return null;
    }
    final typed = _manualReference.trim();
    return (
      cents: cents,
      type: _manualType,
      reference: typed.isEmpty ? manualReference() : typed,
    );
  }

  Future<void> _confirm() async {
    final branchId = _selectedBranchId;
    if (branchId == null) return;
    final entry = _resolveEntry();
    if (entry == null) return;

    setState(() => _amountError = null);
    final outcome = _outcome;
    final parsed = outcome is ParseSuccess ? outcome.parsed : null;
    final dao = ref.read(transactionDaoProvider);

    final result = await dao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: branchId,
        amountCents: entry.cents,
        type: entry.type,
        reference: entry.reference,
        source: TxSource.screenshot,
        transactionDate: parsed?.date ?? DateTime.now(),
        screenshotPath: Value(_image?.path),
        ocrText: Value(parsed?.rawText ?? _rawText()),
      ),
    );

    if (!mounted) return;

    if (result == InsertResult.duplicate) {
      // §FR-2: block the save and say when it was first recorded.
      final existing = await dao.findByReference(entry.reference);
      if (!mounted) return;
      setState(
        () => _duplicateDate = existing == null
            ? null
            : _formatDate(existing.transactionDate),
      );
      return;
    }

    await ref.read(settingsDaoProvider).setLastBranchId(branchId);
    if (!mounted) return;

    final branches = ref.read(activeBranchesProvider).value ?? const <Branch>[];
    final name = branches
        .firstWhere(
          (b) => b.id == branchId,
          orElse: () => Branch(
            id: branchId,
            name: 'branch',
            archived: false,
            createdAt: DateTime.now(),
          ),
        )
        .name;

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Saved to $name')));
    if (context.canPop()) context.pop();
  }

  String _rawText() {
    final outcome = _outcome;
    return switch (outcome) {
      ParseSuccess(:final parsed) => parsed.rawText,
      ParseUnreadable(:final rawText) => rawText,
      _ => '',
    };
  }

  static String _formatDate(DateTime date) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year} '
        'at ${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Single screenshot')),
      body: _busy
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('Reading screenshot…'),
                ],
              ),
            )
          : switch (_outcome) {
              ParseSuccess(:final parsed) => _buildSuccess(parsed),
              ParseUnreadable() => _buildUnreadable(),
              _ => const SizedBox.shrink(),
            },
    );
  }

  // ── SUCCESS ──────────────────────────────────────────────────────────────

  Widget _buildSuccess(ParsedCbeMessage parsed) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SummaryCard(parsed: parsed, image: _image),
        const SizedBox(height: 16),
        Text('Branch', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        BranchChips(
          selectedId: _selectedBranchId,
          onSelected: (id) => setState(() => _selectedBranchId = id),
          onDefaultResolved: (id) {
            if (_selectedBranchId == null) {
              setState(() => _selectedBranchId = id);
            }
          },
        ),
        const SizedBox(height: 16),
        if (_manualOpen) _buildManualFields(),
        if (_duplicateDate != null)
          _DuplicateNotice(date: _duplicateDate!)
        else ...[
          FilledButton(
            onPressed: _selectedBranchId == null ? null : _confirm,
            child: const Text('Confirm'),
          ),
          Align(
            child: TextButton(
              onPressed: () => setState(() => _manualOpen = !_manualOpen),
              child: Text(_manualOpen ? 'Hide manual edit' : 'Edit manually'),
            ),
          ),
        ],
      ],
    );
  }

  // ── UNREADABLE ───────────────────────────────────────────────────────────

  Widget _buildUnreadable() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Icon(
                  Icons.image_not_supported_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 12),
                Text(
                  "Couldn't read this screenshot",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (_image != null) _Thumbnail(image: _image!, size: 160),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Nothing is ever auto-saved from this state (§FR-2).
        if (!_manualOpen) ...[
          FilledButton(
            onPressed: _pick,
            child: const Text('Try another image'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => setState(() => _manualOpen = true),
            child: const Text('Enter manually'),
          ),
        ] else ...[
          Text('Branch', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          BranchChips(
            selectedId: _selectedBranchId,
            onSelected: (id) => setState(() => _selectedBranchId = id),
            onDefaultResolved: (id) {
              if (_selectedBranchId == null) {
                setState(() => _selectedBranchId = id);
              }
            },
          ),
          const SizedBox(height: 16),
          _buildManualFields(),
          if (_duplicateDate != null)
            _DuplicateNotice(date: _duplicateDate!)
          else
            FilledButton(
              onPressed: _selectedBranchId == null ? null : _confirm,
              child: const Text('Save'),
            ),
        ],
      ],
    );
  }

  // ── Manual fields ────────────────────────────────────────────────────────

  Widget _buildManualFields() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: ManualEntryFields(
        initialCents: _manualCents,
        initialType: _manualType,
        initialReference: _manualReference,
        amountError: _amountError,
        onAmountChanged: (cents) => setState(() {
          _manualCents = cents;
          _amountError = null;
        }),
        onTypeChanged: (type) => _manualType = type,
        onReferenceChanged: (ref) => _manualReference = ref,
      ),
    );
  }
}

/// Read-only parsed summary: thumbnail, signed amount, badge, mono reference.
class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.parsed, required this.image});

  final ParsedCbeMessage parsed;
  final File? image;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isCredit = parsed.type == TxType.credit;
    final signed = isCredit ? parsed.amountCents : -parsed.amountCents;
    final color = isCredit ? const Color(0xFF1B7A43) : theme.colorScheme.error;
    final smsVerified = ref.watch(smsVerifiedProvider(parsed.reference));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parsed.confidence == Confidence.aiParsed)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: _AiBadge(),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (image != null) ...[
                  _Thumbnail(image: image!, size: 72),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatSignedCents(signed),
                        style: AppTextStyles.money.copyWith(color: color),
                      ),
                      const SizedBox(height: 6),
                      _TypeBadge(isCredit: isCredit),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              parsed.reference ?? 'No reference read',
              style: AppTextStyles.mono.copyWith(
                color: parsed.reference == null
                    ? theme.colorScheme.outline
                    : theme.colorScheme.onSurface,
              ),
            ),
            if (parsed.date != null) ...[
              const SizedBox(height: 4),
              Text(
                _AddSingleScreenState._formatDate(parsed.date!),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            // Hidden until Phase 6 provides real SMS verification.
            if (smsVerified != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    smsVerified ? Icons.verified : Icons.help_outline,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    smsVerified ? 'Verified against SMS' : 'No matching SMS',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ],
          ],
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3D6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 14, color: amber),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Read with AI — please check the amount',
              style: TextStyle(color: amber, fontSize: 12),
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
    final bg = isCredit ? scheme.primaryContainer : scheme.errorContainer;
    final fg = isCredit ? scheme.onPrimaryContainer : scheme.onErrorContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        isCredit ? 'CREDIT' : 'DEBIT',
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.image, required this.size});

  final File image;
  final double size;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        image,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // cacheWidth keeps list/thumbnail decoding cheap (§2).
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        errorBuilder: (context, _, _) => Container(
          width: size,
          height: size,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: const Icon(Icons.broken_image_outlined),
        ),
      ),
    );
  }
}

/// Replaces the confirm button when the reference is already recorded.
class _DuplicateNotice extends StatelessWidget {
  const _DuplicateNotice({required this.date});

  final String date;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Icon(Icons.block, color: scheme.onErrorContainer, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Already recorded on $date',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          // Real transaction detail arrives in Phase 7.
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Transaction detail arrives in Phase 7'),
            ),
          ),
          child: const Text('View existing'),
        ),
      ],
    );
  }
}
