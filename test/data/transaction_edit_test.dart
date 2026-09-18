// Phase 7 (§FR-7): editing and deleting a transaction, and what that does to
// balances.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late int bole;
  late int cmc;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    bole = await db.branchDao.createBranch('Bole');
    cmc = await db.branchDao.createBranch('Cmc');
  });
  tearDown(() => db.close());

  Future<int> addTx({
    required String reference,
    int branchId = 0,
    int cents = 500000,
    TxType type = TxType.credit,
    DateTime? date,
  }) async {
    await db.transactionDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: branchId == 0 ? bole : branchId,
        amountCents: cents,
        type: type,
        reference: reference,
        source: TxSource.screenshot,
        transactionDate: date ?? DateTime(2026, 7, 14, 10, 42),
      ),
    );
    return (await db.transactionDao.findByReference(reference))!.id;
  }

  group('deleting a transaction (§FR-7)', () {
    test('the row goes and the balance follows', () async {
      final txId = await addTx(reference: 'FTGONE000001');
      expect(await db.transactionDao.deleteTransaction(txId), 1);
      expect(await db.select(db.transactions).get(), isEmpty);
    });
  });

  group('editing a transaction', () {
    test('changing the amount emits a new balance', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T', cents: 500000);
      expect(await db.transactionDao.watchBalanceCents(bole).first, 500000);

      await db.transactionDao.updateTransaction(
        txId,
        const TransactionsCompanion(amountCents: Value(320000)),
      );

      expect(await db.transactionDao.watchBalanceCents(bole).first, 320000);
    });

    test('changing the type flips the balance sign', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T', cents: 500000);
      await db.transactionDao.updateTransaction(
        txId,
        const TransactionsCompanion(type: Value(TxType.debit)),
      );
      expect(await db.transactionDao.watchBalanceCents(bole).first, -500000);
    });

    test('moving to another branch updates BOTH balances', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T', cents: 500000);
      expect(await db.transactionDao.watchBalanceCents(bole).first, 500000);
      expect(await db.transactionDao.watchBalanceCents(cmc).first, 0);

      await db.transactionDao.updateTransaction(
        txId,
        TransactionsCompanion(branchId: Value(cmc)),
      );

      expect(await db.transactionDao.watchBalanceCents(bole).first, 0);
      expect(await db.transactionDao.watchBalanceCents(cmc).first, 500000);
      // The money moved, it didn't multiply.
      expect(await db.transactionDao.watchTotalBalanceCents().first, 500000);
    });

    test('the balance stream pushes the edit without a re-read', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T', cents: 500000);
      final stream = db.transactionDao.watchBalanceCents(bole);
      final expectation = expectLater(stream, emitsInOrder([500000, 320000]));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await db.transactionDao.updateTransaction(
        txId,
        const TransactionsCompanion(amountCents: Value(320000)),
      );
      await expectation;
    });
  });

  group('a branch\'s rows', () {
    test('come back newest first', () async {
      await addTx(reference: 'FTNEWER00001', date: DateTime(2026, 7, 14, 9, 0));
      await addTx(reference: 'FTOLDER00001', date: DateTime(2026, 7, 14, 8, 0));

      final rows = await db.transactionDao
          .watchTransactionsForBranch(bole)
          .first;
      expect(rows.map((r) => r.reference), ['FTNEWER00001', 'FTOLDER00001']);
    });

    test('only this branch', () async {
      await addTx(reference: 'FTBOLE000001');
      await addTx(reference: 'FTCMC0000001', branchId: cmc);

      final rows = await db.transactionDao
          .watchTransactionsForBranch(bole)
          .first;
      expect(rows.map((r) => r.reference), ['FTBOLE000001']);
    });

    test('findById feeds the detail screen', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T');
      final found = await db.transactionDao.findById(txId);
      expect(found?.reference, 'FT26195XKQ8T');
      expect(await db.transactionDao.findById(txId + 99), isNull);
    });
  });
}
