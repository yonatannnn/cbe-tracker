import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  /// Builds a transaction row for [branchId] with a given [reference].
  TransactionsCompanion txn({
    required int branchId,
    required int amountCents,
    required String reference,
    TxType type = TxType.credit,
    DateTime? date,
  }) {
    return TransactionsCompanion.insert(
      branchId: branchId,
      amountCents: amountCents,
      type: type,
      reference: reference,
      source: TxSource.screenshot,
      transactionDate: date ?? DateTime(2026, 7, 14, 10, 0),
    );
  }

  Future<int> rowCount() async =>
      (await db.select(db.transactions).get()).length;

  group('TransactionDao.insertIfNew — duplicate guard', () {
    test('duplicate reference → duplicate, row count stays 1', () async {
      final branch = await db.branchDao.createBranch('Main');

      final first = await db.transactionDao.insertIfNew(
        txn(branchId: branch, amountCents: 5000, reference: 'FTAAAAAAAAAA'),
      );
      final second = await db.transactionDao.insertIfNew(
        // Same reference, different amount — must NOT overwrite or add.
        txn(branchId: branch, amountCents: 9999, reference: 'FTAAAAAAAAAA'),
      );

      expect(first, InsertResult.inserted);
      expect(second, InsertResult.duplicate);
      expect(await rowCount(), 1);
      expect(await db.transactionDao.watchBalanceCents(branch).first, 5000);
    });
  });

  group('TransactionDao.insertManyAtomic — all-or-nothing', () {
    test('all valid rows → all inserted', () async {
      final branch = await db.branchDao.createBranch('Main');
      await db.transactionDao.insertManyAtomic([
        txn(branchId: branch, amountCents: 100, reference: 'FTBATCH00001'),
        txn(branchId: branch, amountCents: 200, reference: 'FTBATCH00002'),
        txn(branchId: branch, amountCents: 300, reference: 'FTBATCH00003'),
      ]);
      expect(await rowCount(), 3);
    });

    test('one invalid FK row → NOTHING inserted (full rollback)', () async {
      final branch = await db.branchDao.createBranch('Main');
      final batch = [
        txn(branchId: branch, amountCents: 100, reference: 'FTBATCH00001'),
        // No such branch → FK violation (foreign_keys pragma is ON).
        txn(branchId: 999999, amountCents: 200, reference: 'FTBATCH00002'),
        txn(branchId: branch, amountCents: 300, reference: 'FTBATCH00003'),
      ];

      await expectLater(
        db.transactionDao.insertManyAtomic(batch),
        throwsA(anything),
      );
      expect(await rowCount(), 0);
    });

    // DOCUMENTED DECISION (§FR-3): duplicates are filtered out BEFORE the
    // atomic batch (the review modal excludes them). So an unexpected
    // duplicate inside insertManyAtomic is a real error → FULL rollback of the
    // whole batch, NOT a partial "insert the other 4".
    test('one duplicate among five → full rollback, none committed', () async {
      final branch = await db.branchDao.createBranch('Main');
      await db.transactionDao.insertIfNew(
        txn(branchId: branch, amountCents: 111, reference: 'FTDUP0000001'),
      );

      final batch = [
        txn(branchId: branch, amountCents: 1, reference: 'FTBATCH00001'),
        txn(branchId: branch, amountCents: 2, reference: 'FTBATCH00002'),
        // Collides with the pre-existing row.
        txn(branchId: branch, amountCents: 3, reference: 'FTDUP0000001'),
        txn(branchId: branch, amountCents: 4, reference: 'FTBATCH00004'),
        txn(branchId: branch, amountCents: 5, reference: 'FTBATCH00005'),
      ];

      await expectLater(
        db.transactionDao.insertManyAtomic(batch),
        throwsA(anything),
      );
      // Only the pre-existing row survives; the batch was rolled back whole.
      expect(await rowCount(), 1);
    });
  });

  group('TransactionDao — balance math (integer cents)', () {
    test('3 credits + 2 debits → exact expected cents', () async {
      final branch = await db.branchDao.createBranch('Main');
      final rows = <TransactionsCompanion>[
        txn(branchId: branch, amountCents: 5000, reference: 'FTC000000001'),
        txn(branchId: branch, amountCents: 2500, reference: 'FTC000000002'),
        txn(branchId: branch, amountCents: 1000, reference: 'FTC000000003'),
        txn(
          branchId: branch,
          amountCents: 800,
          type: TxType.debit,
          reference: 'FTD000000001',
        ),
        txn(
          branchId: branch,
          amountCents: 700,
          type: TxType.debit,
          reference: 'FTD000000002',
        ),
      ];
      for (final r in rows) {
        await db.transactionDao.insertIfNew(r);
      }

      final balance = await db.transactionDao.watchBalanceCents(branch).first;
      expect(balance, 5000 + 2500 + 1000 - 800 - 700); // 7000
    });
  });

  group('TransactionDao.dailySummary — auditable across days', () {
    test('opening/closing correct for the middle day; deterministic', () async {
      final branch = await db.branchDao.createBranch('Main');
      // Day 1 (before): sets the opening balance for day 2.
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 10000,
          reference: 'FTDAY10001',
          date: DateTime(2026, 7, 13, 9, 0),
        ),
      );
      // Day 2 (middle): one credit + one debit.
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 3000,
          reference: 'FTDAY20001',
          date: DateTime(2026, 7, 14, 9, 0),
        ),
      );
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 1000,
          type: TxType.debit,
          reference: 'FTDAY20002',
          date: DateTime(2026, 7, 14, 15, 0),
        ),
      );
      // Day 3 (after): must NOT affect day 2's opening or closing.
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 500,
          reference: 'FTDAY30001',
          date: DateTime(2026, 7, 15, 9, 0),
        ),
      );

      final s = await db.transactionDao.dailySummary(
        branch,
        DateTime(2026, 7, 14),
      );
      expect(s.openingCents, 10000);
      expect(s.creditedCents, 3000);
      expect(s.debitedCents, 1000);
      expect(s.closingCents, 10000 + 3000 - 1000); // 12000
      expect(s.txCount, 2);

      // Regenerating the same past day is deterministic.
      final again = await db.transactionDao.dailySummary(
        branch,
        DateTime(2026, 7, 14),
      );
      expect(again.openingCents, s.openingCents);
      expect(again.creditedCents, s.creditedCents);
      expect(again.debitedCents, s.debitedCents);
      expect(again.closingCents, s.closingCents);
      expect(again.txCount, s.txCount);
    });
  });

  group('TransactionDao.deleteTransaction — live balance', () {
    test('delete emits an updated balance on the stream', () async {
      final branch = await db.branchDao.createBranch('Main');
      await db.transactionDao.insertIfNew(
        txn(branchId: branch, amountCents: 5000, reference: 'FTDEL00001'),
      );
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 2000,
          type: TxType.debit,
          reference: 'FTDEL00002',
        ),
      );
      final debit = (await db.select(db.transactions).get()).firstWhere(
        (t) => t.reference == 'FTDEL00002',
      );

      final stream = db.transactionDao.watchBalanceCents(branch);
      final expectation = expectLater(
        stream,
        emitsInOrder([3000, 5000]), // 5000-2000, then after delete 5000
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await db.transactionDao.deleteTransaction(debit.id);
      await expectation;
    });
  });

  group('TransactionDao.watchTotalBalanceCents — active branches only', () {
    test('archived branch balance is excluded from the total', () async {
      final a = await db.branchDao.createBranch('A');
      final b = await db.branchDao.createBranch('B');
      await db.transactionDao.insertIfNew(
        txn(branchId: a, amountCents: 5000, reference: 'FTTOT00001'),
      );
      await db.transactionDao.insertIfNew(
        txn(branchId: b, amountCents: 3000, reference: 'FTTOT00002'),
      );

      expect(await db.transactionDao.watchTotalBalanceCents().first, 8000);
      await db.branchDao.archiveBranch(b);
      expect(await db.transactionDao.watchTotalBalanceCents().first, 5000);
    });
  });

  group('TransactionDao — dashboard streams (Phase 3)', () {
    test('watchDayDeltaCents = credits − debits for that day only', () async {
      final branch = await db.branchDao.createBranch('Main');
      final today = DateTime(2026, 7, 14);
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 5000,
          reference: 'FTD1',
          date: DateTime(2026, 7, 14, 9, 0),
        ),
      );
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 2000,
          type: TxType.debit,
          reference: 'FTD2',
          date: DateTime(2026, 7, 14, 12, 0),
        ),
      );
      // Yesterday — must not count toward today's delta.
      await db.transactionDao.insertIfNew(
        txn(
          branchId: branch,
          amountCents: 9999,
          reference: 'FTD3',
          date: DateTime(2026, 7, 13, 9, 0),
        ),
      );

      expect(await db.transactionDao.watchDayDeltaCents(today).first, 3000);
    });

    test('watchDayDeltaCents excludes archived branches', () async {
      final a = await db.branchDao.createBranch('A');
      final b = await db.branchDao.createBranch('B');
      final today = DateTime(2026, 7, 14);
      await db.transactionDao.insertIfNew(
        txn(
          branchId: a,
          amountCents: 5000,
          reference: 'FTA1',
          date: DateTime(2026, 7, 14, 9, 0),
        ),
      );
      await db.transactionDao.insertIfNew(
        txn(
          branchId: b,
          amountCents: 1000,
          reference: 'FTB1',
          date: DateTime(2026, 7, 14, 9, 0),
        ),
      );

      expect(await db.transactionDao.watchDayDeltaCents(today).first, 6000);
      await db.branchDao.archiveBranch(b);
      expect(await db.transactionDao.watchDayDeltaCents(today).first, 5000);
    });

    test('watchDayCount counts only that branch, that day', () async {
      final a = await db.branchDao.createBranch('A');
      final b = await db.branchDao.createBranch('B');
      final today = DateTime(2026, 7, 14);
      await db.transactionDao.insertIfNew(
        txn(
          branchId: a,
          amountCents: 100,
          reference: 'FTC1',
          date: DateTime(2026, 7, 14, 9, 0),
        ),
      );
      await db.transactionDao.insertIfNew(
        txn(
          branchId: a,
          amountCents: 200,
          reference: 'FTC2',
          date: DateTime(2026, 7, 14, 18, 0),
        ),
      );
      await db.transactionDao.insertIfNew(
        txn(
          branchId: a,
          amountCents: 300,
          reference: 'FTC3',
          date: DateTime(2026, 7, 15, 9, 0),
        ),
      );
      await db.transactionDao.insertIfNew(
        txn(
          branchId: b,
          amountCents: 400,
          reference: 'FTC4',
          date: DateTime(2026, 7, 14, 9, 0),
        ),
      );

      expect(await db.transactionDao.watchDayCount(a, today).first, 2);
      expect(await db.transactionDao.watchDayCount(b, today).first, 1);
    });
  });

  group('BranchDao — delete rules (§FR-1)', () {
    test('deleteBranch with transactions throws', () async {
      final branch = await db.branchDao.createBranch('Main');
      await db.transactionDao.insertIfNew(
        txn(branchId: branch, amountCents: 5000, reference: 'FTBR00001'),
      );

      await expectLater(
        db.branchDao.deleteBranch(branch),
        throwsA(isA<BranchHasTransactionsException>()),
      );
      expect((await db.branchDao.watchActiveBranches().first).length, 1);
    });

    test('deleteBranch with no transactions succeeds', () async {
      final branch = await db.branchDao.createBranch('Empty');
      await db.branchDao.deleteBranch(branch);
      expect((await db.branchDao.watchActiveBranches().first), isEmpty);
    });
  });


  group('TransactionDao — period-scoped movement (dashboard windows)', () {
    // A ledger spanning three days, one branch, so the windows are easy to
    // reason about: +100 on the 10th, −40 on the 14th, +30 on the 15th.
    Future<int> seed() async {
      final branch = await db.branchDao.createBranch('Main');
      await db.transactionDao.insertIfNew(txn(
        branchId: branch,
        amountCents: 10000,
        reference: 'R-10TH',
        date: DateTime(2026, 7, 10, 9),
      ));
      await db.transactionDao.insertIfNew(txn(
        branchId: branch,
        amountCents: 4000,
        type: TxType.debit,
        reference: 'R-14TH',
        date: DateTime(2026, 7, 14, 12),
      ));
      await db.transactionDao.insertIfNew(txn(
        branchId: branch,
        amountCents: 3000,
        reference: 'R-15TH',
        date: DateTime(2026, 7, 15, 8),
      ));
      return branch;
    }

    test('null bounds sum the whole ledger — movement equals balance', () async {
      await seed();
      // 10000 − 4000 + 3000 = 9000.
      expect(
        await db.transactionDao.watchDeltaCentsInRange(null, null).first,
        9000,
      );
    });

    test('a single day counts only that day, boundary exclusive', () async {
      await seed();
      // The 14th only: a −4000 debit. The 15th's +3000 must not leak in.
      final start = DateTime(2026, 7, 14);
      final end = DateTime(2026, 7, 15);
      expect(
        await db.transactionDao.watchDeltaCentsInRange(start, end).first,
        -4000,
      );
    });

    test('an open start (…, end) reaches back to the first row', () async {
      await seed();
      // Everything before the 15th: 10000 − 4000 = 6000.
      expect(
        await db.transactionDao
            .watchDeltaCentsInRange(null, DateTime(2026, 7, 15))
            .first,
        6000,
      );
    });

    test('an open end (start, …) runs to the present', () async {
      await seed();
      // From the 14th onward: −4000 + 3000 = −1000.
      expect(
        await db.transactionDao
            .watchDeltaCentsInRange(DateTime(2026, 7, 14), null)
            .first,
        -1000,
      );
    });

    test('per-branch range and count agree with the window', () async {
      final branch = await seed();
      // 13th (Mon) through now: the −4000 and +3000 → −1000, two rows.
      final weekStart = DateTime(2026, 7, 13);
      expect(
        await db.transactionDao
            .watchBranchDeltaCentsInRange(branch, weekStart, null)
            .first,
        -1000,
      );
      expect(
        await db.transactionDao
            .watchBranchCountInRange(branch, weekStart, null)
            .first,
        2,
      );
      // All time for the branch is its balance and its whole count.
      expect(
        await db.transactionDao
            .watchBranchDeltaCentsInRange(branch, null, null)
            .first,
        9000,
      );
      expect(
        await db.transactionDao
            .watchBranchCountInRange(branch, null, null)
            .first,
        3,
      );
    });

    test('an archived branch is excluded from the all-branches delta', () async {
      final active = await db.branchDao.createBranch('Active');
      final archived = await db.branchDao.createBranch('Archived');
      await db.transactionDao.insertIfNew(txn(
        branchId: active,
        amountCents: 5000,
        reference: 'R-ACTIVE',
        date: DateTime(2026, 7, 15, 8),
      ));
      await db.transactionDao.insertIfNew(txn(
        branchId: archived,
        amountCents: 9999,
        reference: 'R-ARCHIVED',
        date: DateTime(2026, 7, 15, 8),
      ));
      await db.branchDao.archiveBranch(archived);

      expect(
        await db.transactionDao.watchDeltaCentsInRange(null, null).first,
        5000,
        reason: "the archived branch's 9999 must not count",
      );
    });
  });
}
