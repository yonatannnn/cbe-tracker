/// Cloud backup — an off-device copy of the local backup zip (Phase 10).
///
/// The design is deliberately thin: it reuses [BackupService], which already
/// builds and restores the exact sqlite-plus-screenshots zip, and only adds
/// "put this file in the cloud" and "get the latest one back". Nothing about
/// the money data is re-modelled for the network, so there is no sync or
/// conflict logic that could corrupt the books — the cloud holds whole,
/// self-contained snapshots, newest wins.
///
/// The Supabase calls sit behind [CloudBackend] so the orchestration here is
/// testable without a live project; [SupabaseCloudBackend] is the real seam.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/db/daos/settings_dao.dart';
import 'backup_service.dart';

class CloudBackupException implements Exception {
  CloudBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One backup file sitting in the owner's cloud area.
class CloudBackupEntry {
  const CloudBackupEntry({required this.name, this.createdAt});

  final String name;
  final DateTime? createdAt;
}

/// The cloud operations the service needs, behind a seam. A real implementation
/// talks to Supabase; tests use a fake, so the upload/restore orchestration is
/// verified without a network.
abstract class CloudBackend {
  /// The signed-in owner's email, or null when signed out.
  String? get signedInEmail;

  /// Emits the current email on subscribe, then on every sign-in / sign-out.
  Stream<String?> authChanges();

  Future<void> signIn(String email, String password);
  Future<void> signUp(String email, String password);
  Future<void> signOut();

  /// Uploads [bytes] as [fileName] in the owner's private area, replacing any
  /// existing file of the same name.
  Future<void> upload(String fileName, List<int> bytes);

  /// The owner's backup files (order not guaranteed — the caller sorts).
  Future<List<CloudBackupEntry>> list();

  Future<List<int>> download(String fileName);
}

/// Talks to Supabase Storage + Auth. Every path is prefixed with the signed-in
/// user's id, and the bucket's row-level rules only let a user touch their own
/// folder — so the folder prefix is enforced by the server, not just trusted
/// here.
class SupabaseCloudBackend implements CloudBackend {
  SupabaseCloudBackend(this._client);

  final SupabaseClient _client;

  static const String bucket = 'backups';

  @override
  String? get signedInEmail => _client.auth.currentUser?.email;

  @override
  Stream<String?> authChanges() =>
      _client.auth.onAuthStateChange.map((state) => state.session?.user.email);

  @override
  Future<void> signIn(String email, String password) async {
    try {
      await _client.auth
          .signInWithPassword(email: email, password: password);
    } on AuthException catch (e) {
      throw CloudBackupException(e.message);
    }
  }

  @override
  Future<void> signUp(String email, String password) async {
    try {
      await _client.auth.signUp(email: email, password: password);
    } on AuthException catch (e) {
      throw CloudBackupException(e.message);
    }
  }

  @override
  Future<void> signOut() => _client.auth.signOut();

  String get _uid {
    final id = _client.auth.currentUser?.id;
    if (id == null) throw CloudBackupException('Not signed in.');
    return id;
  }

  @override
  Future<void> upload(String fileName, List<int> bytes) async {
    try {
      await _client.storage.from(bucket).uploadBinary(
            '$_uid/$fileName',
            Uint8List.fromList(bytes),
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'application/zip',
            ),
          );
    } on StorageException catch (e) {
      throw CloudBackupException(e.message);
    }
  }

  @override
  Future<List<CloudBackupEntry>> list() async {
    try {
      final objects = await _client.storage.from(bucket).list(path: _uid);
      return objects
          .where((o) => o.name.endsWith('.zip'))
          .map(
            (o) => CloudBackupEntry(
              name: o.name,
              createdAt:
                  o.createdAt == null ? null : DateTime.tryParse(o.createdAt!),
            ),
          )
          .toList();
    } on StorageException catch (e) {
      throw CloudBackupException(e.message);
    }
  }

  @override
  Future<List<int>> download(String fileName) async {
    try {
      return await _client.storage.from(bucket).download('$_uid/$fileName');
    } on StorageException catch (e) {
      throw CloudBackupException(e.message);
    }
  }
}

class CloudBackupService {
  CloudBackupService({
    required this.backend,
    required this.backup,
    required this.settings,
  });

  final CloudBackend backend;
  final BackupService backup;
  final SettingsDao settings;

  /// The automatic path skips a backup taken within this window, so opening the
  /// app several times a day doesn't re-upload the same data repeatedly.
  static const Duration autoInterval = Duration(hours: 20);

  bool get isSignedIn => backend.signedInEmail != null;
  String? get email => backend.signedInEmail;

  Stream<String?> authChanges() => backend.authChanges();

  Future<void> signIn(String email, String password) =>
      backend.signIn(email, password);
  Future<void> signUp(String email, String password) =>
      backend.signUp(email, password);
  Future<void> signOut() => backend.signOut();

  Future<DateTime?> lastBackupAt() => settings.getLastCloudBackup();

  /// Builds the current backup zip and uploads it, recording the time so the
  /// automatic path knows when it last succeeded.
  Future<void> backupNow(DateTime now) async {
    if (!isSignedIn) {
      throw CloudBackupException('Sign in to back up to the cloud.');
    }
    final zip = await backup.export();
    final bytes = await zip.readAsBytes();
    await backend.upload(_fileName(now), bytes);
    await settings.setLastCloudBackup(now);
  }

  /// Uploads only when signed in and it's been [autoInterval] since the last
  /// success. Returns whether it uploaded. Never throws — an opportunistic
  /// backup that fails (offline, say) must not disrupt app startup; the next
  /// launch tries again.
  Future<bool> maybeAutoBackup(DateTime now) async {
    if (!isSignedIn) return false;
    final last = await settings.getLastCloudBackup();
    if (last != null && now.difference(last) < autoInterval) return false;
    try {
      await backupNow(now);
      return true;
    } on Object {
      return false;
    }
  }

  Future<List<CloudBackupEntry>> list() => backend.list();

  /// Downloads the newest backup and REPLACES local data with it.
  Future<void> restoreLatest() async {
    final entries = await list();
    if (entries.isEmpty) {
      throw CloudBackupException('No cloud backups found for this account.');
    }
    // Filenames are timestamped and zero-padded, so lexicographic order is
    // chronological — greatest name is newest. Independent of the server's
    // listing order, and of clock skew on createdAt.
    entries.sort((a, b) => b.name.compareTo(a.name));
    final bytes = await backend.download(entries.first.name);

    final temp = await getTemporaryDirectory();
    final file = File('${temp.path}/cloud_restore.zip');
    await file.writeAsBytes(bytes, flush: true);
    // Reuses the validated local restore: it checks the zip before touching
    // anything and swaps the database in atomically.
    await backup.restore(file);
  }

  /// Zero-padded to the second so same-day backups never collide and names sort
  /// chronologically.
  static String _fileName(DateTime now) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'CBETracker_${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.zip';
  }
}
