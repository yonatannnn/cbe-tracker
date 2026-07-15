/// Matches shadow-ledger SMS against real screenshot transactions (§FR-5).
///
/// SMS never affects balances — this only sets `matchedTransactionId` so the
/// Reconcile tab can show what arrived by SMS but was never screenshotted.
///
/// Runs after any transaction insert, any SMS insert, and on app resume. It is
/// idempotent: a matched SMS is skipped on later runs, so re-running is free.
library;

import '../data/db/daos/sms_dao.dart';
import '../data/db/daos/transaction_dao.dart';
import '../data/db/database.dart';

class ReconcileService {
  ReconcileService({required this.smsDao, required this.transactionDao});

  final SmsDao smsDao;
  final TransactionDao transactionDao;

  /// Links every SMS it confidently can. Returns how many it linked.
  Future<int> reconcile() async {
    final pending = await smsDao.allUnmatched();
    if (pending.isEmpty) return 0;

    // Transactions already spoken for. Without this, two identical SMS (same
    // amount, type and day) would BOTH fall back onto the single screenshot
    // that exists, and the day would look fully reconciled when one payment
    // is still missing a screenshot.
    final claimed = (await smsDao.matchedTransactionIds()).toSet();

    var linked = 0;
    for (final sms in pending) {
      final txId = await _findMatch(sms, claimed);
      if (txId == null) continue;
      await smsDao.linkToTransaction(sms.id, txId);
      claimed.add(txId);
      linked++;
    }
    return linked;
  }

  /// The match rules, in order (§FR-5). Returns null when nothing is certain —
  /// an unmatched row is a prompt for the user, a wrong match is a lie.
  Future<int?> _findMatch(SmsTransaction sms, Set<int> claimed) async {
    // 1) Exact FT reference. Both sides are UNIQUE, so this can't be
    //    ambiguous and doesn't need the `claimed` guard.
    final reference = sms.reference;
    if (reference != null && reference.isNotEmpty) {
      final exact = await transactionDao.findByReference(reference);
      if (exact != null) return exact.id;
    }

    // 2) Fallback for OCR misreads of the reference: same amount, same type,
    //    same LOCAL calendar day.
    final type = sms.type;
    if (type == null) return null; // can't match without a direction

    final dayStart = _startOfLocalDay(sms.receivedAt);
    final candidates = await transactionDao.findCandidates(
      amountCents: sms.amountCents,
      type: type,
      dayStart: dayStart,
      dayEnd: dayStart.add(const Duration(days: 1)),
    );

    final available = candidates
        .where((t) => !claimed.contains(t.id))
        .toList(growable: false);

    // Exactly one, or nothing. Several same-amount payments on one day are
    // genuinely ambiguous, so they stay unmatched for manual resolution.
    return available.length == 1 ? available.single.id : null;
  }

  /// Midnight local — the day boundary the fallback compares on. An SMS at
  /// 23:50 and a transaction at 00:10 the next day are different days.
  static DateTime _startOfLocalDay(DateTime moment) =>
      DateTime(moment.year, moment.month, moment.day);
}
