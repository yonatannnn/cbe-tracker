// §2: screenshots are the evidence behind every number in the ledger. These
// tests pin the two properties that make them survivable — the file leaves the
// cache, and the stored path is relative so it still resolves after a restore
// onto a different install.

import 'dart:io';

import 'package:cbe_tracker/core/parser/cbe_parser.dart';
import 'package:cbe_tracker/data/db/database.dart';
import 'package:cbe_tracker/data/db/tables.dart';
import 'package:cbe_tracker/services/image_migration.dart';
import 'package:cbe_tracker/services/image_store.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory docs;
  late Directory cache;
  late ImageStore store;

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('cbe_docs');
    cache = await Directory.systemTemp.createTemp('cbe_cache');
    store = ImageStore(docs);
  });

  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
    if (cache.existsSync()) cache.deleteSync(recursive: true);
  });

  Future<File> pickedImage([String name = 'shot.jpg']) async {
    final file = File('${cache.path}/$name');
    await file.writeAsBytes([9, 8, 7]);
    return file;
  }

  group('save', () {
    test('returns a relative path, never an absolute one', () async {
      final stored = await store.save(await pickedImage());
      // The whole point: an absolute path is wrong even if it works today,
      // because the sandbox path changes on reinstall and restore.
      expect(stored, isNotNull);
      expect(stored!.startsWith('/'), isFalse);
      expect(stored, startsWith('screenshots/'));
    });

    test('copies the bytes into the documents dir', () async {
      final stored = await store.save(await pickedImage());
      final landed = File('${docs.path}/$stored');
      expect(landed.existsSync(), isTrue);
      expect(await landed.readAsBytes(), [9, 8, 7]);
    });

    test('leaves the original alone — the cache copy is the OS\'s to delete',
        () async {
      final source = await pickedImage();
      await store.save(source);
      expect(source.existsSync(), isTrue);
    });

    test('two images with the same filename both survive', () async {
      // image_picker reuses names like "image_picker1234.jpg"; a collision
      // would silently overwrite one receipt's evidence with another's.
      final a = await store.save(await pickedImage('shot.jpg'));
      await File('${cache.path}/shot.jpg').writeAsBytes([1, 1, 1]);
      final b = await store.save(File('${cache.path}/shot.jpg'));

      expect(a, isNot(b));
      expect(await File('${docs.path}/$a').readAsBytes(), [9, 8, 7]);
      expect(await File('${docs.path}/$b').readAsBytes(), [1, 1, 1]);
    });

    test('keeps the extension so the decoder gets a hint', () async {
      final png = File('${cache.path}/a.PNG')..writeAsBytesSync([1]);
      expect(await store.save(png), endsWith('.png'));
    });

    test('a missing source returns null rather than throwing', () async {
      // The amount matters more than the picture: a failed copy must not lose
      // the transaction.
      expect(await store.save(File('${cache.path}/gone.jpg')), isNull);
    });
  });

  group('resolve', () {
    test('a relative path resolves under the current documents dir', () async {
      final stored = await store.save(await pickedImage());
      expect(store.resolve(stored)!.path, '${docs.path}/$stored');
    });

    test('resolves against wherever the app lives now, not where it was',
        () async {
      final stored = await store.save(await pickedImage());
      // Simulates the restore/reinstall case: same relative path, new sandbox.
      final elsewhere = ImageStore(Directory('/new/sandbox'));
      expect(elsewhere.resolve(stored)!.path, '/new/sandbox/$stored');
    });

    test('a legacy absolute path is passed through', () {
      // Rows written before ImageStore existed hold a cache path; they should
      // keep rendering until the migration relocates them.
      expect(store.resolve('/data/cache/old.jpg')!.path, '/data/cache/old.jpg');
    });

    test('null and empty mean no image', () {
      expect(store.resolve(null), isNull);
      expect(store.resolve(''), isNull);
    });
  });

  group('migration (rescues what older builds put in the cache)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() => db.close());

    Future<int> insertTx(String? path, {String reference = 'FT26195XKQ8T'}) {
      return db.transactionDao.insertIfNew(
        TransactionsCompanion.insert(
          branchId: 1,
          amountCents: 1000,
          type: TxType.credit,
          reference: reference,
          source: TxSource.screenshot,
          transactionDate: DateTime(2026, 7, 14),
          screenshotPath: Value(path),
        ),
      ).then((_) => 0);
    }

    Future<List<Transaction>> allTx() => db.select(db.transactions).get();

    setUp(() async => db.branchDao.createBranch('Bole'));

    test('an existing cached image is copied and the row rewritten', () async {
      final cached = await pickedImage();
      await insertTx(cached.path);

      final result = await ImageMigration(db: db, store: store).run();

      expect(result.rescued, 1);
      expect(result.lost, 0);
      final path = (await allTx()).single.screenshotPath!;
      expect(path.startsWith('/'), isFalse);
      expect(await File('${docs.path}/$path').readAsBytes(), [9, 8, 7]);
    });

    test('a cached image the OS already purged clears the dead path',
        () async {
      // Showing a broken-image box forever is worse than admitting it's gone.
      await insertTx('${cache.path}/purged.jpg');

      final result = await ImageMigration(db: db, store: store).run();

      expect(result.lost, 1);
      expect((await allTx()).single.screenshotPath, isNull);
    });

    test('rows already relative are left untouched', () async {
      await insertTx('screenshots/already-safe.jpg');
      final result = await ImageMigration(db: db, store: store).run();
      expect(result, (rescued: 0, lost: 0));
      expect((await allTx()).single.screenshotPath, 'screenshots/already-safe.jpg');
    });

    test('rows with no image are ignored', () async {
      await insertTx(null);
      final result = await ImageMigration(db: db, store: store).run();
      expect(result, (rescued: 0, lost: 0));
    });

    test('a second run does nothing — it is safe on every launch', () async {
      await insertTx((await pickedImage()).path);
      await ImageMigration(db: db, store: store).run();

      final second = await ImageMigration(db: db, store: store).run();

      expect(second, (rescued: 0, lost: 0));
      // And it didn't duplicate the image on disk.
      final dir = Directory('${docs.path}/${ImageStore.subdirectory}');
      expect(dir.listSync().length, 1);
    });

    test('a mixed ledger reports both counts', () async {
      await insertTx((await pickedImage('a.jpg')).path, reference: 'FT26195AAA1A');
      await insertTx('${cache.path}/purged.jpg', reference: 'FT26195BBB2B');
      await insertTx(null, reference: 'FT26195CCC3C');
      await insertTx('screenshots/safe.jpg', reference: 'FT26195DDD4D');

      final result = await ImageMigration(db: db, store: store).run();

      expect(result, (rescued: 1, lost: 1));
    });
  });
}
