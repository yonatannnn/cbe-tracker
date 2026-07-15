// §FR-6: reports are COMPUTED from the transactions table for the chosen date,
// never from a stored running number. The load-bearing guarantee is that a past
// day's report is stable — yesterday's numbers must not move because something
// happened today.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/reconcile_service.dart';
import 'package:cbe_tracker/services/report_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ReportService reports;
  late ReconcileService reconciler;
  late int bole;
  late int cmc;

  final day1 = DateTime(2026, 7, 13);
  final day2 = DateTime(2026, 7, 14); // the middle day under test
  final day3 = DateTime(2026, 7, 15);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    reports = ReportService(
      branchDao: db.branchDao,
      transactionDao: db.transactionDao,
      smsDao: db.smsDao,
    );
    reconciler = ReconcileService(
      smsDao: db.smsDao,
      transactionDao: db.transactionDao,
    );
    bole = await db.branchDao.createBranch('Bole');
    cmc = await db.branchDao.createBranch('Cmc');
  });
  tearDown(() => db.close());

  Future<void> addTx({
    required String reference,
    required DateTime date,
    int? branchId,
    int cents = 100000,
    TxType type = TxType.credit,
  }) async {
    await db.transactionDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: branchId ?? bole,
        amountCents: cents,
        type: type,
        reference: reference,
        source: TxSource.screenshot,
        transactionDate: date,
      ),
    );
  }

  var smsSeq = 0;
  Future<void> addSms({
    String? reference,
    int cents = 100000,
    required DateTime receivedAt,
    bool ignored = false,
  }) async {
    await db.smsDao.insertIfNew(
      SmsTransactionsCompanion.insert(
        amountCents: cents,
        smsBody: 'CBE message #${++smsSeq}',
        receivedAt: receivedAt,
        type: const Value(TxType.credit),
        reference: Value(reference),
        ignored: Value(ignored),
      ),
    );
  }

  BranchDayReport boleIn(DailyReport report) =>
      report.branches.firstWhere((b) => b.branch.id == bole);

  group('a past day is stable and auditable (§FR-6)', () {
    test('the middle day is unaffected by later activity', () async {
      await addTx(reference: 'FTD1A', date: DateTime(2026, 7, 13, 9, 0));
      await addTx(reference: 'FTD2A', date: DateTime(2026, 7, 14, 9, 0));
      await addTx(
        reference: 'FTD2B',
        date: DateTime(2026, 7, 14, 15, 0),
        cents: 40000,
        type: TxType.debit,
      );

      final before = await reports.dailyReport(day2);
      final b = boleIn(before);
      expect(b.summary.openingCents, 100000, reason: 'day 1 credit');
      expect(b.summary.creditedCents, 100000);
      expect(b.summary.debitedCents, 40000);
      expect(b.summary.closingCents, 160000);
      expect(b.totalCount, 2);

      // A later day's activity happens...
      await addTx(reference: 'FTD3A', date: DateTime(2026, 7, 15, 9, 0));
      await addTx(reference: 'FTD3B', date: DateTime(2026, 7, 15, 12, 0));

      // ...and day 2's report must be byte-for-byte what it was.
      final after = boleIn(await reports.dailyReport(day2));
      expect(after.summary.openingCents, b.summary.openingCents);
      expect(after.summary.creditedCents, b.summary.creditedCents);
      expect(after.summary.debitedCents, b.summary.debitedCents);
      expect(after.summary.closingCents, b.summary.closingCents);
      expect(after.totalCount, b.totalCount);
    });

    test('backdating into day 1 DOES change day 2 opening — correctly', () async {
      await addTx(reference: 'FTD2A', date: DateTime(2026, 7, 14, 9, 0));
      expect(boleIn(await reports.dailyReport(day2)).summary.openingCents, 0);

      // A screenshot from day 1 added late is real history; day 2's opening
      // must reflect it. Recomputation is the point.
      await addTx(reference: 'FTD1LATE', date: DateTime(2026, 7, 13, 9, 0));
      expect(
        boleIn(await reports.dailyReport(day2)).summary.openingCents,
        100000,
      );
    });

    test('regenerating the same day twice gives identical numbers', () async {
      await addTx(reference: 'FTD2A', date: DateTime(2026, 7, 14, 9, 0));
      final first = boleIn(await reports.dailyReport(day2));
      final second = boleIn(await reports.dailyReport(day2));

      expect(second.summary.openingCents, first.summary.openingCents);
      expect(second.summary.closingCents, first.summary.closingCents);
      expect(second.verifiedCount, first.verifiedCount);
      expect(second.transactions.length, first.transactions.length);
    });

    test('a day with no activity still reports, with a carried opening',
        () async {
      await addTx(reference: 'FTD1A', date: DateTime(2026, 7, 13, 9, 0));

      final b = boleIn(await reports.dailyReport(day2));
      expect(b.hasTransactions, isFalse);
      expect(b.summary.openingCents, 100000);
      expect(b.summary.closingCents, 100000, reason: 'nothing moved');
      expect(b.totalCount, 0);
      expect(b.transactions, isEmpty);
    });
  });

  group('verification counts', () {
    test('a mix of matched and unmatched → n/total', () async {
      await addTx(reference: 'FTVER1', date: DateTime(2026, 7, 14, 9, 0));
      await addTx(reference: 'FTVER2', date: DateTime(2026, 7, 14, 10, 0));
      await addTx(reference: 'FTVER3', date: DateTime(2026, 7, 14, 11, 0));
      // Only two of the three have a CBE message.
      await addSms(reference: 'FTVER1', receivedAt: DateTime(2026, 7, 14, 9, 1));
      await addSms(
        reference: 'FTVER2',
        receivedAt: DateTime(2026, 7, 14, 10, 1),
      );
      await reconciler.reconcile();

      final b = boleIn(await reports.dailyReport(day2));
      expect(b.verifiedCount, 2);
      expect(b.totalCount, 3);
      expect(b.verificationLabel, '2/3');
      expect(b.isFullyVerified, isFalse, reason: 'amber');
    });

    test('all matched → fully verified (green)', () async {
      await addTx(reference: 'FTVER1', date: DateTime(2026, 7, 14, 9, 0));
      await addSms(reference: 'FTVER1', receivedAt: DateTime(2026, 7, 14, 9, 1));
      await reconciler.reconcile();

      final b = boleIn(await reports.dailyReport(day2));
      expect(b.verificationLabel, '1/1');
      expect(b.isFullyVerified, isTrue);
    });

    test('no transactions is NOT "fully verified"', () async {
      // 0/0 must not read as a green tick — there is nothing to vouch for.
      final b = boleIn(await reports.dailyReport(day2));
      expect(b.isFullyVerified, isFalse);
      expect(b.verificationLabel, '0/0');
    });

    test('verification is per-day: yesterday\'s SMS does not count', () async {
      await addTx(reference: 'FTTODAY', date: DateTime(2026, 7, 14, 9, 0));
      await addTx(reference: 'FTPREV', date: DateTime(2026, 7, 13, 9, 0));
      await addSms(reference: 'FTPREV', receivedAt: DateTime(2026, 7, 13, 9, 1));
      await reconciler.reconcile();

      final day2Report = boleIn(await reports.dailyReport(day2));
      expect(day2Report.verifiedCount, 0);
      expect(day2Report.totalCount, 1);

      final day1Report = boleIn(await reports.dailyReport(day1));
      expect(day1Report.verifiedCount, 1);
      expect(day1Report.totalCount, 1);
    });
  });

  group('reconciliation footer', () {
    test('counts personal and unresolved for that day only', () async {
      await addSms(
        reference: 'FTIGN1',
        receivedAt: DateTime(2026, 7, 14, 9, 0),
        ignored: true,
      );
      await addSms(
        reference: 'FTIGN2',
        receivedAt: DateTime(2026, 7, 14, 10, 0),
        ignored: true,
      );
      await addSms(reference: 'FTUN1', receivedAt: DateTime(2026, 7, 14, 11, 0));
      // A different day — must not leak in.
      await addSms(reference: 'FTOTHER', receivedAt: DateTime(2026, 7, 15, 9, 0));

      final footer = (await reports.dailyReport(day2)).footer;
      expect(footer.personalCount, 2);
      expect(footer.unresolvedCount, 1);
      expect(footer.isEmpty, isFalse);
    });

    test('a matched SMS is neither personal nor unresolved', () async {
      await addTx(reference: 'FTM1', date: DateTime(2026, 7, 14, 9, 0));
      await addSms(reference: 'FTM1', receivedAt: DateTime(2026, 7, 14, 9, 1));
      await reconciler.reconcile();

      final footer = (await reports.dailyReport(day2)).footer;
      expect(footer.personalCount, 0);
      expect(footer.unresolvedCount, 0);
      expect(footer.isEmpty, isTrue);
    });

    test('an ignored SMS is personal, not unresolved', () async {
      await addSms(
        reference: 'FTIGN',
        receivedAt: DateTime(2026, 7, 14, 9, 0),
        ignored: true,
      );
      final footer = (await reports.dailyReport(day2)).footer;
      expect(footer.personalCount, 1);
      expect(footer.unresolvedCount, 0, reason: 'ignoring resolves it');
    });
  });

  group('across branches', () {
    test('every active branch appears; totals add up', () async {
      await addTx(reference: 'FTB1', date: DateTime(2026, 7, 14, 9, 0));
      await addTx(
        reference: 'FTC1',
        date: DateTime(2026, 7, 14, 9, 0),
        branchId: cmc,
        cents: 250000,
      );

      final report = await reports.dailyReport(day2);
      expect(report.branches, hasLength(2));
      expect(report.totalCreditedCents, 350000);
      expect(report.totalClosingCents, 350000);
      expect(report.totalTransactionCount, 2);
      expect(report.activeBranches, hasLength(2));
    });

    test('an archived branch is excluded', () async {
      await addTx(reference: 'FTB1', date: DateTime(2026, 7, 14, 9, 0));
      await addTx(
        reference: 'FTC1',
        date: DateTime(2026, 7, 14, 9, 0),
        branchId: cmc,
      );
      await db.branchDao.archiveBranch(cmc);

      final report = await reports.dailyReport(day2);
      expect(report.branches.map((b) => b.branch.name), ['Bole']);
    });

    test('a silent branch is listed but not "active" for the PDF', () async {
      await addTx(reference: 'FTB1', date: DateTime(2026, 7, 14, 9, 0));

      final report = await reports.dailyReport(day2);
      expect(report.branches, hasLength(2), reason: 'both listed on screen');
      expect(
        report.activeBranches.map((b) => b.branch.name),
        ['Bole'],
        reason: 'only branches that moved money get a PDF section',
      );
    });
  });

  group('day boundaries', () {
    test('23:59 belongs to that day, 00:00 to the next', () async {
      await addTx(reference: 'FTLATE', date: DateTime(2026, 7, 14, 23, 59));
      await addTx(reference: 'FTEARLY', date: DateTime(2026, 7, 15, 0, 0));

      expect(boleIn(await reports.dailyReport(day2)).totalCount, 1);
      expect(boleIn(await reports.dailyReport(day3)).totalCount, 1);
      // And day 3 opens with day 2's money.
      expect(
        boleIn(await reports.dailyReport(day3)).summary.openingCents,
        100000,
      );
    });

    test('the day argument is normalized — any time of day works', () async {
      await addTx(reference: 'FTX', date: DateTime(2026, 7, 14, 9, 0));
      final atNoon = await reports.dailyReport(DateTime(2026, 7, 14, 12, 34));
      expect(boleIn(atNoon).totalCount, 1);
      expect(atNoon.day, DateTime(2026, 7, 14));
    });
  });
}
