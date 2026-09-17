/// First-run onboarding: create initial branches (§8 Phase 3, FR-1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/database_provider.dart';
import '../../data/profiles/profile_provider.dart';

/// Shown when there are zero branches. Branches are written straight to the
/// database as they're added, so "first run" stays derived from the count.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
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

  @override
  Widget build(BuildContext context) {
    final branches = ref.watch(activeBranchesProvider);
    final added = branches.value ?? const [];
    final name = ref.watch(activeProfileProvider)?.name;

    return Scaffold(
      appBar: AppBar(title: const Text('Add your branches')),
      // SafeArea keeps Done clear of the system navigation bar.
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (name != null) ...[
                Text('Hi $name', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
              ],
              Text(
                'Create a branch for each shop you track. You can add more later.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Branch name',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _add(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _add,
                    icon: const Icon(Icons.add),
                    tooltip: 'Add branch',
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: added.isEmpty
                    ? Center(
                        child: Text(
                          'No branches yet',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(context).colorScheme.outline,
                              ),
                        ),
                      )
                    : SingleChildScrollView(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final branch in added)
                              InputChip(
                                label: Text(branch.name),
                                onDeleted: () => ref
                                    .read(branchDaoProvider)
                                    .deleteBranch(branch.id),
                              ),
                          ],
                        ),
                      ),
              ),
              FilledButton(
                // Enabled only once at least one branch exists.
                onPressed: added.isEmpty ? null : () => context.go('/home'),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
