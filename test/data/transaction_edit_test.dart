// Phase 7 (§FR-7): editing and deleting a transaction, and what that does to
// balances and to a linked CBE SMS.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/reconcile_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ReconcileService reconciler;
  late int bole;
  late int cmc;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    reconciler = ReconcileService(
      smsDao: db.smsDao,
      transactionDao: db.transactionDao,
    );
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

  var smsSeq = 0;
  Future<int> addSms({
    String? reference,
    int cents = 500000,
    DateTime? receivedAt,
  }) async {
    await db.smsDao.insertIfNew(
      SmsTransactionsCompanion.insert(
        amountCents: cents,
        smsBody: 'CBE message #${++smsSeq}',
        receivedAt: receivedAt ?? DateTime(2026, 7, 14, 10, 42),
        type: const Value(TxType.credit),
        reference: Value(reference),
      ),
    );
    return (await db.select(db.smsTransactions).get()).last.id;
  }

  group('deleting a transaction with a linked SMS (§FR-7 + §FR-5)', () {
    test('the SMS returns to unmatched and re-enters reconciliation', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T');
      final smsId = await addSms(reference: 'FT26195XKQ8T');

      expect(await reconciler.reconcile(), 1);
      final day = DateTime(2026, 7, 14);
      expect(await db.smsDao.watchUnmatchedForDay(day).first, isEmpty);

      // She deletes the screenshot — the payment still happened, so the SMS
      // must resurface rather than vanish with it.
      await db.transactionDao.deleteTransaction(txId);

      final unmatched = await db.smsDao.watchUnmatchedForDay(day).first;
      expect(unmatched.map((s) => s.id), [smsId]);
      expect(unmatched.single.matchedTransactionId, isNull);
    });

    test('the delete is not blocked by the foreign key', () async {
      // matchedTransactionId references transactions(id) with no ON DELETE, so
      // without unlinking first SQLite rejects the delete entirely.
      final txId = await addTx(reference: 'FT26195XKQ8T');
      await addSms(reference: 'FT26195XKQ8T');
      await reconciler.reconcile();

      await db.transactionDao.deleteTransaction(txId);

      expect(await db.select(db.transactions).get(), isEmpty);
      expect(await db.transactionDao.watchBalanceCents(bole).first, 0);
    });

    test('re-adding the screenshot re-links the same SMS', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T');
      await addSms(reference: 'FT26195XKQ8T');
      await reconciler.reconcile();
      await db.transactionDao.deleteTransaction(txId);

      final newTxId = await addTx(reference: 'FT26195XKQ8T');
      expect(await reconciler.reconcile(), 1);

      final sms = (await db.select(db.smsTransactions).get()).single;
      expect(sms.matchedTransactionId, newTxId);
    });

    test('deleting an unlinked transaction still works', () async {
      final txId = await addTx(reference: 'FTNOSMS00001');
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

  group('transactions joined with their SMS (no N+1)', () {
    test('verified and unverified rows come back in one query', () async {
      await addTx(reference: 'FTVERIFIED01', date: DateTime(2026, 7, 14, 9, 0));
      await addTx(reference: 'FTPLAIN00001', date: DateTime(2026, 7, 14, 8, 0));
      await addSms(reference: 'FTVERIFIED01');
      await reconciler.reconcile();

      final rows = await db.transactionDao
          .watchBranchTransactionsWithSms(bole)
          .first;

      expect(rows, hasLength(2));
      // Newest first.
      expect(rows.first.transaction.reference, 'FTVERIFIED01');
      expect(rows.first.isVerified, isTrue);
      expect(rows.first.sms, isNotNull);
      expect(rows.last.transaction.reference, 'FTPLAIN00001');
      expect(rows.last.isVerified, isFalse);
      expect(rows.last.sms, isNull);
    });

    test('only this branch', () async {
      await addTx(reference: 'FTBOLE000001');
      await addTx(reference: 'FTCMC0000001', branchId: cmc);

      final rows = await db.transactionDao
          .watchBranchTransactionsWithSms(bole)
          .first;
      expect(rows.map((r) => r.transaction.reference), ['FTBOLE000001']);
    });

    test('findWithSms returns the link for the detail screen', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T');
      await addSms(reference: 'FT26195XKQ8T');
      await reconciler.reconcile();

      final found = await db.transactionDao.findWithSms(txId);
      expect(found, isNotNull);
      expect(found!.isVerified, isTrue);
      expect(found.sms!.reference, 'FT26195XKQ8T');
    });
  });
}
