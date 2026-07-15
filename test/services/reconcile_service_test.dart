// The critical Phase 6 suite: reconciliation against an in-memory database.
//
// A wrong match is worse than no match — it tells the user a payment is
// accounted for when it isn't. These tests pin exactly when we link and, more
// importantly, when we refuse to.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/reconcile_service.dart';
// Only Value is needed; importing all of drift collides with matcher's isNull.
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late ReconcileService service;
  late int branch;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    service = ReconcileService(
      smsDao: db.smsDao,
      transactionDao: db.transactionDao,
    );
    branch = await db.branchDao.createBranch('Bole');
  });
  tearDown(() => db.close());

  /// Inserts a screenshot transaction and returns its id.
  Future<int> addTx({
    required String reference,
    int cents = 500000,
    TxType type = TxType.credit,
    DateTime? date,
  }) async {
    await db.transactionDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: branch,
        amountCents: cents,
        type: type,
        reference: reference,
        source: TxSource.screenshot,
        transactionDate: date ?? DateTime(2026, 7, 14, 10, 42),
      ),
    );
    return (await db.transactionDao.findByReference(reference))!.id;
  }

  // The ledger dedupes on (smsBody, receivedAt), so every test message needs a
  // distinct body — as real ones have. Sharing one body would silently collapse
  // two messages into a single row and make these tests lie.
  var smsSeq = 0;

  /// Inserts a shadow-ledger SMS and returns its id.
  Future<int> addSms({
    String? reference,
    int cents = 500000,
    TxType? type = TxType.credit,
    DateTime? receivedAt,
    bool ignored = false,
  }) async {
    final result = await db.smsDao.insertIfNew(
      SmsTransactionsCompanion.insert(
        amountCents: cents,
        smsBody: 'CBE test message #${++smsSeq}',
        receivedAt: receivedAt ?? DateTime(2026, 7, 14, 10, 42),
        type: Value(type),
        reference: Value(reference),
        ignored: Value(ignored),
      ),
    );
    expect(result, InsertResult.inserted, reason: 'test setup must insert');
    final all = await db.select(db.smsTransactions).get();
    return all.last.id;
  }

  Future<SmsTransaction> smsById(int id) async =>
      (await (db.select(db.smsTransactions)
            ..where((s) => s.id.equals(id)))
          .getSingle());

  group('rule 1 — exact reference', () {
    test('links an SMS to the transaction with the same FT reference', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T');
      final smsId = await addSms(reference: 'FT26195XKQ8T');

      expect(await service.reconcile(), 1);
      expect((await smsById(smsId)).matchedTransactionId, txId);
    });

    test('a different reference does not link', () async {
      await addTx(reference: 'FT26195XKQ8T');
      final smsId = await addSms(
        reference: 'FTZZZZZZZZZZ',
        // Different amount too, so the fallback can't rescue it.
        cents: 999999,
      );

      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);
    });

    test('exact reference wins even across days', () async {
      // The reference is authoritative; the fallback's day rule doesn't apply.
      final txId = await addTx(
        reference: 'FT26195XKQ8T',
        date: DateTime(2026, 7, 10, 9, 0),
      );
      final smsId = await addSms(
        reference: 'FT26195XKQ8T',
        receivedAt: DateTime(2026, 7, 14, 10, 42),
      );

      expect(await service.reconcile(), 1);
      expect((await smsById(smsId)).matchedTransactionId, txId);
    });
  });

  group('rule 2 — fallback on amount + type + local day', () {
    test('links when the reference was misread but the rest agrees', () async {
      // OCR mangled the screenshot's reference, so the refs differ.
      final txId = await addTx(
        reference: 'FTOCRMANGLED',
        cents: 320000,
        date: DateTime(2026, 7, 14, 9, 5),
      );
      final smsId = await addSms(
        reference: 'FTREALREF001',
        cents: 320000,
        receivedAt: DateTime(2026, 7, 14, 9, 4),
      );

      expect(await service.reconcile(), 1);
      expect((await smsById(smsId)).matchedTransactionId, txId);
    });

    test('a different amount does not link', () async {
      await addTx(reference: 'FTA', cents: 320000);
      final smsId = await addSms(reference: 'FTB', cents: 320001);

      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);
    });

    test('a different type does not link', () async {
      await addTx(reference: 'FTA', cents: 320000, type: TxType.credit);
      final smsId = await addSms(
        reference: 'FTB',
        cents: 320000,
        type: TxType.debit,
      );

      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);
    });

    test('an SMS with no type never falls back', () async {
      await addTx(reference: 'FTA', cents: 320000);
      final smsId = await addSms(reference: 'FTB', cents: 320000, type: null);

      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);
    });
  });

  group('ambiguity — never guess (§FR-5)', () {
    test('TWO candidate transactions → stays unmatched', () async {
      // Two identical payments the same day; we cannot know which is which.
      await addTx(reference: 'FTONE', cents: 320000, date: DateTime(2026, 7, 14, 9, 0));
      await addTx(reference: 'FTTWO', cents: 320000, date: DateTime(2026, 7, 14, 15, 0));
      final smsId = await addSms(reference: 'FTSMS', cents: 320000);

      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);
    });

    test('two identical SMS cannot both claim the one transaction', () async {
      // Two payments arrived, only one screenshot was saved. Linking both
      // would report the day as fully reconciled while a screenshot is still
      // missing.
      final txId = await addTx(reference: 'FTTX', cents: 320000);
      final smsA = await addSms(reference: 'FTSMSA', cents: 320000);
      final smsB = await addSms(reference: 'FTSMSB', cents: 320000);

      expect(await service.reconcile(), 1, reason: 'exactly one may link');

      final linked = [
        (await smsById(smsA)).matchedTransactionId,
        (await smsById(smsB)).matchedTransactionId,
      ];
      expect(linked.where((id) => id == txId), hasLength(1));
      expect(linked.where((id) => id == null), hasLength(1));
    });
  });

  group('day boundary is the LOCAL calendar day', () {
    test('SMS 23:50 vs transaction 00:10 next day → NOT a match', () async {
      await addTx(
        reference: 'FTNEXTDAY',
        cents: 320000,
        date: DateTime(2026, 7, 15, 0, 10),
      );
      final smsId = await addSms(
        reference: 'FTLATE',
        cents: 320000,
        receivedAt: DateTime(2026, 7, 14, 23, 50),
      );

      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);
    });

    test('same day at the edges (00:00 and 23:59) → matches', () async {
      final txId = await addTx(
        reference: 'FTEDGE',
        cents: 320000,
        date: DateTime(2026, 7, 14, 0, 0),
      );
      final smsId = await addSms(
        reference: 'FTEDGESMS',
        cents: 320000,
        receivedAt: DateTime(2026, 7, 14, 23, 59),
      );

      expect(await service.reconcile(), 1);
      expect((await smsById(smsId)).matchedTransactionId, txId);
    });
  });

  group('ignored SMS', () {
    test('is never matched and never counted', () async {
      await addTx(reference: 'FT26195XKQ8T');
      final smsId = await addSms(reference: 'FT26195XKQ8T', ignored: true);

      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);
    });

    test('is absent from the unmatched list', () async {
      await addSms(reference: 'FTIGNORED', ignored: true);
      expect(await db.smsDao.allUnmatched(), isEmpty);
    });
  });

  group('idempotency', () {
    test('running twice changes nothing', () async {
      final txId = await addTx(reference: 'FT26195XKQ8T');
      final smsId = await addSms(reference: 'FT26195XKQ8T');

      expect(await service.reconcile(), 1);
      expect(await service.reconcile(), 0, reason: 'nothing left to link');
      expect(await service.reconcile(), 0);

      expect((await smsById(smsId)).matchedTransactionId, txId);
      // And the link didn't duplicate or drift.
      expect(await db.smsDao.allUnmatched(), isEmpty);
    });
  });

  group('SMS arriving BEFORE its screenshot', () {
    test('saving the screenshot later links the waiting SMS', () async {
      // The SMS lands first — nothing to match yet.
      final smsId = await addSms(reference: 'FT26195XKQ8T');
      expect(await service.reconcile(), 0);
      expect((await smsById(smsId)).matchedTransactionId, isNull);

      // She screenshots it later; reconcile-on-insert catches up.
      final txId = await addTx(reference: 'FT26195XKQ8T');
      expect(await service.reconcile(), 1);
      expect((await smsById(smsId)).matchedTransactionId, txId);
    });

    test('the fallback direction works too', () async {
      final smsId = await addSms(
        reference: 'FTSMSONLY',
        cents: 750000,
        receivedAt: DateTime(2026, 7, 14, 11, 0),
      );
      expect(await service.reconcile(), 0);

      final txId = await addTx(
        reference: 'FTSHOTLATER',
        cents: 750000,
        date: DateTime(2026, 7, 14, 16, 30),
      );
      expect(await service.reconcile(), 1);
      expect((await smsById(smsId)).matchedTransactionId, txId);
    });
  });

  group('balances are untouched', () {
    test('reconciling never changes a branch balance', () async {
      await addTx(reference: 'FT26195XKQ8T', cents: 500000);
      await addSms(reference: 'FT26195XKQ8T', cents: 500000);
      final before = await db.transactionDao.watchBalanceCents(branch).first;

      await service.reconcile();

      expect(await db.transactionDao.watchBalanceCents(branch).first, before);
      expect(before, 500000, reason: 'SMS is a shadow ledger only (§FR-4)');
    });
  });

  group('nothing to do', () {
    test('no SMS at all → 0', () async {
      expect(await service.reconcile(), 0);
    });
  });
}
