// §9: backup is the migration path to a new phone. The test that matters is
// the round trip — export, wipe, import, and the books are exactly as they
// were. Uses real files on disk, because the whole feature is about files.

import 'dart:io';

import 'package:archive/archive.dart';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/backup_service.dart';
import 'package:cbe_tracker/services/image_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// getTemporaryDirectory() has no implementation under `flutter test`.
class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.temp);

  final String temp;

  @override
  Future<String?> getTemporaryPath() async => temp;

  @override
  Future<String?> getApplicationDocumentsPath() async => temp;
}

void main() {
  late Directory docs;
  late AppDatabase db;
  late ImageStore store;
  late BackupService backup;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('cbe_backup_test');
    PathProviderPlatform.instance = _FakePaths(docs.path);
    // The real app opens this exact filename in the documents dir.
    db = AppDatabase.forTesting(
      NativeDatabase(File('${docs.path}/cbe_tracker.sqlite')),
    );
    store = ImageStore(docs);
    backup = BackupService(db: db, store: store);
  });

  tearDown(() async {
    await db.close();
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<void> seed() async {
    final bole = await db.branchDao.createBranch('Bole');
    await db.branchDao.createBranch('Cmc');
    await db.transactionDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: bole,
        amountCents: 500000,
        type: TxType.credit,
        reference: 'FT26195XKQ8T',
        source: TxSource.screenshot,
        transactionDate: DateTime(2026, 7, 14, 10, 42),
        screenshotPath: const Value('screenshots/photo.jpg'),
      ),
    );
    await db.transactionDao.insertIfNew(
      TransactionsCompanion.insert(
        branchId: bole,
        amountCents: 120000,
        type: TxType.debit,
        reference: 'FT26195YLR9U',
        source: TxSource.screenshot,
        transactionDate: DateTime(2026, 7, 14, 15, 0),
      ),
    );
    // A real evidence image on disk.
    final dir = Directory('${docs.path}/${ImageStore.subdirectory}');
    await dir.create(recursive: true);
    await File('${dir.path}/photo.jpg').writeAsBytes([1, 2, 3, 4, 5]);
  }

  group('round trip (§9 — the disaster-recovery path)', () {
    test('export → wipe → import restores books and images exactly', () async {
      await seed();
      final balanceBefore = await db.transactionDao
          .watchBalanceCents(1)
          .first;
      expect(balanceBefore, 380000);

      final zip = await backup.export();
      expect(zip.existsSync(), isTrue);
      expect(await zip.length(), greaterThan(0));

      // Wipe: exactly what a new phone looks like.
      await db.transactionDao.deleteTransaction(1);
      await db.transactionDao.deleteTransaction(2);
      await db.branchDao.deleteBranch(2);
      await File('${docs.path}/${ImageStore.subdirectory}/photo.jpg').delete();
      expect(await db.transactionDao.watchBalanceCents(1).first, 0);

      await backup.restore(zip);

      // restore() closes the database; the app reopens it on restart.
      final restored = AppDatabase.forTesting(
        NativeDatabase(File('${docs.path}/cbe_tracker.sqlite')),
      );
      expect(await restored.transactionDao.watchBalanceCents(1).first, 380000);
      expect((await restored.select(restored.branches).get()).length, 2);
      expect((await restored.select(restored.transactions).get()).length, 2);
      await restored.close();

      // The evidence image came back byte-for-byte.
      final image = File('${docs.path}/${ImageStore.subdirectory}/photo.jpg');
      expect(image.existsSync(), isTrue);
      expect(await image.readAsBytes(), [1, 2, 3, 4, 5]);

      // The test's own tearDown closes `db`, which restore() already closed.
      db = restored;
    });

    test('inspect reports what a restore would bring, without applying it',
        () async {
      await seed();
      final zip = await backup.export();

      final summary = await backup.inspect(zip);
      expect(summary.branches, 2);
      expect(summary.transactions, 2);
      expect(summary.images, 1);

      // Nothing was touched.
      expect(await db.transactionDao.watchBalanceCents(1).first, 380000);
    });
  });

  group('bad input is refused, not half-applied', () {
    /// A valid zip of the wrong thing — she picked holiday photos.
    File wrongZip() {
      final archive = Archive()
        ..addFile(ArchiveFile('holiday.jpg', 3, [1, 2, 3]));
      final file = File('${docs.path}/wrong.zip');
      file.writeAsBytesSync(ZipEncoder().encode(archive));
      return file;
    }

    test('a non-zip file is rejected', () async {
      final junk = File('${docs.path}/notazip.zip');
      await junk.writeAsString('this is not a zip');
      expect(() => backup.inspect(junk), throwsA(isA<BackupException>()));
    });

    test('a zip with no database is rejected', () async {
      expect(() => backup.inspect(wrongZip()), throwsA(isA<BackupException>()));
    });

    test('restoring the wrong zip leaves the books exactly as they were',
        () async {
      // The one destructive action in the app. If it refuses, it must refuse
      // BEFORE touching anything — a half-applied restore loses real money.
      await seed();

      await expectLater(
        backup.restore(wrongZip()),
        throwsA(isA<BackupException>()),
      );

      expect(await db.transactionDao.watchBalanceCents(1).first, 380000);
      expect(
        File('${docs.path}/${ImageStore.subdirectory}/photo.jpg').existsSync(),
        isTrue,
      );
    });

    test('restoring a corrupt file leaves the books exactly as they were',
        () async {
      await seed();
      final junk = File('${docs.path}/corrupt.zip');
      await junk.writeAsString('not a zip at all');

      await expectLater(backup.restore(junk), throwsA(isA<BackupException>()));

      expect(await db.transactionDao.watchBalanceCents(1).first, 380000);
    });
  });

  group('restore swaps the database file atomically', () {
    test('no staging file is left behind', () async {
      await seed();
      final zip = await backup.export();
      await backup.restore(zip);

      // A leftover .incoming would mean the rename never happened — the books
      // would look restored while the real file was untouched.
      expect(File('${docs.path}/cbe_tracker.sqlite.incoming').existsSync(),
          isFalse);

      db = AppDatabase.forTesting(
        NativeDatabase(File('${docs.path}/cbe_tracker.sqlite')),
      );
      expect(await db.transactionDao.watchBalanceCents(1).first, 380000);
    });

    test('a stale journal from the old database is removed', () async {
      await seed();
      final zip = await backup.export();
      // A journal left by a crash would be replayed onto the restored file and
      // corrupt it.
      await File('${docs.path}/cbe_tracker.sqlite-journal')
          .writeAsBytes([0, 1, 2]);

      await backup.restore(zip);

      expect(File('${docs.path}/cbe_tracker.sqlite-journal').existsSync(),
          isFalse);

      db = AppDatabase.forTesting(
        NativeDatabase(File('${docs.path}/cbe_tracker.sqlite')),
      );
      expect(await db.transactionDao.watchBalanceCents(1).first, 380000);
    });
  });

  group('export contents', () {
    test('includes the database even with no images', () async {
      await db.branchDao.createBranch('Bole');
      final zip = await backup.export();
      expect(zip.existsSync(), isTrue);

      final summary = await backup.inspect(zip);
      expect(summary.branches, 1);
      expect(summary.images, 0);
    });

    test('filename carries the date so backups sort and never collide',
        () async {
      await db.branchDao.createBranch('Bole');
      final zip = await backup.export();
      expect(zip.uri.pathSegments.last, startsWith('CBETracker_backup_'));
      expect(zip.uri.pathSegments.last, endsWith('.zip'));
    });
  });
}
