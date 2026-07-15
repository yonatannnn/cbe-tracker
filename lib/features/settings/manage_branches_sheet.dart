/// Manage-branches sheet (§7 sheets, FR-1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';

/// Opens the manage-branches bottom sheet.
Future<void> showManageBranchesSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const ManageBranchesSheet(),
  );
}

class ManageBranchesSheet extends ConsumerWidget {
  const ManageBranchesSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final branches = ref.watch(activeBranchesProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Manage branches',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Flexible(
              child: branches.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text("Couldn't load branches: $error"),
                ),
                data: (list) => ListView(
                  shrinkWrap: true,
                  children: [
                    for (final branch in list)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(branch.name),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Rename',
                              onPressed: () => _rename(context, ref, branch),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'Remove',
                              onPressed: () => _remove(context, ref, branch),
                            ),
                          ],
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => _create(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('Add branch'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await _promptName(context, title: 'New branch');
    if (name == null || name.isEmpty) return;
    await ref.read(branchDaoProvider).createBranch(name);
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    Branch branch,
  ) async {
    final name = await _promptName(
      context,
      title: 'Rename branch',
      initial: branch.name,
    );
    if (name == null || name.isEmpty || name == branch.name) return;
    await ref.read(branchDaoProvider).renameBranch(branch.id, name);
  }

  /// Tries a hard delete first. The Phase 2 DAO throws when the branch has any
  /// transactions (§FR-1) — in that case we offer archiving instead. Branches
  /// with zero transactions are deleted outright.
  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    Branch branch,
  ) async {
    final dao = ref.read(branchDaoProvider);
    try {
      await dao.deleteBranch(branch.id);
    } on BranchHasTransactionsException {
      if (!context.mounted) return;
      final archive = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(branch.name),
          content: const Text(
            'This branch has transactions — archive instead?',
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
      if (archive ?? false) {
        await dao.archiveBranch(branch.id);
      }
    }
  }
}

/// Shared name prompt for create/rename.
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
