/// One-line cloud hooks for the screens: after a save, edit, delete or branch
/// change, mirror it to Firestore in the background.
///
/// Every hook reads the signed-in user and the rows fresh from the database,
/// so callers pass ids, never copies. All of them are fire-and-forget: the
/// phone's write has already succeeded, and a cloud failure is logged, never
/// shown.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database.dart';
import '../data/db/database_provider.dart';
import '../data/profiles/profile_provider.dart';
import 'service_providers.dart';

extension CloudSync on WidgetRef {
  /// Mirrors the transactions with these references (just saved or edited).
  void cloudSyncTransactions(Iterable<String> references) {
    final sync = read(firebaseSyncProvider);
    final profile = read(activeProfileProvider);
    if (sync == null || profile == null) return;
    final dao = read(transactionDaoProvider);
    unawaited(() async {
      final rows = <Transaction>[];
      for (final reference in references) {
        final tx = await dao.findByReference(reference);
        if (tx != null) rows.add(tx);
      }
      await sync.upsertTransactions(profile, rows);
    }());
  }

  void cloudDeleteTransaction(Transaction tx) {
    final sync = read(firebaseSyncProvider);
    final profile = read(activeProfileProvider);
    if (sync == null || profile == null) return;
    unawaited(sync.deleteTransaction(profile, tx));
  }

  /// Mirrors one branch (created, renamed or archived).
  void cloudSyncBranch(int branchId) {
    final sync = read(firebaseSyncProvider);
    final profile = read(activeProfileProvider);
    if (sync == null || profile == null) return;
    final db = read(appDatabaseProvider);
    unawaited(() async {
      final branch = await (db.select(
        db.branches,
      )..where((b) => b.id.equals(branchId))).getSingleOrNull();
      if (branch != null) await sync.upsertBranch(profile, branch);
    }());
  }

  void cloudDeleteBranch(int branchId) {
    final sync = read(firebaseSyncProvider);
    final profile = read(activeProfileProvider);
    if (sync == null || profile == null) return;
    unawaited(sync.deleteBranch(profile, branchId));
  }
}
