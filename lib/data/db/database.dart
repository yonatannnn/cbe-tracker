/// Drift database, tables and DAOs (§3).
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/parser/cbe_parser.dart'; // TxType — used by generated part
import 'daos/branch_dao.dart';
import 'daos/settings_dao.dart';
import 'daos/sms_dao.dart';
import 'daos/transaction_dao.dart';
import 'tables.dart';

part 'database.g.dart';

/// Outcome of an idempotent insert (INSERT OR IGNORE on a UNIQUE reference).
enum InsertResult { inserted, duplicate }

/// A branch's per-day figures, all in integer cents (§FR-6).
class DailySummary {
  const DailySummary({
    required this.openingCents,
    required this.creditedCents,
    required this.debitedCents,
    required this.closingCents,
    required this.txCount,
  });

  final int openingCents;
  final int creditedCents;
  final int debitedCents;
  final int closingCents;
  final int txCount;
}

/// SMS reconciliation counts for a day (§FR-5 summary cards).
class DayCounts {
  const DayCounts({required this.received, required this.matched});

  final int received;
  final int matched;
}

/// Thrown when deleting a branch that still has transactions (§FR-1: such a
/// branch must be archived, not deleted).
class BranchHasTransactionsException implements Exception {
  BranchHasTransactionsException(this.branchId);

  final int branchId;

  @override
  String toString() =>
      'BranchHasTransactionsException: branch $branchId has transactions '
      'and cannot be deleted — archive it instead.';
}

@DriftDatabase(
  tables: [Branches, Transactions, SmsTransactions, AppSettings],
  daos: [BranchDao, TransactionDao, SmsDao, SettingsDao],
)
class AppDatabase extends _$AppDatabase {
  /// Production database, opened on disk via drift_flutter.
  AppDatabase() : super(_open());

  /// Test/DI seam: pass a `NativeDatabase.memory()` executor.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // v2 adds the key-value settings table (last-used branch). Existing
      // installs keep their branches and transactions.
      if (from < 2) await m.createTable(appSettings);
    },
    beforeOpen: (details) async {
      // Enforce referential integrity (branchId / matchedTransactionId FKs).
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  static QueryExecutor _open() => driftDatabase(name: 'cbe_tracker');
}
