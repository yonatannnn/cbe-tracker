import 'package:drift/drift.dart';

import '../database.dart';
import '../tables.dart';

part 'sms_dao.g.dart';

/// SMS shadow ledger (§FR-4/§FR-5). Never affects balances.
@DriftAccessor(tables: [SmsTransactions])
class SmsDao extends DatabaseAccessor<AppDatabase> with _$SmsDaoMixin {
  SmsDao(super.db);

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
