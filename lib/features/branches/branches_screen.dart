/// Branch management page (§FR-1): add, rename, archive or remove branches,
/// with each one's standing balance. Tapping a branch opens it.
///
/// A full page rather than the old bottom sheet: managing branches is a
/// destination she goes to on purpose, and the balances make it a useful
/// overview in its own right.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';

class BranchesScreen extends ConsumerStatefulWidget {
  const BranchesScreen({super.key});

  @override
  ConsumerState<BranchesScreen> createState() => _BranchesScreenState();
}

class _BranchesScreenState extends ConsumerState<BranchesScreen> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    await ref.read(branchDaoProvider).createBranch(name);
    _controller.clear();
  }

  Future<void> _rename(Branch branch) async {
    final name = await _promptName(
      context,
      title: 'Rename branch',
      initial: branch.name,
    );
    if (name == null || name.isEmpty || name == branch.name) return;
    await ref.read(branchDaoProvider).renameBranch(branch.id, name);
  }

  /// Tries a hard delete first. The DAO throws when the branch has any
  /// transactions (§FR-1) — in that case we offer archiving instead. Branches
  /// with zero transactions are deleted outright.
  Future<void> _remove(Branch branch) async {
    final dao = ref.read(branchDaoProvider);
    try {
      await dao.deleteBranch(branch.id);
    } on BranchHasTransactionsException {
      if (!mounted) return;
      final archive = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(branch.name),
          content: const Text(
            'This branch has transactions, so it can only be archived. '
            'Its transactions are kept; it just leaves the dashboard and '
            'reports.',
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
      if (archive ?? false) await dao.archiveBranch(branch.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final branches = ref.watch(activeBranchesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Branches')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'New branch name',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  IconButton.filled(
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                    tooltip: 'Add branch',
                  ),
                ],
              ),
            ),
            Expanded(
              child: branches.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) =>
                    Center(child: Text("Couldn't load branches: $error")),
                data: (list) => list.isEmpty
                    ? Center(
                        child: Text(
                          'No branches yet',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          AppSpacing.sm,
                          AppSpacing.lg,
                          AppSpacing.xl,
                        ),
                        itemCount: list.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: AppSpacing.sm),
                        itemBuilder: (context, i) => _BranchCard(
                          branch: list[i],
                          onRename: () => _rename(list[i]),
                          onRemove: () => _remove(list[i]),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchCard extends ConsumerWidget {
  const _BranchCard({
    required this.branch,
    required this.onRename,
    required this.onRemove,
  });

  final Branch branch;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(branchBalanceCentsProvider(branch.id)).value;

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.store_outlined),
        title: Text(branch.name),
        subtitle: Text(
          balance == null ? '—' : formatCents(balance),
          style: AppTextStyles.moneyRow.copyWith(
            fontSize: 13,
            color: balance == null
                ? AppColors.muted
                : balance < 0
                ? AppColors.debit
                : AppColors.ink,
          ),
        ),
        trailing: PopupMenuButton<String>(
          tooltip: 'Branch actions',
          onSelected: (value) => switch (value) {
            'rename' => onRename(),
            'remove' => onRemove(),
            _ => null,
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'remove', child: Text('Remove')),
          ],
        ),
        onTap: () => context.push('/branch/${branch.id}'),
      ),
    );
  }
}

/// Shared name prompt for rename.
Future<String?> _promptName(
  BuildContext context, {
  required String title,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  final name = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Branch name'),
        onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  return name;
}
