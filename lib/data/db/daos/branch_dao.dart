import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'branch_dao.g.dart';

/// Branch CRUD (§FR-1). Balance is derived elsewhere, never stored here.
@DriftAccessor(tables: [Branches, Transactions])
class BranchDao extends DatabaseAccessor<AppDatabase> with _$BranchDaoMixin {
  BranchDao(super.db);

  /// Creates a branch and returns its id.
  Future<int> createBranch(String name) =>
      into(branches).insert(BranchesCompanion.insert(name: name));

  Future<int> renameBranch(int id, String name) =>
      (update(branches)..where((b) => b.id.equals(id)))
          .write(BranchesCompanion(name: Value(name)));

  Future<int> archiveBranch(int id) =>
      (update(branches)..where((b) => b.id.equals(id)))
          .write(const BranchesCompanion(archived: Value(true)));

  /// Live list of non-archived branches, alphabetical.
  Stream<List<Branch>> watchActiveBranches() => (select(branches)
        ..where((b) => b.archived.equals(false))
        ..orderBy([(b) => OrderingTerm.asc(b.name)]))
      .watch();

  /// Deletes a branch, but throws [BranchHasTransactionsException] if it has
  /// ANY transactions (§FR-1). The check and delete run in one transaction so
  /// a concurrent insert can't slip through.
  Future<void> deleteBranch(int id) {
    return transaction(() async {
      final txCount = transactions.id.count();
      final count = await (selectOnly(transactions)
            ..addColumns([txCount])
            ..where(transactions.branchId.equals(id)))
          .map((row) => row.read(txCount) ?? 0)
          .getSingle();
      if (count > 0) {
        throw BranchHasTransactionsException(id);
      }
      await (delete(branches)..where((b) => b.id.equals(id))).go();
    });
  }
}
