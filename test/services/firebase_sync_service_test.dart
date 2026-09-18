// The pure parts of the cloud mirror: how a name becomes a document id and
// how rows become documents. The Firestore calls themselves need a project.

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/firebase_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('firestoreUserKey', () {
    test('one document per person, whatever the spelling', () {
      expect(firestoreUserKey('Sosina Tilahun'), 'sosina_tilahun');
      expect(firestoreUserKey('  sosina   TILAHUN '), 'sosina_tilahun');
      expect(firestoreUserKey('Almaz'), 'almaz');
    });

    test('Amharic names are kept, punctuation is not', () {
      expect(firestoreUserKey('ሶስና ጥላሁን'), 'ሶስና_ጥላሁን');
      expect(firestoreUserKey('Mrs. Sosina / Piassa'), 'mrs_sosina_piassa');
    });

    test('never an empty id', () {
      expect(firestoreUserKey('  ...  '), 'user');
    });
  });

  test('a transaction document carries integer cents and UTC dates', () {
    final tx = Transaction(
      id: 7,
      branchId: 2,
      amountCents: 450000,
      type: TxType.credit,
      reference: 'AWASH-20260917152803-450000',
      source: TxSource.screenshot,
      transactionDate: DateTime(2026, 9, 17, 15, 28, 3),
      createdAt: DateTime(2026, 9, 18, 12, 0),
      ocrText: 'raw',
    );
    final doc = transactionToDoc(tx);
    expect(doc['amountCents'], 450000);
    expect(doc['type'], 'credit');
    expect(doc['reference'], 'AWASH-20260917152803-450000');
    expect(doc['branchId'], 2);
    expect(doc['transactionDate'], endsWith('Z'));
    expect(
      DateTime.parse(doc['transactionDate'] as String).toLocal(),
      DateTime(2026, 9, 17, 15, 28, 3),
    );
  });

  test('a branch document', () {
    final branch = Branch(
      id: 3,
      name: 'Piassa',
      archived: false,
      createdAt: DateTime(2026, 9, 17),
    );
    expect(branchToDoc(branch), {
      'localId': 3,
      'name': 'Piassa',
      'archived': false,
      'createdAt': DateTime(2026, 9, 17).toUtc().toIso8601String(),
    });
  });
}
