/// Branch picker shared by the single-add and bulk-add flows (§7).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';
import '../../services/service_providers.dart';

/// 2-column grid of active branches, most recently used pre-selected (§FR-2).
class BranchChips extends ConsumerWidget {
  const BranchChips({
    super.key,
    required this.selectedId,
    required this.onSelected,
    required this.onDefaultResolved,
  });

  final int? selectedId;
  final ValueChanged<int> onSelected;

  /// Called once with the branch that should start selected.
  final ValueChanged<int> onDefaultResolved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(activeBranchesProvider);
    final lastUsed = ref.watch(lastBranchIdProvider).value;

    // Distinguish "still loading" from "truly none": `.value ?? []` flashed the
    // no-branches message during the stream's first moments, telling a user
    // with five branches she had none.
    if (async.isLoading && !async.hasValue) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (async.hasError && !async.hasValue) {
      return const Text(
        "Couldn't load branches. Close and reopen this screen.",
      );
    }
    final branches = async.value ?? const <Branch>[];

    if (branches.isEmpty) {
      // Branches are managed in Settings, not the dashboard.
      return const Text(
        'No branches yet — add one in Settings → Manage branches.',
      );
    }

    // Pre-select the most recently used branch, else the first one.
    if (selectedId == null) {
      final preferred = branches.any((b) => b.id == lastUsed)
          ? lastUsed!
          : branches.first.id;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onDefaultResolved(preferred),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: branches.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 3.2,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemBuilder: (context, i) {
        final branch = branches[i];
        return ChoiceChip(
          label: Text(branch.name, overflow: TextOverflow.ellipsis),
          selected: selectedId == branch.id,
          onSelected: (_) => onSelected(branch.id),
        );
      },
    );
  }
}
