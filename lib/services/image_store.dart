/// Durable storage for screenshot evidence (§2).
///
/// image_picker hands back a path inside the app's CACHE directory, which
/// Android purges under storage pressure and "Clear cache" wipes on demand.
/// Saving that path meant the evidence images were disposable and the backup
/// would have archived files the OS could delete at any moment.
///
/// Images are copied into the documents directory and the database stores a
/// RELATIVE path, so a restore onto another install still resolves.
library;

import 'dart:io';

import '../core/ids.dart';

class ImageStore {
  ImageStore(this.documentsDir);

  final Directory documentsDir;

  static const String subdirectory = 'screenshots';

  Directory get _dir => Directory('${documentsDir.path}/$subdirectory');

  /// Copies [source] into the documents directory.
  ///
  /// Returns the relative path to store, or null when the copy fails — the
  /// caller saves the transaction regardless, because the amount matters more
  /// than the picture.
  Future<String?> save(File source) async {
    try {
      if (!_dir.existsSync()) await _dir.create(recursive: true);
      final extension = _extensionOf(source.path);
      final relative = '$subdirectory/${uuidV4()}$extension';
      await source.copy('${documentsDir.path}/$relative');
      return relative;
    } on FileSystemException {
      return null;
    }
  }

  /// Resolves a stored path to a real file.
  ///
  /// Accepts absolute paths too: rows written before this existed hold an
  /// absolute cache path, and those images should keep rendering until the
  /// migration relocates them (or the OS deletes them).
  File? resolve(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    if (stored.startsWith('/')) return File(stored);
    return File('${documentsDir.path}/$stored');
  }

  /// Deletes a stored image, ignoring one that's already gone.
  Future<void> delete(String? stored) async {
    final file = resolve(stored);
    if (file == null) return;
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // Best-effort; a leftover image must never fail a delete.
    }
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot == -1 || dot < path.lastIndexOf('/')) return '.jpg';
    final extension = path.substring(dot).toLowerCase();
    return extension.length <= 5 ? extension : '.jpg';
  }
}
