// Pure review-modal rules: defaults per status, the live save label, and a
// failed row becoming checkable once filled in. No widgets, no database.

import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/features/bulk_add/bulk_review_state.dart';
import 'package:cbe_tracker/services/bulk_processor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final image = File('never_read.png');

  ParsedCbeMessage parsed({
    int cents = 500000,
    TxType type = TxType.credit,
    String? reference = 'FT26195XKQ8T',
    Confidence confidence = Confidence.high,
  }) {
    return ParsedCbeMessage(
      amountCents: cents,
      type: type,
      reference: reference,
      date: DateTime(2026, 7, 14, 10, 42),
      confidence: confidence,
      rawText: 'raw',
    );
  }

  Transaction existingTx() => Transaction(
    id: 1,
    branchId: 1,
    amountCents: 500000,
    type: TxType.credit,
    reference: 'FT26195XKQ8T',
    source: TxSource.screenshot,
    transactionDate: DateTime(2026, 7, 13, 9, 0),
    createdAt: DateTime(2026, 7, 13, 9, 0),
  );

  BulkItem ok({int cents = 500000, TxType type = TxType.credit}) =>
      BulkItem.ok(image, parsed(cents: cents, type: type));
  BulkItem ai({int cents = 500000}) => BulkItem.okAiParsed(
    image,
    parsed(cents: cents, confidence: Confidence.aiParsed, reference: null),
  );
  BulkItem dup() => BulkItem.duplicate(image, parsed(), existingTx());
  BulkItem failed() => BulkItem.failed(image, 'unreadable text');

  group('initial defaults per status (§FR-3)', () {
    test('ok rows are checked; ai/duplicate/failed are not', () {
      final state = ReviewState.initial([ok(), ai(), dup(), failed()]);

      expect(state.rows[0].checked, isTrue, reason: 'ok');
      expect(
        state.rows[1].checked,
        isFalse,
        reason: 'aiParsed must be looked at',
      );
      expect(state.rows[2].checked, isFalse, reason: 'duplicate');
      expect(state.rows[3].checked, isFalse, reason: 'failed');
    });

    test('checked count reflects only the ok rows', () {
      final state = ReviewState.initial([ok(), ok(), ai(), dup(), failed()]);
      expect(state.checkedCount, 2);
    });

    test('duplicates are never checkable', () {
      final state = ReviewState.initial([dup()]);
      expect(state.rows.single.isCheckable, isFalse);
      // Even an explicit toggle can't turn one on.
      expect(state.toggle(0, checked: true).checkedCount, 0);
    });

    test('only ai and failed rows are editable', () {
      final state = ReviewState.initial([ok(), ai(), dup(), failed()]);
      expect(
        state.rows[0].isEditable,
        isFalse,
        reason: 'clean parse: read-only',
      );
      expect(state.rows[1].isEditable, isTrue);
      expect(state.rows[2].isEditable, isFalse);
      expect(state.rows[3].isEditable, isTrue);
    });
  });

  group('save button', () {
    test('label states the exact count and pluralises', () {
      expect(ReviewState.initial([ai()]).saveLabel, 'Approve 0 transactions');
      expect(ReviewState.initial([ok()]).saveLabel, 'Approve 1 transaction');
      expect(
        ReviewState.initial([ok(), ok(), ok(), ok(), ok()]).saveLabel,
        'Approve 5 transactions',
      );
    });

    test('disabled at zero checked', () {
      expect(ReviewState.initial([ai(), dup()]).canSave, isFalse);
      expect(ReviewState.initial([ok()]).canSave, isTrue);
    });

    test('label tracks toggles live', () {
      var state = ReviewState.initial([ok(), ok(), ok()]);
      expect(state.saveLabel, 'Approve 3 transactions');

      state = state.toggle(0, checked: false);
      expect(state.saveLabel, 'Approve 2 transactions');

      state = state.toggle(1, checked: false);
      state = state.toggle(2, checked: false);
      expect(state.saveLabel, 'Approve 0 transactions');
      expect(state.canSave, isFalse);
    });
  });

  group('aiParsed rows', () {
    test('can be checked once the user has seen them', () {
      final state = ReviewState.initial([ai()]);
      expect(state.checkedCount, 0);
      expect(state.rows.single.isCheckable, isTrue, reason: 'has amount+type');
      expect(state.toggle(0, checked: true).checkedCount, 1);
    });

    test('editing the amount overrides the AI value', () {
      var state = ReviewState.initial([ai()]);
      state = state.editAmount(0, 123456);
      expect(state.rows.single.effectiveCents, 123456);
      expect(state.rows.single.checked, isTrue);
    });
  });

  group('failed rows become checkable once filled in', () {
    test('a failed row starts unchecked and uncheckable', () {
      final state = ReviewState.initial([failed()]);
      expect(state.rows.single.isCheckable, isFalse);
      expect(state.checkedCount, 0);
    });

    test('every row is money in — a failed row needs only an amount', () {
      var state = ReviewState.initial([failed()]);
      expect(state.rows.single.effectiveType, TxType.credit);
      state = state.editAmount(0, 500000);

      expect(state.rows.single.isCheckable, isTrue);
      expect(state.rows.single.checked, isTrue);
      expect(state.checkedCount, 1);
      expect(state.saveLabel, 'Approve 1 transaction');
    });

    test('clearing the amount un-checks it again', () {
      var state = ReviewState.initial([failed()]);
      state = state.editAmount(0, 500000);
      expect(state.checkedCount, 1);

      // Emptying the box must genuinely clear, not keep the old value.
      state = state.editAmount(0, null);
      expect(state.rows.single.effectiveCents, isNull);
      expect(state.rows.single.isCheckable, isFalse);
      expect(state.checkedCount, 0);
    });

    test('zero is not a valid amount', () {
      var state = ReviewState.initial([failed()]);
      state = state.editAmount(0, 0);
      expect(state.rows.single.isCheckable, isFalse);
    });
  });

  group('effective reference', () {
    test('uses the parsed reference when present', () {
      final state = ReviewState.initial([ok()]);
      expect(state.rows.single.effectiveReference(), 'FT26195XKQ8T');
    });

    test('uses the typed reference when the user supplies one', () {
      var state = ReviewState.initial([ai()]);
      state = state.editReference(0, 'FT99999999999');
      expect(state.rows.single.effectiveReference(), 'FT99999999999');
    });

    test('falls back to MANUAL-<uuid> when there is none', () {
      // aiParsed here has reference: null — an unreadable FT number.
      final row = ReviewState.initial([ai()]).rows.single;
      final ref = row.effectiveReference();
      expect(ref, startsWith('MANUAL-'));
      // Unique per call, since reference is the UNIQUE duplicate guard.
      expect(row.effectiveReference(), isNot(ref));
    });

    test('a blank typed reference still falls back to MANUAL-', () {
      var state = ReviewState.initial([ai()]);
      state = state.editReference(0, '   ');
      expect(state.rows.single.effectiveReference(), startsWith('MANUAL-'));
    });
  });

  group('counts for the summary line', () {
    test('duplicate and failed counts', () {
      final state = ReviewState.initial([
        ok(),
        ok(),
        dup(),
        dup(),
        dup(),
        failed(),
      ]);
      expect(state.duplicateCount, 3);
      expect(state.failedCount, 1);
      expect(state.checkedCount, 2);
    });
  });

  group('immutability', () {
    test('toggling returns a new state and leaves the original alone', () {
      final original = ReviewState.initial([ok()]);
      final toggled = original.toggle(0, checked: false);

      expect(original.checkedCount, 1);
      expect(toggled.checkedCount, 0);
      expect(identical(original, toggled), isFalse);
    });
  });

  group('approval summary', () {
    test('counts what was read, in either way, against the total', () {
      final state = ReviewState.initial([ok(), ai(), dup(), failed()]);
      expect(state.readCount, 3, reason: 'a duplicate was still read');
      expect(state.duplicateCount, 1);
      expect(state.failedCount, 1);
    });

    test('sums only the checked rows, in cents', () {
      var state = ReviewState.initial([
        ok(cents: 500000),
        // Whatever a receipt says, it is a payment in — it adds.
        ok(cents: 250000, type: TxType.debit),
        ai(cents: 100000), // starts unchecked
        dup(), // never counted
      ]);
      expect(state.totalCents, 750000);

      state = state.toggle(2, checked: true);
      expect(state.totalCents, 850000);

      state = state.toggle(0, checked: false);
      expect(state.totalCents, 350000);
    });

    test('a filled-in failed row joins the sum', () {
      var state = ReviewState.initial([failed()]);
      expect(state.totalCents, 0);
      state = state.editAmount(0, 75000);
      expect(state.totalCents, 75000);
    });
  });

  group('transactionDateFor', () {
    final now = DateTime(2026, 9, 17, 21, 5, 9);

    test("the chosen day wins over the receipt's date, keeping its time", () {
      final date = transactionDateFor(
        day: DateTime(2026, 9, 16),
        parsed: DateTime(2026, 9, 10, 14, 30, 5),
        now: now,
      );
      expect(date, DateTime(2026, 9, 16, 14, 30, 5));
    });

    test('no receipt time and today → the current time', () {
      final date = transactionDateFor(
        day: DateTime(2026, 9, 17),
        parsed: null,
        now: now,
      );
      expect(date, DateTime(2026, 9, 17, 21, 5, 9));
    });

    test('no receipt time and another day → noon', () {
      final date = transactionDateFor(
        day: DateTime(2026, 9, 1),
        parsed: null,
        now: now,
      );
      expect(date, DateTime(2026, 9, 1, 12));
    });
  });

  group('reference collisions', () {
    test('two checked rows sharing a reference block the save', () {
      final state = ReviewState.initial([
        BulkItem.ok(image, parsed(reference: 'FT26SAME')),
        BulkItem.ok(image, parsed(reference: 'FT26SAME')),
      ]);
      expect(state.conflictingReference, 'FT26SAME');
      expect(state.canSave, isFalse);
      // Unticking one clears it.
      final fixed = state.toggle(1, checked: false);
      expect(fixed.conflictingReference, isNull);
      expect(fixed.canSave, isTrue);
    });

    test('a manual reference typed to match another row is caught', () {
      var state = ReviewState.initial([
        BulkItem.ok(image, parsed(reference: 'FT26AAAA')),
        failed(),
      ]);
      state = state.editAmount(1, 1000);
      state = state.editReference(1, 'FT26AAAA');
      expect(state.checkedCount, 2);
      expect(state.conflictingReference, 'FT26AAAA');
      expect(state.canSave, isFalse);
    });
  });
}
