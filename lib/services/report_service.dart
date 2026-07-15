/// Daily report aggregation (§6, FR-6).
///
/// Everything is COMPUTED from the transactions table for the requested day —
/// no stored running totals — so any past day can be regenerated and audited,
/// and later activity can never rewrite an old report.
library;

import '../data/db/daos/branch_dao.dart';
import '../data/db/daos/sms_dao.dart';
import '../data/db/daos/transaction_dao.dart';
import '../data/db/database.dart';

/// One branch's figures for one day.
class BranchDayReport {
  const BranchDayReport({
    required this.branch,
    required this.summary,
    required this.verifiedCount,
    required this.transactions,
  });

  final Branch branch;

  /// opening / credited / debited / closing / txCount, all integer cents.
  final DailySummary summary;

  /// How many of the day's transactions a CBE SMS corroborates.
  final int verifiedCount;

  /// The day's transactions, newest first — the PDF's per-branch list.
  final List<TransactionWithSms> transactions;

  int get totalCount => summary.txCount;

  /// "12/12" — green when all are verified, amber when partial (§FR-6).
  String get verificationLabel => '$verifiedCount/$totalCount';

  /// True only when there IS something to verify and all of it is.
  bool get isFullyVerified => totalCount > 0 && verifiedCount == totalCount;

  bool get hasTransactions => totalCount > 0;
}

/// "n SMS marked personal · n unresolved" (§FR-6).
class ReconciliationFooter {
  const ReconciliationFooter({
    required this.personalCount,
    required this.unresolvedCount,
  });

  final int personalCount;
  final int unresolvedCount;

  bool get isEmpty => personalCount == 0 && unresolvedCount == 0;
}

/// A whole day, across every active branch.
class DailyReport {
  const DailyReport({
    required this.day,
    required this.branches,
    required this.footer,
  });

  final DateTime day;
  final List<BranchDayReport> branches;
  final ReconciliationFooter footer;

  int get totalClosingCents =>
      branches.fold(0, (sum, b) => sum + b.summary.closingCents);

  int get totalCreditedCents =>
      branches.fold(0, (sum, b) => sum + b.summary.creditedCents);

  int get totalDebitedCents =>
      branches.fold(0, (sum, b) => sum + b.summary.debitedCents);

  int get totalTransactionCount =>
      branches.fold(0, (sum, b) => sum + b.totalCount);

  int get totalVerifiedCount =>
      branches.fold(0, (sum, b) => sum + b.verifiedCount);

  /// Branches that actually moved money — the PDF skips silent ones.
  List<BranchDayReport> get activeBranches =>
      branches.where((b) => b.hasTransactions).toList(growable: false);
}

class ReportService {
  ReportService({
    required this.branchDao,
    required this.transactionDao,
    required this.smsDao,
  });

  final BranchDao branchDao;
  final TransactionDao transactionDao;
  final SmsDao smsDao;

  /// The full report for [day], every active branch.
  Future<DailyReport> dailyReport(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));

    final branches = await branchDao.watchActiveBranches().first;

    final reports = <BranchDayReport>[];
    for (final branch in branches) {
      // Reuses the Phase 2 DAO rather than re-deriving the day maths.
      final summary = await transactionDao.dailySummary(branch.id, start);
      final transactions = await transactionDao.transactionsForBranchDay(
        branchId: branch.id,
        dayStart: start,
        dayEnd: end,
      );
      reports.add(
        BranchDayReport(
          branch: branch,
          summary: summary,
          verifiedCount: transactions.where((t) => t.isVerified).length,
          transactions: transactions,
        ),
      );
    }

    return DailyReport(
      day: start,
      branches: reports,
      footer: await reconciliationFooter(start),
    );
  }

  /// Personal / unresolved SMS counts for [day].
  Future<ReconciliationFooter> reconciliationFooter(DateTime day) async {
    final counts = await smsDao.footerCountsForDay(day);
    return ReconciliationFooter(
      personalCount: counts.personal,
      unresolvedCount: counts.unresolved,
    );
  }
}
