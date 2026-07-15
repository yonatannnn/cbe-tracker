/// Bulk upload flow: branch → images → sequential OCR → review (§8 Phase 5,
/// FR-3).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../services/bulk_processor.dart';
import '../../services/service_providers.dart';
import '../shared/branch_chips.dart';
import 'bulk_review_modal.dart';

/// Which step of the flow we're on.
enum _Step { pickBranch, pickImages, processing }

class BulkAddScreen extends ConsumerStatefulWidget {
  const BulkAddScreen({super.key});

  @override
  ConsumerState<BulkAddScreen> createState() => _BulkAddScreenState();
}

class _BulkAddScreenState extends ConsumerState<BulkAddScreen> {
  _Step _step = _Step.pickBranch;
  int? _branchId;
  final _images = <File>[];
  BulkProgress? _progress;

  Future<void> _addImages() async {
    final picked = await ImagePicker().pickMultiImage();
    if (picked.isEmpty || !mounted) return;

    final room = BulkProcessor.maxImages - _images.length;
    final accepted = picked.take(room).toList();
    final dropped = picked.length - accepted.length;

    setState(() => _images.addAll(accepted.map((x) => File(x.path))));

    if (dropped > 0) {
      // §FR-3: keep the first 10, say what happened.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Only ${BulkProcessor.maxImages} images at a time — '
            '$dropped not added',
          ),
        ),
      );
    }
  }

  Future<void> _start() async {
    final branchId = _branchId;
    if (branchId == null || _images.isEmpty) return;
    setState(() {
      _step = _Step.processing;
      _progress = null;
    });

    final processor = BulkProcessor(
      pipeline: ref.read(parsePipelineProvider),
      dao: ref.read(transactionDaoProvider),
    );

    BulkProgress? last;
    await for (final progress in processor.process(_images)) {
      if (!mounted) return;
      last = progress;
      setState(() => _progress = progress);
    }

    if (!mounted || last == null) return;
    await _openReview(last.resultsSoFar, branchId);
  }

  Future<void> _openReview(List<BulkItem> items, int branchId) async {
    final saved = await showBulkReviewModal(
      context: context,
      items: items,
      branchId: branchId,
      branchName: _branchName(branchId),
    );
    if (!mounted) return;

    if (saved == null) {
      // Discarded — back to the image step so the batch isn't lost.
      setState(() => _step = _Step.pickImages);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Saved $saved ${saved == 1 ? 'transaction' : 'transactions'} '
          'to ${_branchName(branchId)}',
        ),
      ),
    );
    if (context.canPop()) context.pop();
  }

  String _branchName(int branchId) {
    final branches = ref.read(activeBranchesProvider).value ?? const <Branch>[];
    for (final branch in branches) {
      if (branch.id == branchId) return branch.name;
    }
    return 'branch';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bulk upload')),
      body: switch (_step) {
        _Step.pickBranch => _buildBranchStep(),
        _Step.pickImages => _buildImagesStep(),
        _Step.processing => _buildProcessingStep(),
      },
    );
  }

  // ── Step 1: branch ───────────────────────────────────────────────────────

  Widget _buildBranchStep() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Which branch are these screenshots for?',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        BranchChips(
          selectedId: _branchId,
          onSelected: (id) => setState(() => _branchId = id),
          onDefaultResolved: (id) {
            if (_branchId == null) setState(() => _branchId = id);
          },
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _branchId == null
              ? null
              : () => setState(() => _step = _Step.pickImages),
          child: const Text('Next'),
        ),
      ],
    );
  }

  // ── Step 2: images ───────────────────────────────────────────────────────

  Widget _buildImagesStep() {
    final full = _images.length >= BulkProcessor.maxImages;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _branchName(_branchId!),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Text(
                '${_images.length}/${BulkProcessor.maxImages}',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: full
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            // One extra tile for "+", unless we're at the cap.
            itemCount: _images.length + (full ? 0 : 1),
            itemBuilder: (context, i) {
              if (i == _images.length) return _AddTile(onTap: _addImages);
              return _ImageTile(
                image: _images[i],
                onRemove: () => setState(() => _images.removeAt(i)),
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _images.isEmpty ? null : _start,
                child: Text(
                  _images.length == 1
                      ? 'Start — 1 screenshot'
                      : 'Start — ${_images.length} screenshots',
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Step 3: processing ───────────────────────────────────────────────────

  Widget _buildProcessingStep() {
    final progress = _progress;
    final current = progress?.current ?? 0;
    final total = progress?.total ?? _images.length;

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Processing ${current == 0 ? 1 : current} of $total…',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: progress?.fraction ?? 0),
          const SizedBox(height: 12),
          Text(
            'Reading each screenshot on your device',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({required this.image, required this.onRemove});

  final File image;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(
            image,
            fit: BoxFit.cover,
            cacheWidth: 300, // keep grid decoding cheap (§2)
            errorBuilder: (context, _, _) => Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: const Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: InkWell(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 16, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(Icons.add_photo_alternate_outlined, color: scheme.primary),
      ),
    );
  }
}
