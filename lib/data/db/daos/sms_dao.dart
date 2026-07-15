import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'sms_dao.g.dart';

/// SMS shadow ledger (§FR-4/§FR-5). Never affects balances.
@DriftAccessor(tables: [SmsTransactions, SmsDebugLog])
class SmsDao extends DatabaseAccessor<AppDatabase> with _$SmsDaoMixin {
  SmsDao(super.db);

  /// Every SMS still awaiting a match, any day — the reconcile input set.
  /// Ignored messages are excluded: marking one personal is final (§FR-5).
  Future<List<SmsTransaction>> allUnmatched() {
    return (select(smsTransactions)
          ..where(
            (s) => s.matchedTransactionId.isNull() & s.ignored.equals(false),
          )
          ..orderBy([(s) => OrderingTerm.asc(s.receivedAt)]))
        .get();
  }

  /// Transaction ids already claimed by some SMS, so the amount/type/day
  /// fallback can't hand the same transaction to two different messages.
  Future<List<int>> matchedTransactionIds() {
    final column = smsTransactions.matchedTransactionId;
    return (selectOnly(smsTransactions)
          ..addColumns([column])
          ..where(column.isNotNull()))
        .map((row) => row.read(column)!)
        .get();
  }

  /// Looks up an SMS by FT reference — used to show "Verified against SMS"
  /// on the confirm screen before saving (§FR-2).
  Future<SmsTransaction?> findByReference(String reference) {
    return (select(smsTransactions)
          ..where((s) => s.reference.equals(reference))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Live count of today's unmatched, un-ignored SMS — the dashboard banner.
  Stream<int> watchUnmatchedCountForDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return customSelect(
      'SELECT COUNT(*) AS c FROM sms_transactions '
      'WHERE received_at >= ?1 AND received_at < ?2 '
      'AND matched_transaction_id IS NULL AND ignored = 0',
      variables: [Variable<DateTime>(start), Variable<DateTime>(end)],
      readsFrom: {smsTransactions},
    ).map((row) => row.read<int>('c')).watchSingle();
  }

  /// The collapsed "Ignored today (n)" section (§FR-5).
  Stream<List<SmsTransaction>> watchIgnoredForDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return (select(smsTransactions)
          ..where(
            (s) =>
                s.receivedAt.isBiggerOrEqualValue(start) &
                s.receivedAt.isSmallerThanValue(end) &
                s.ignored.equals(true),
          )
          ..orderBy([(s) => OrderingTerm.asc(s.receivedAt)]))
        .watch();
  }

  /// Records a CBE SMS the parser couldn't read, for fixture harvesting.
  ///
  /// INSERT OR IGNORE against the (body, receivedAt) unique index: a re-sync
  /// re-reads the whole inbox, and without this the same failure is recorded
  /// again every time.
  Future<void> logUnreadable({
    required String address,
    required String body,
    required DateTime receivedAt,
    String? reason,
  }) {
    return into(smsDebugLog).insert(
      SmsDebugLogCompanion.insert(
        address: address,
        body: body,
        receivedAt: receivedAt,
        reason: Value(reason),
      ),
      mode: InsertMode.insertOrIgnore,
    );
  }

  /// Drops debug rows for a body that now parses.
  ///
  /// The log means "we currently cannot read this". Without this, entries
  /// recorded before a parser fix linger forever and misrepresent coverage —
  /// which is exactly what happened after the real-format fix.
  Future<int> clearDebugFor(String body) =>
      (delete(smsDebugLog)..where((d) => d.body.equals(body))).go();

  /// Idempotent insert: INSERT OR IGNORE on the UNIQUE reference — race-safe.
  Future<InsertResult> insertIfNew(SmsTransactionsCompanion entry) async {
    final row = await into(
      smsTransactions,
    ).insertReturningOrNull(entry, mode: InsertMode.insertOrIgnore);
    return row == null ? InsertResult.duplicate : InsertResult.inserted;
  }

  /// Unmatched, non-ignored SMS received on [day] (§FR-5 reconcile list).
  Stream<List<SmsTransaction>> watchUnmatchedForDay(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    return (select(smsTransactions)
          ..where(
            (s) =>
                s.receivedAt.isBiggerOrEqualValue(start) &
                s.receivedAt.isSmallerThanValue(end) &
                s.matchedTransactionId.isNull() &
                s.ignored.equals(false),
          )
          ..orderBy([(s) => OrderingTerm.asc(s.receivedAt)]))
        .watch();
  }

  /// Marks an SMS as reconciled against a real transaction (§FR-5).
  Future<int> linkToTransaction(int smsId, int txId) =>
      (update(smsTransactions)..where((s) => s.id.equals(smsId)))
          .write(SmsTransactionsCompanion(matchedTransactionId: Value(txId)));

  Future<int> setIgnored(int smsId, bool ignored) =>
      (update(smsTransactions)..where((s) => s.id.equals(smsId)))
          .write(SmsTransactionsCompanion(ignored: Value(ignored)));

  /// Received vs matched counts for [day] (§FR-5 summary cards).
  Future<DayCounts> countsForDay(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));
    final row = await customSelect(
      'SELECT COUNT(*) AS received, '
      'COALESCE(SUM(CASE WHEN matched_transaction_id IS NOT NULL '
      'THEN 1 ELSE 0 END), 0) AS matched '
      'FROM sms_transactions WHERE received_at >= ?1 AND received_at < ?2',
      variables: [Variable<DateTime>(start), Variable<DateTime>(end)],
      readsFrom: {smsTransactions},
    ).getSingle();
    return DayCounts(
      received: row.read<int>('received'),
      matched: row.read<int>('matched'),
    );
  }
}
