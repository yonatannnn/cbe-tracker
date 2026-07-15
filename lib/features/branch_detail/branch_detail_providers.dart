/// Providers for branch detail + transaction detail (§FR-7).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db/database.dart';
import '../../data/db/database_provider.dart';

/// A branch's transactions, newest first, each with its SMS link.
final branchTransactionsProvider =
    StreamProvider.family<List<TransactionWithSms>, int>(
      (ref, branchId) => ref
          .watch(transactionDaoProvider)
          .watchBranchTransactionsWithSms(branchId),
    );

/// Today's in/out for the summary card.
///
/// Reuses the Phase 2 dailySummary rather than re-deriving the day maths, and
/// re-runs whenever the branch's transactions change so it tracks the list.
final branchTodaySummaryProvider = FutureProvider.family<DailySummary, int>((
  ref,
  branchId,
) {
  ref.watch(branchTransactionsProvider(branchId));
  return ref
      .watch(transactionDaoProvider)
      .dailySummary(branchId, DateTime.now());
});

/// One branch by id, for the app bar title.
final branchByIdProvider = Provider.family<Branch?, int>((ref, branchId) {
  final branches = ref.watch(activeBranchesProvider).value ?? const <Branch>[];
  for (final branch in branches) {
    if (branch.id == branchId) return branch;
  }
  return null;
});

/// One transaction with its SMS link, for the detail screen.
final transactionByIdProvider = FutureProvider.family<TransactionWithSms?, int>(
  (ref, id) {
    // Re-reads after an edit so the detail screen never shows stale fields.
    ref.watch(transactionRevisionProvider);
    return ref.watch(transactionDaoProvider).findWithSms(id);
  },
);

/// Bumped after an edit to force [transactionByIdProvider] to re-read.
class TransactionRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final transactionRevisionProvider = NotifierProvider<TransactionRevision, int>(
  TransactionRevision.new,
);
