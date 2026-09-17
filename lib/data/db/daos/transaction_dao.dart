import 'package:drift/drift.dart';

import '../../../core/parser/cbe_parser.dart' show TxType;
import '../database.dart';
import '../tables.dart';

part 'transaction_dao.g.dart';

/// Transactions — the ONLY source of balances (§3). All money math is integer
/// cents in SQL; there is no double arithmetic anywhere here.
@DriftAccessor(tables: [Transactions, Branches])
class TransactionDao extends DatabaseAccessor<AppDatabase>
    with _$TransactionDaoMixin {
  TransactionDao(super.db);

  /// Idempotent insert: INSERT OR IGNORE on the UNIQUE reference — race-safe,
  /// no pre-select. Returns [InsertResult.duplicate] when the reference
  /// already exists (§FR-2).
  Future<InsertResult> insertIfNew(TransactionsCompanion entry) async {
    final row = await into(
      transactions,
    ).insertReturningOrNull(entry, mode: InsertMode.insertOrIgnore);
    return row == null ? InsertResult.duplicate : InsertResult.inserted;
  }

  /// Looks up an existing transaction by its FT reference — used to show
  /// "Already recorded on `<date>`" when a duplicate is rejected (§FR-2).
  Future<Transaction?> findByReference(String reference) =>
      (select(transactions)
            ..where((t) => t.reference.equals(reference))
            ..limit(1))
          .getSingleOrNull();

  /// Commits every row in ONE transaction. Any failure — including an
  /// unexpected duplicate reference — rolls back the WHOLE batch.
  ///
  /// Duplicates are expected to be filtered out BEFORE calling this (the bulk
  /// review modal already excludes them, §FR-3), so a duplicate reaching here
  /// is treated as a real error, not silently skipped. A plain INSERT (not
  /// INSERT OR IGNORE) makes that a hard failure → full rollback.
  Future<void> insertManyAtomic(List<TransactionsCompanion> entries) {
    return transaction(() async {
      for (final entry in entries) {
        await into(transactions).insert(entry);
      }
    });
  }

  /// Live balance for one branch = SUM(credits) − SUM(debits), in cents.
  Stream<int> watchBalanceCents(int branchId) {
    return customSelect(
      "SELECT COALESCE(SUM(CASE WHEN type = 'credit' "
      'THEN amount_cents ELSE -amount_cents END), 0) AS balance '
      'FROM transactions WHERE branch_id = ?1',
      variables: [Variable<int>(branchId)],
      readsFrom: {transactions},
    ).map((row) => row.read<int>('balance')).watchSingle();
  }

  /// Live total balance across all NON-archived branches, in cents.
  Stream<int> watchTotalBalanceCents() {
    return customSelect(
      "SELECT COALESCE(SUM(CASE WHEN t.type = 'credit' "
      'THEN t.amount_cents ELSE -t.amount_cents END), 0) AS balance '
      'FROM transactions t JOIN branches b ON b.id = t.branch_id '
      'WHERE b.archived = 0',
      readsFrom: {transactions, branches},
    ).map((row) => row.read<int>('balance')).watchSingle();
  }

  /// Opening/credited/debited/closing/count for [day], computed from the
  /// transactions table so any past day regenerates identically (§FR-6).
  /// opening = signed sum before the day; closing = opening + credited −
  /// debited.
  Future<DailySummary> dailySummary(int branchId, DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final row = await customSelect(
      'SELECT '
      'COALESCE(SUM(CASE WHEN transaction_date < ?1 THEN '
      "(CASE WHEN type = 'credit' THEN amount_cents ELSE -amount_cents END) "
      'ELSE 0 END), 0) AS opening, '
      'COALESCE(SUM(CASE WHEN transaction_date >= ?1 AND transaction_date < ?2 '
      "AND type = 'credit' THEN amount_cents ELSE 0 END), 0) AS credited, "
      'COALESCE(SUM(CASE WHEN transaction_date >= ?1 AND transaction_date < ?2 '
      "AND type = 'debit' THEN amount_cents ELSE 0 END), 0) AS debited, "
      'COALESCE(SUM(CASE WHEN transaction_date >= ?1 AND transaction_date < ?2 '
      'THEN 1 ELSE 0 END), 0) AS tx_count '
      'FROM transactions WHERE branch_id = ?3',
      variables: [
        Variable<DateTime>(start),
        Variable<DateTime>(end),
        Variable<int>(branchId),
      ],
      readsFrom: {transactions},
    ).getSingle();

    final opening = row.read<int>('opening');
    final credited = row.read<int>('credited');
    final debited = row.read<int>('debited');
    return DailySummary(
      openingCents: opening,
      creditedCents: credited,
      debitedCents: debited,
      closingCents: opening + credited - debited,
      txCount: row.read<int>('tx_count'),
    );
  }

  /// Live signed delta for [day] across all NON-archived branches, in cents
  /// (credits − debits). Drives the dashboard's "today" line (§FR-8).
  Stream<int> watchDayDeltaCents(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return customSelect(
      "SELECT COALESCE(SUM(CASE WHEN t.type = 'credit' "
      'THEN t.amount_cents ELSE -t.amount_cents END), 0) AS delta '
      'FROM transactions t JOIN branches b ON b.id = t.branch_id '
      'WHERE b.archived = 0 '
      'AND t.transaction_date >= ?1 AND t.transaction_date < ?2',
      variables: [Variable<DateTime>(start), Variable<DateTime>(end)],
      readsFrom: {transactions, branches},
    ).map((row) => row.read<int>('delta')).watchSingle();
  }

  /// Live count of a branch's transactions on [day] (dashboard branch cards).
  Stream<int> watchDayCount(int branchId, DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return customSelect(
      'SELECT COUNT(*) AS tx_count FROM transactions '
      'WHERE branch_id = ?1 '
      'AND transaction_date >= ?2 AND transaction_date < ?3',
      variables: [
        Variable<int>(branchId),
        Variable<DateTime>(start),
        Variable<DateTime>(end),
      ],
      readsFrom: {transactions},
    ).map((row) => row.read<int>('tx_count')).watchSingle();
  }

  // ── period-scoped movement (dashboard period selector) ─────────────────────
  //
  // One shape for every period the dashboard offers. Each bound is optional: a
  // null start reaches back to the first transaction and a null end runs to the
  // present, so "all time" is just (null, null) — and movement over all time
  // equals the running balance, which is why these subsume the old
  // total/balance queries rather than sitting beside them. Bounds are compared
  // with `?n IS NULL OR …` so a null variable widens the window instead of
  // excluding every row (a direct `>= NULL` is never true in SQL).
  //
  // [start] is inclusive, [end] exclusive — the same half-open convention the
  // day queries use, so a day, a week and a month tile without double-counting
  // the boundary midnight.

  /// Live credits − debits within [start, end) across NON-archived branches.
  Stream<int> watchDeltaCentsInRange(DateTime? start, DateTime? end) {
    return customSelect(
      "SELECT COALESCE(SUM(CASE WHEN t.type = 'credit' "
      'THEN t.amount_cents ELSE -t.amount_cents END), 0) AS delta '
      'FROM transactions t JOIN branches b ON b.id = t.branch_id '
      'WHERE b.archived = 0 '
      'AND (?1 IS NULL OR t.transaction_date >= ?1) '
      'AND (?2 IS NULL OR t.transaction_date < ?2)',
      variables: [Variable<DateTime>(start), Variable<DateTime>(end)],
      readsFrom: {transactions, branches},
    ).map((row) => row.read<int>('delta')).watchSingle();
  }

  /// Live ledger rows within [start, end) across NON-archived branches —
  /// date, amount and type only, for the Reports bar chart to bucket by day.
  Stream<List<LedgerEntry>> watchLedgerInRange(DateTime start, DateTime end) {
    return customSelect(
      'SELECT t.transaction_date AS d, t.amount_cents AS a, t.type AS ty '
      'FROM transactions t JOIN branches b ON b.id = t.branch_id '
      'WHERE b.archived = 0 AND t.transaction_date >= ?1 '
      'AND t.transaction_date < ?2',
      variables: [Variable<DateTime>(start), Variable<DateTime>(end)],
      readsFrom: {transactions, branches},
    ).watch().map(
      (rows) => [
        for (final row in rows)
          LedgerEntry(
            date: row.read<DateTime>('d'),
            amountCents: row.read<int>('a'),
            type: TxType.values.byName(row.read<String>('ty')),
          ),
      ],
    );
  }

  /// Live credits − debits within [start, end) for one branch.
  Stream<int> watchBranchDeltaCentsInRange(
    int branchId,
    DateTime? start,
    DateTime? end,
  ) {
    return customSelect(
      "SELECT COALESCE(SUM(CASE WHEN type = 'credit' "
      'THEN amount_cents ELSE -amount_cents END), 0) AS delta '
      'FROM transactions WHERE branch_id = ?1 '
      'AND (?2 IS NULL OR transaction_date >= ?2) '
      'AND (?3 IS NULL OR transaction_date < ?3)',
      variables: [
        Variable<int>(branchId),
        Variable<DateTime>(start),
        Variable<DateTime>(end),
      ],
      readsFrom: {transactions},
    ).map((row) => row.read<int>('delta')).watchSingle();
  }

  /// Live count of a branch's transactions within [start, end).
  Stream<int> watchBranchCountInRange(
    int branchId,
    DateTime? start,
    DateTime? end,
  ) {
    return customSelect(
      'SELECT COUNT(*) AS tx_count FROM transactions WHERE branch_id = ?1 '
      'AND (?2 IS NULL OR transaction_date >= ?2) '
      'AND (?3 IS NULL OR transaction_date < ?3)',
      variables: [
        Variable<int>(branchId),
        Variable<DateTime>(start),
        Variable<DateTime>(end),
      ],
      readsFrom: {transactions},
    ).map((row) => row.read<int>('tx_count')).watchSingle();
  }

  /// Branch transactions ordered newest-first (day-grouping friendly, §FR-7).
  Stream<List<Transaction>> watchTransactionsForBranch(int branchId) {
    return (select(transactions)
          ..where((t) => t.branchId.equals(branchId))
          ..orderBy([
            (t) => OrderingTerm.desc(t.transactionDate),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .watch();
  }

  /// One transaction by id, for the detail screen.
  Future<Transaction?> findById(int id) =>
      (select(transactions)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// A branch's transactions for one local day, newest first — the report's
  /// per-branch list (§FR-6).
  Future<List<Transaction>> transactionsForBranchDay({
    required int branchId,
    required DateTime dayStart,
    required DateTime dayEnd,
  }) {
    return (select(transactions)
          ..where(
            (t) =>
                t.branchId.equals(branchId) &
                t.transactionDate.isBiggerOrEqualValue(dayStart) &
                t.transactionDate.isSmallerThanValue(dayEnd),
          )
          ..orderBy([
            (t) => OrderingTerm.desc(t.transactionDate),
            (t) => OrderingTerm.desc(t.id),
          ]))
        .get();
  }

  /// Applies an edit (amount / type / reference / branch). Balance streams
  /// recompute themselves, including for a branch change (§FR-7).
  Future<int> updateTransaction(int id, TransactionsCompanion changes) =>
      (update(transactions)..where((t) => t.id.equals(id))).write(changes);

  /// Deletes a transaction; balance streams recompute automatically (§FR-7).
  Future<int> deleteTransaction(int id) =>
      (delete(transactions)..where((t) => t.id.equals(id))).go();
}
