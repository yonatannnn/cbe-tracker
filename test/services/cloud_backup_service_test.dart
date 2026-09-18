// Cloud backup orchestration, verified without a live Supabase project: a fake
// [CloudBackend] stands in for the network, while the backup/restore underneath
// is the real thing — an in-memory database and real zip files on disk. So
// these prove the parts we wrote (when it uploads, what it records, that a
// restore round-trips) while the Supabase calls themselves are covered by the
// on-device test with a real project.

import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/backup_service.dart';
import 'package:cbe_tracker/services/cloud_backup_service.dart';
import 'package:cbe_tracker/services/image_store.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.temp);
  final String temp;
  @override
  Future<String?> getTemporaryPath() async => temp;
  @override
  Future<String?> getApplicationDocumentsPath() async => temp;
}

/// Stands in for Supabase Storage + Auth. Records what it was asked to do so
/// the tests can assert on it.
class _FakeBackend implements CloudBackend {
  _FakeBackend({this.email});

  String? email;
  final Map<String, List<int>> files = {};
  int uploads = 0;
  bool failUploads = false;
  String? lastDownloaded;

  @override
  String? get signedInEmail => email;
  @override
  Stream<String?> authChanges() => Stream.value(email);
  @override
  Future<void> signIn(String e, String p) async => email = e;
  @override
  Future<void> signUp(String e, String p) async => email = e;
  @override
  Future<void> signOut() async => email = null;

  @override
  Future<void> upload(String fileName, List<int> bytes) async {
    if (failUploads) throw CloudBackupException('offline');
    uploads++;
    files[fileName] = List<int>.of(bytes);
  }

  @override
  Future<List<CloudBackupEntry>> list() async =>
      files.keys.map((n) => CloudBackupEntry(name: n)).toList();

  @override
  Future<List<int>> download(String fileName) async {
    lastDownloaded = fileName;
    final b = files[fileName];
    if (b == null) throw CloudBackupException('not found');
    return b;
  }
}

void main() {
  late Directory docs;
  late AppDatabase db;
  late ImageStore store;
  late BackupService backup;
  late _FakeBackend backend;
  late CloudBackupService cloud;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('cbe_cloud_test');
    PathProviderPlatform.instance = _FakePaths(docs.path);
    db = AppDatabase.forTesting(
      NativeDatabase(File('${docs.path}/cbe_tracker.sqlite')),
    );
    store = ImageStore(docs);
    backup = BackupService(db: db, store: store);
    backend = _FakeBackend(email: 'owner@example.com');
    cloud = CloudBackupService(
      backend: backend,
      backup: backup,
      settings: db.settingsDao,
    );
  });

  tearDown(() async {
    await db.close();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<void> seedBole(int cents) async {
    final bole = await db.branchDao.createBranch('Bole');
    await db.transactionDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: bole,
        amountCents: cents,
        type: TxType.credit,
        reference: 'FT-$cents',
        source: TxSource.screenshot,
        transactionDate: DateTime(2026, 7, 14, 10),
      ),
    );
  }

  final t1 = DateTime(2026, 7, 15, 9);
  final t2 = DateTime(2026, 7, 16, 9);

  group('backupNow', () {
    test('uploads a real zip and records the time', () async {
      await seedBole(500000);
      expect(await db.settingsDao.getLastCloudBackup(), isNull);

      await cloud.backupNow(t1);

      expect(backend.uploads, 1);
      expect(backend.files.keys.single, endsWith('.zip'));
      expect(backend.files.values.single, isNotEmpty);
      expect(await db.settingsDao.getLastCloudBackup(), t1);
    });

    test('refuses when signed out', () async {
      backend.email = null;
      await expectLater(
        cloud.backupNow(t1),
        throwsA(isA<CloudBackupException>()),
      );
      expect(backend.uploads, 0);
    });
  });

  group('maybeAutoBackup', () {
    test('uploads when never backed up', () async {
      await seedBole(500000);
      expect(await cloud.maybeAutoBackup(t1), isTrue);
      expect(backend.uploads, 1);
    });

    test('skips when the last backup is within the window', () async {
      await seedBole(500000);
      await cloud.backupNow(t1);
      // 10 hours later — inside the 20h window.
      final didRun = await cloud.maybeAutoBackup(
        t1.add(const Duration(hours: 10)),
      );
      expect(didRun, isFalse);
      expect(backend.uploads, 1, reason: 'no second upload');
    });

    test('uploads again once the window has passed', () async {
      await seedBole(500000);
      await cloud.backupNow(t1);
      final didRun = await cloud.maybeAutoBackup(
        t1.add(const Duration(hours: 21)),
      );
      expect(didRun, isTrue);
      expect(backend.uploads, 2);
    });

    test('skips silently when signed out', () async {
      backend.email = null;
      expect(await cloud.maybeAutoBackup(t1), isFalse);
      expect(backend.uploads, 0);
    });

    test(
      'swallows an upload failure and leaves the timestamp untouched',
      () async {
        await seedBole(500000);
        backend.failUploads = true;
        expect(await cloud.maybeAutoBackup(t1), isFalse);
        expect(await db.settingsDao.getLastCloudBackup(), isNull);
      },
    );
  });

  group('restoreLatest', () {
    test('downloads the newest backup and replaces local data', () async {
      // First snapshot at 5,000; a later one at 9,000. Restore must bring back
      // the later state.
      await seedBole(500000);
      await cloud.backupNow(t1);

      await db.transactionDao.insertIfNew(
        TransactionsCompanion.insert(
          branchId: 1,
          amountCents: 400000,
          type: TxType.credit,
          reference: 'FT-EXTRA',
          source: TxSource.screenshot,
          transactionDate: DateTime(2026, 7, 16, 8),
        ),
      );
      await cloud.backupNow(t2); // now the cloud's newest holds 900000

      // Wipe to a fresh phone.
      await db.transactionDao.deleteTransaction(1);
      await db.transactionDao.deleteTransaction(2);
      expect(await db.transactionDao.watchBalanceCents(1).first, 0);

      await cloud.restoreLatest();

      // Picked the t2 file (lexicographically greatest name).
      expect(backend.lastDownloaded, contains('2026-07-16'));

      final restored = AppDatabase.forTesting(
        NativeDatabase(File('${docs.path}/cbe_tracker.sqlite')),
      );
      expect(await restored.transactionDao.watchBalanceCents(1).first, 900000);
      await restored.close();
      db = restored; // tearDown closes this
    });

    test('reports when there is nothing to restore', () async {
      await expectLater(
        cloud.restoreLatest(),
        throwsA(isA<CloudBackupException>()),
      );
    });
  });
}
