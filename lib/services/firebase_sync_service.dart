/// Mirrors the books to Firestore: users/{name}/branches/{id}/transactions.
///
/// The phone's SQLite stays the source of truth (§3). Every save that goes
/// through Approve, the single-add confirm, an edit, a delete, or branch
/// management is pushed here as well — best-effort, never blocking the UI,
/// and never throwing into it. Firestore keeps its own offline queue, so a
/// write made without signal lands when the signal returns.
///
/// Layout, as asked for: the user's NAME is the root document, branches sit
/// under it, transactions under each branch. Transaction documents are keyed
/// by reference, so the cloud dedupes exactly as the phone does (§FR-2).
///
///   users/{userKey}                       {name, profileId, updatedAt}
///     branches/{branchId}                 {name, archived, createdAt}
///       transactions/{reference}          {amountCents, reference, …}
///
/// Sign-in is anonymous: the rules only require a signed-in device. The data
/// is filed by name, not by device, so a reinstall or a second phone typing
/// the same name writes to the same books.
library;

import 'package:cloud_firestore/cloud_firestore.dart' hide Transaction;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import '../data/db/database.dart';
import '../data/profiles/profile_store.dart';
import 'parse_diagnostics.dart';

/// The Firestore document id for a user's name: "Sosina Tilahun" →
/// "sosina_tilahun". Case and spacing don't create a second set of books,
/// matching how the welcome screen treats names.
String firestoreUserKey(String name) {
  final key = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9ሀ-፿]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return key.isEmpty ? 'user' : key;
}

/// A transaction as stored in Firestore. Integer cents, ISO-8601 dates in
/// UTC, and the same reference the phone dedupes on.
Map<String, Object?> transactionToDoc(Transaction tx) => {
  'localId': tx.id,
  'branchId': tx.branchId,
  'amountCents': tx.amountCents,
  'type': tx.type.name,
  'reference': tx.reference,
  'source': tx.source.name,
  'transactionDate': tx.transactionDate.toUtc().toIso8601String(),
  'createdAt': tx.createdAt.toUtc().toIso8601String(),
  'ocrText': tx.ocrText,
};

Map<String, Object?> branchToDoc(Branch branch) => {
  'localId': branch.id,
  'name': branch.name,
  'archived': branch.archived,
  'createdAt': branch.createdAt.toUtc().toIso8601String(),
};

class FirebaseSyncService {
  FirebaseSyncService({
    required this.firestore,
    required this.auth,
    this.diagnostic = logParseDiagnostic,
  });

  final FirebaseFirestore firestore;
  final FirebaseAuth auth;
  final ParseDiagnostic diagnostic;

  /// True once `Firebase.initializeApp` has run — i.e. the build carries a
  /// generated `firebase_options.dart`. Without it the service is absent and
  /// every hook is a no-op.
  static bool get isAvailable => Firebase.apps.isNotEmpty;

  Future<void> _signIn() async {
    if (auth.currentUser != null) return;
    await auth.signInAnonymously();
  }

  DocumentReference<Map<String, dynamic>> _user(Profile profile) =>
      firestore.collection('users').doc(firestoreUserKey(profile.name));

  DocumentReference<Map<String, dynamic>> _branch(Profile profile, int id) =>
      _user(profile).collection('branches').doc('$id');

  /// Runs [body] with the user document guaranteed to exist. Every failure
  /// is logged and swallowed: the money is already on the phone.
  Future<bool> _guarded(
    String what,
    Profile profile,
    Future<void> Function() body,
  ) async {
    try {
      await _signIn();
      await _user(profile).set({
        'name': profile.name,
        'profileId': profile.id,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await body();
      diagnostic('cloud $what ok');
      return true;
    } on Object catch (error) {
      // Type only — the message could carry paths or ids.
      diagnostic('cloud $what failed: ${error.runtimeType}');
      return false;
    }
  }

  Future<bool> upsertBranch(Profile profile, Branch branch) => _guarded(
    'branch',
    profile,
    () => _branch(profile, branch.id).set({
      ...branchToDoc(branch),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true)),
  );

  /// A branch removed on the phone (it had no transactions, §FR-1).
  Future<bool> deleteBranch(Profile profile, int branchId) => _guarded(
    'branch delete',
    profile,
    () => _branch(profile, branchId).delete(),
  );

  /// Writes every row in one batch; each is keyed by its reference.
  Future<bool> upsertTransactions(
    Profile profile,
    List<Transaction> transactions,
  ) {
    if (transactions.isEmpty) return Future.value(true);
    return _guarded('transactions', profile, () async {
      // Firestore batches cap at 500 writes.
      for (var i = 0; i < transactions.length; i += 400) {
        final batch = firestore.batch();
        for (final tx in transactions.skip(i).take(400)) {
          batch.set(
            _branch(
              profile,
              tx.branchId,
            ).collection('transactions').doc(tx.reference),
            {
              ...transactionToDoc(tx),
              'updatedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
      }
    });
  }

  Future<bool> deleteTransaction(Profile profile, Transaction tx) => _guarded(
    'transaction delete',
    profile,
    () => _branch(
      profile,
      tx.branchId,
    ).collection('transactions').doc(tx.reference).delete(),
  );

  /// Pushes everything on the phone for this user — the first time the
  /// cloud is switched on, and the "Sync now" button in Settings.
  Future<bool> syncAll(Profile profile, AppDatabase db) async {
    final branches = await db.select(db.branches).get();
    final transactions = await db.select(db.transactions).get();
    var ok = true;
    for (final branch in branches) {
      ok &= await upsertBranch(profile, branch);
    }
    ok &= await upsertTransactions(profile, transactions);
    return ok;
  }
}
