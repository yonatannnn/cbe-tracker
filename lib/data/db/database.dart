/// Drift database, tables and DAOs (§3).
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import '../../core/parser/cbe_parser.dart'; // TxType — used by generated part
import 'daos/branch_dao.dart';
import 'daos/settings_dao.dart';
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

/// One ledger row reduced to what a chart needs: when, how much, which way.
class LedgerEntry {
  const LedgerEntry({
    required this.date,
    required this.amountCents,
    required this.type,
  });

  final DateTime date;
  final int amountCents;
  final TxType type;
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
  tables: [Branches, Transactions, AppSettings],
  daos: [BranchDao, TransactionDao, SettingsDao],
)
class AppDatabase extends _$AppDatabase {
  /// Production database: `cbe_tracker.sqlite` inside [directory] — the
  /// active user's folder, so each user has her own file.
  AppDatabase.inDirectory(Directory directory) : super(_open(directory));

  /// The file a profile's database lives at. The backup service reads the same
  /// path, so the two can never disagree about which file is "the database".
  static File fileIn(Directory directory) =>
      File('${directory.path}/$fileName');

  static const String fileName = 'cbe_tracker.sqlite';

  /// Test/DI seam: pass a `NativeDatabase.memory()` executor.
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 5;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    onUpgrade: (m, from, to) async {
      // Each step is additive — existing branches and transactions survive.
      // v2: key-value settings table (last-used branch).
      if (from < 2) await m.createTable(appSettings);
      // v3 added the SMS debug log and v4 its dedupe indexes; v5 removes the
      // SMS feature altogether. Both tables are dropped — the shadow ledger
      // never affected balances (§3), so nothing she can see changes. Older
      // installs skip straight from 2 to 5 without ever creating them.
      if (from < 5) {
        await customStatement('DROP TABLE IF EXISTS sms_transactions');
        await customStatement('DROP TABLE IF EXISTS sms_debug_log');
      }
    },
    beforeOpen: (details) async {
      // Enforce referential integrity (branchId / matchedTransactionId FKs).
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  static QueryExecutor _open(Directory directory) => driftDatabase(
    name: 'cbe_tracker',
    native: DriftNativeOptions(
      databasePath: () async => fileIn(directory).path,
    ),
  );
}
