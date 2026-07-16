/// Relocates screenshots that were saved into the cache directory (§2).
///
/// Early builds stored image_picker's cache path straight into the database.
/// Those files are one storage-purge away from deletion, so on launch we copy
/// any that still exist into the documents directory and rewrite the row to a
/// relative path.
///
/// Runs once per launch and is cheap when there's nothing to do: it only looks
/// at rows whose path is still absolute.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;

import '../data/db/database.dart';
import 'image_store.dart';

class ImageMigration {
  ImageMigration({required this.db, required this.store});

  final AppDatabase db;
  final ImageStore store;

  /// Returns (rescued, lost): images copied to safety, and rows whose cached
  /// file the OS had already deleted.
  Future<({int rescued, int lost})> run() async {
    final rows = await db.select(db.transactions).get();
    var rescued = 0;
    var lost = 0;

    for (final tx in rows) {
      final path = tx.screenshotPath;
      // Relative paths are already safe; null means there was never an image.
      if (path == null || path.isEmpty || !path.startsWith('/')) continue;

      final source = File(path);
      if (!source.existsSync()) {
        // The cache was purged before we got here. Clear the dead path so the
        // UI shows "no image" rather than a broken file.
        await db.transactionDao.updateTransaction(
          tx.id,
          const TransactionsCompanion(screenshotPath: Value(null)),
        );
        lost++;
        continue;
      }

      final relative = await store.save(source);
      if (relative == null) continue; // leave it; try again next launch
      await db.transactionDao.updateTransaction(
        tx.id,
        TransactionsCompanion(screenshotPath: Value(relative)),
      );
      rescued++;
    }

    return (rescued: rescued, lost: lost);
  }
}
