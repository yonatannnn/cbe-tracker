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
  tables: [Branches, Transactions, SmsTransactions, AppSettings, SmsDebugLog],
  daos: [BranchDao, TransactionDao, SmsDao, SettingsDao],
)
class AppDatabase extends _$AppDatabase {
  /// Production database, opened on disk via drift_flutter.
  AppDatabase() : super(_open());

  /// Test/DI seam: pass a `NativeDatabase.memory()` executor.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Each step is additive — existing branches and transactions survive.
      // v2: key-value settings table (last-used branch).
      if (from < 2) await m.createTable(appSettings);
      // v3: debug log of unreadable CBE SMS bodies (§FR-4).
      if (from < 3) await m.createTable(smsDebugLog);

      // v4: content-based dedupe for the SMS tables. The reference alone
      // can't dedupe — modern CBE messages have none, and SQLite allows any
      // number of NULLs in a UNIQUE column, so re-syncing duplicated them.
      if (from < 4) {
        // Existing rows must be deduped BEFORE the unique indexes are added,
        // or index creation fails outright. Live data really is affected: the
        // debug log had 606 rows for 192 distinct messages. Keep the earliest
        // row of each group so ids stay stable.
        await customStatement(
          'DELETE FROM sms_transactions WHERE id NOT IN '
          '(SELECT MIN(id) FROM sms_transactions GROUP BY sms_body, '
          'received_at)',
        );
        await customStatement(
          'DELETE FROM sms_debug_log WHERE id NOT IN '
          '(SELECT MIN(id) FROM sms_debug_log GROUP BY body, received_at)',
        );
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS sms_body_time_unique '
          'ON sms_transactions (sms_body, received_at)',
        );
        await customStatement(
          'CREATE UNIQUE INDEX IF NOT EXISTS sms_debug_unique '
          'ON sms_debug_log (body, received_at)',
        );
      }
    },
    beforeOpen: (details) async {
      // Enforce referential integrity (branchId / matchedTransactionId FKs).
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  static QueryExecutor _open() => driftDatabase(name: 'cbe_tracker');
}
