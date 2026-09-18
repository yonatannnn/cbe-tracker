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
import '../shared/branch_chips.dart';
import '../shared/manual_entry_fields.dart';

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

  /// The already-recorded transaction a blocked save collided with (§FR-2).
  ///
  /// The id is what "View existing" opens. Both fields are null only when the
  /// row vanished between the insert and the lookup — she still has to be told
  /// it's a duplicate, which matters more than being able to open it.
  ({int? id, String? date})? _duplicate;

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
      _duplicate = null;
    });
    final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (picked == null) {
      // Cancelled the picker — leave the flow entirely. Clearing _busy matters
      // for the case where there's nothing to pop back to: the screen would
      // otherwise sit on the spinner with no picker and no way forward.
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        setState(() => _busy = false);
      }
      return;
    }
    final file = File(picked.path);
    setState(() => _image = file);

    // ML Kit throws on a format it can't decode, and on a fresh phone that has
    // never had network it throws because the model isn't downloaded yet — a
    // real first-run in Ethiopia. Unguarded, that left "Reading screenshot…"
    // spinning forever with no retry and no explanation. Treat any failure as
    // unreadable, which is the state that already offers "Try another image"
    // and "Enter manually".
    ParseOutcome outcome;
    try {
      outcome = await ref.read(parsePipelineProvider).parse(file);
    } on Object {
      outcome = const ParseUnreadable('');
    }
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

    // image_picker's file lives in the cache, which Android deletes at will.
    // Copy it somewhere durable before the row points at it (§2).
    final image = _image;
    final storedPath = image == null
        ? null
        : await ref.read(imageStoreProvider).save(image);
    if (!mounted) return;

    final result = await dao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: branchId,
        amountCents: entry.cents,
        type: entry.type,
        reference: entry.reference,
        source: TxSource.screenshot,
        transactionDate: parsed?.date ?? DateTime.now(),
        screenshotPath: Value(storedPath),
        ocrText: Value(parsed?.rawText ?? _rawText()),
      ),
    );

    if (result == InsertResult.duplicate) {
      // The image was copied to durable storage before the insert, and a
      // blocked save means no row will ever point at it. Deleted before the
      // mounted check on purpose: whether she happened to leave the screen
      // must not decide whether ~100KB leaks into every backup from here on.
      await ref.read(imageStoreProvider).delete(storedPath);
      // §FR-2: block the save and say when it was first recorded.
      final existing = await dao.findByReference(entry.reference);
      if (!mounted) return;
      setState(
        () => _duplicate = (
          id: existing?.id,
          date: existing == null ? null : _formatDate(existing.transactionDate),
        ),
      );
      return;
    }

    if (!mounted) return;

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
    // The picker's cache copy served its purpose — the durable copy is in the
    // documents dir and the row points there. Left behind, every add grew the
    // app's cache by ~100KB forever. Best-effort; only after a committed save,
    // since a blocked duplicate still shows this file on screen.
    if (image != null) {
      try {
        await image.delete();
      } on FileSystemException {
        // Android may have purged it already.
      }
    }
    if (!mounted) return;
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
      body: SafeArea(
        child: _busy
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
      ),
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
        if (_duplicate != null)
          _DuplicateNotice(duplicate: _duplicate!)
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
                  switch (_outcome) {
                    ParseUnreadable(:final aiFailure) => unreadableMessage(
                      aiFailure,
                    ),
                    _ => "Couldn't read this screenshot",
                  },
                  textAlign: TextAlign.center,
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
          if (_duplicate != null)
            _DuplicateNotice(duplicate: _duplicate!)
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
    final color = isCredit ? AppColors.credit : theme.colorScheme.error;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parsed.confidence != Confidence.high)
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.pendingWash,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 14, color: AppColors.pending),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Read with AI — please check the amount',
              style: TextStyle(color: AppColors.pending, fontSize: 12),
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
  const _DuplicateNotice({required this.duplicate});

  final ({int? id, String? date}) duplicate;

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
                  duplicate.date == null
                      ? 'Already recorded'
                      : 'Already recorded on ${duplicate.date}',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
        ),
        // No id means the row it collided with couldn't be read back, so there
        // is nothing to open — the notice stands on its own rather than
        // offering a button that would go nowhere.
        if (duplicate.id case final id?) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => context.push('/transaction/$id'),
            child: const Text('View existing'),
          ),
        ],
      ],
    );
  }
}
