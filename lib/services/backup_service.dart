/// Backup export / import — the migration path to a new phone (§9).
///
/// Everything lives in one SQLite file plus a screenshots directory, so a
/// backup is those two things zipped. Local and offline on purpose: it works
/// with no signal, needs no account, and nothing leaves the device except when
/// the owner shares the file herself.
library;

import 'dart:io';

// archive_io for ZipFileEncoder, which streams entries to disk one at a time.
import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

import '../data/db/database.dart';
import 'image_store.dart';

/// What a restore is about to do, shown before it happens.
class BackupSummary {
  const BackupSummary({
    required this.branches,
    required this.transactions,
    required this.smsMessages,
    required this.images,
  });

  final int branches;
  final int transactions;
  final int smsMessages;
  final int images;
}

class BackupException implements Exception {
  BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupService {
  BackupService({required this.db, required this.store});

  final AppDatabase db;
  final ImageStore store;

  static const String _dbEntry = 'cbe_tracker.sqlite';

  File get _databaseFile =>
      File('${store.documentsDir.path}/$_dbEntry');

  /// Writes a zip of the database + screenshots and returns it.
  Future<File> export() async {
    // A no-op today: drift_flutter opens a plain NativeDatabase, so the
    // journal mode is `delete` and a closed transaction leaves everything in
    // the .sqlite file itself (verified — the device's documents dir holds no
    // -wal). Kept as a cheap guard in case the journal mode ever changes,
    // since the failure it prevents is a backup silently missing the newest
    // transactions.
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');

    final dbFile = _databaseFile;
    if (!dbFile.existsSync()) {
      throw BackupException('No database found to back up.');
    }

    final temp = await getTemporaryDirectory();
    final stamp = _stamp(DateTime.now());
    final out = File('${temp.path}/CBETracker_backup_$stamp.zip');

    // Streamed to disk one entry at a time. The old in-memory Archive held
    // every screenshot's bytes at once (raw AND compressed) — and since the
    // cloud auto-backup runs this on every launch, a few months of daily
    // screenshots would have had startup itself OOM-killing the app.
    final encoder = ZipFileEncoder();
    encoder.create(out.path);
    try {
      await encoder.addFile(dbFile, _dbEntry);
      final imagesDir = Directory(
        '${store.documentsDir.path}/${ImageStore.subdirectory}',
      );
      if (imagesDir.existsSync()) {
        for (final entity in imagesDir.listSync()) {
          if (entity is! File) continue;
          final name = entity.uri.pathSegments.last;
          await encoder.addFile(entity, '${ImageStore.subdirectory}/$name');
        }
      }
    } finally {
      await encoder.close();
    }
    return out;
  }

  /// Reads a backup without applying it, so the UI can say what's inside.
  Future<BackupSummary> inspect(File zip) async {
    final archive = _openArchive(zip);
    final dbEntry = archive.findFile(_dbEntry);
    if (dbEntry == null) {
      throw BackupException(
        "That zip isn't a CBE Tracker backup — no database inside.",
      );
    }

    // Open the incoming database read-only from a scratch copy: never point a
    // half-trusted file at the live one.
    final temp = await getTemporaryDirectory();
    final probe = File('${temp.path}/restore_probe.sqlite');
    await probe.writeAsBytes(dbEntry.content as List<int>, flush: true);

    final images = archive.files
        .where(
          (f) => f.isFile && f.name.startsWith('${ImageStore.subdirectory}/'),
        )
        .length;

    try {
      final incoming = AppDatabase.forTesting(NativeDatabase(probe));
      final counts = await Future.wait([
        _count(incoming, 'branches'),
        _count(incoming, 'transactions'),
        _count(incoming, 'sms_transactions'),
      ]);
      await incoming.close();
      return BackupSummary(
        branches: counts[0],
        transactions: counts[1],
        smsMessages: counts[2],
        images: images,
      );
    } on Object {
      throw BackupException('That backup file is damaged or unreadable.');
    } finally {
      if (probe.existsSync()) await probe.delete();
    }
  }

  /// REPLACES all current data with the backup's.
  ///
  /// The caller must rebuild the database provider afterwards: every open
  /// stream and DAO is bound to the file this replaces.
  Future<void> restore(File zip) async {
    // Validate before touching anything on disk — a restore that fails must
    // leave her existing books exactly as they were.
    final archive = _openArchive(zip);
    final dbEntry = archive.findFile(_dbEntry);
    if (dbEntry == null) {
      throw BackupException(
        "That zip isn't a CBE Tracker backup — no database inside.",
      );
    }

    await db.close();

    // Stage the incoming database beside the live one, then swap it in with a
    // rename. rename() is atomic, which matters because closing Drift does not
    // stop it: a query arriving from a still-mounted screen silently REOPENS
    // the file (verified — use-after-close does not throw). Writing in place
    // would let such a reopen read a half-written database; with a rename it
    // either gets the old file or the complete new one, never a torn mix.
    final staged = File('${_databaseFile.path}.incoming');
    await staged.writeAsBytes(dbEntry.content as List<int>, flush: true);

    // Sidecars belong to the database being discarded. A clean close leaves
    // none, but a leftover journal would be replayed onto the restored file
    // and corrupt it.
    for (final suffix in const ['-journal', '-wal', '-shm']) {
      final sidecar = File('${_databaseFile.path}$suffix');
      if (sidecar.existsSync()) await sidecar.delete();
    }

    await staged.rename(_databaseFile.path);

    // Wipe existing screenshots so a restore is a true replace, not a merge
    // of two phones' images.
    final imagesDir = Directory(
      '${store.documentsDir.path}/${ImageStore.subdirectory}',
    );
    if (imagesDir.existsSync()) await imagesDir.delete(recursive: true);
    await imagesDir.create(recursive: true);

    for (final file in archive.files) {
      if (!file.isFile) continue;
      if (!file.name.startsWith('${ImageStore.subdirectory}/')) continue;
      final out = File('${store.documentsDir.path}/${file.name}');
      await out.writeAsBytes(file.content as List<int>, flush: true);
    }
  }

  Archive _openArchive(File zip) {
    try {
      return ZipDecoder().decodeBytes(zip.readAsBytesSync());
    } on Object {
      throw BackupException("That file isn't a readable zip.");
    }
  }

  static Future<int> _count(AppDatabase database, String table) async {
    final row = await database
        .customSelect('SELECT COUNT(*) AS c FROM $table')
        .getSingle();
    return row.read<int>('c');
  }

  static String _stamp(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}';
  }
}
