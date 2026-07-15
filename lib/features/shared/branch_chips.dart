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
    final branches = ref.watch(activeBranchesProvider).value ?? const <Branch>[];
    final lastUsed = ref.watch(lastBranchIdProvider).value;

    if (branches.isEmpty) {
      return const Text('No branches yet — add one from the dashboard.');
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
