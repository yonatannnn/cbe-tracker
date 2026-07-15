/// Branch detail + transaction detail (§8 Phase 7, FR-7).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/money/etb_format.dart';
import '../../data/db/database_provider.dart';

/// Placeholder until Phase 7 builds the day-grouped list. It already shows the
/// live balance so the dashboard tap-through is verifiable now.
class BranchDetailPlaceholderScreen extends ConsumerWidget {
  const BranchDetailPlaceholderScreen({super.key, required this.branchId});

  final int branchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = ref.watch(branchBalanceCentsProvider(branchId));
    return Scaffold(
      appBar: AppBar(title: const Text('Branch')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              balance.maybeWhen(data: formatCents, orElse: () => '—'),
              style: AppTextStyles.money,
            ),
            const SizedBox(height: 8),
            Text(
              'Transaction list arrives in Phase 7',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
