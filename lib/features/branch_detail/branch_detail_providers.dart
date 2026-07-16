/// Providers for branch detail + transaction detail (§FR-7).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';

// All family providers here are autoDispose: they're keyed by whichever branch
// or transaction happens to be open, so without it every screen ever visited
// would keep a live Drift subscription for the rest of the session — and each
// would re-run its query on every write to the watched tables. The screens
// re-create them on entry anyway.

/// A branch's transactions, newest first, each with its SMS link.
final branchTransactionsProvider = StreamProvider.autoDispose
    .family<List<TransactionWithSms>, int>(
      (ref, branchId) => ref
          .watch(transactionDaoProvider)
          .watchBranchTransactionsWithSms(branchId),
    );

/// Today's in/out for the summary card.
///
/// Reuses the Phase 2 dailySummary rather than re-deriving the day maths, and
/// re-runs whenever the branch's transactions change — or the day rolls over —
/// so it tracks the list.
final branchTodaySummaryProvider = FutureProvider.autoDispose
    .family<DailySummary, int>((ref, branchId) {
      ref.watch(branchTransactionsProvider(branchId));
      final today = ref.watch(todayProvider);
      return ref.watch(transactionDaoProvider).dailySummary(branchId, today);
    });

/// One branch by id, for the app bar title.
final branchByIdProvider = Provider.autoDispose.family<Branch?, int>((
  ref,
  branchId,
) {
  final branches = ref.watch(activeBranchesProvider).value ?? const <Branch>[];
  for (final branch in branches) {
    if (branch.id == branchId) return branch;
  }
  return null;
});

/// One transaction with its SMS link, for the detail screen.
final transactionByIdProvider = FutureProvider.autoDispose
    .family<TransactionWithSms?, int>((ref, id) {
      // Re-reads after an edit so the detail screen never shows stale fields.
      // autoDispose matters doubly here: id-space is unbounded, and every
      // retained instance re-ran this fetch on every bump().
      ref.watch(transactionRevisionProvider);
      return ref.watch(transactionDaoProvider).findWithSms(id);
    });

/// Bumped after an edit to force [transactionByIdProvider] to re-read.
class TransactionRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final transactionRevisionProvider = NotifierProvider<TransactionRevision, int>(
  TransactionRevision.new,
);
