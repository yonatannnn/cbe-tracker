/// Riverpod wiring for the OCR / AI / pipeline services (§6).
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/db/database_provider.dart';
import 'backup_service.dart';
import 'cloud_backup_service.dart';
import 'gemini_fallback_service.dart';
import 'image_store.dart';
import 'ocr_service.dart';
import 'parse_pipeline.dart';
import 'supabase_config.dart';

final ocrServiceProvider = Provider<OcrService>((ref) {
  final service = MlKitOcrService();
  ref.onDispose(service.dispose); // close the native recognizer
  return service;
});

final aiFallbackProvider = Provider<CbeAiFallback>(
  (ref) => GeminiFallbackService(),
);

final parsePipelineProvider = Provider<ParsePipeline>(
  (ref) => ParsePipeline(
    ocr: ref.watch(ocrServiceProvider),
    ai: ref.watch(aiFallbackProvider),
  ),
);

/// The branch to pre-select in the add flow: the most recently used one
/// (§FR-2), or null on first use.
final lastBranchIdProvider = StreamProvider<int?>(
  (ref) => ref.watch(settingsDaoProvider).watchLastBranchId(),
);

/// The app documents directory — where the database and screenshots live.
///
/// Resolving it is async, so main() looks it up once and overrides this;
/// nothing downstream has to await a directory. Throwing here rather than
/// returning a guess means a missing override fails loudly at startup instead
/// of silently writing images somewhere the backup will never find them.
final appDocsDirProvider = Provider<Directory>(
  (ref) => throw UnimplementedError('appDocsDirProvider must be overridden'),
);

final imageStoreProvider = Provider<ImageStore>(
  (ref) => ImageStore(ref.watch(appDocsDirProvider)),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    db: ref.watch(appDatabaseProvider),
    store: ref.watch(imageStoreProvider),
  ),
);

/// The Supabase-backed cloud seam, or null when no project is configured. Only
/// touches `Supabase.instance` when configured, so an un-configured build (and
/// every widget test) never initialises the client.
final cloudBackendProvider = Provider<CloudBackend?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  return SupabaseCloudBackend(Supabase.instance.client);
});

/// Cloud backup, or null when the feature is dormant. The UI hides itself and
/// the startup trigger no-ops on null.
final cloudBackupServiceProvider = Provider<CloudBackupService?>((ref) {
  final backend = ref.watch(cloudBackendProvider);
  if (backend == null) return null;
  return CloudBackupService(
    backend: backend,
    backup: ref.watch(backupServiceProvider),
    settings: ref.watch(settingsDaoProvider),
  );
});

/// The signed-in email, live — null when signed out or cloud is not configured.
/// Yields the current value first, then follows sign-in / sign-out.
final cloudAuthEmailProvider = StreamProvider<String?>((ref) async* {
  final service = ref.watch(cloudBackupServiceProvider);
  if (service == null) {
    yield null;
    return;
  }
  yield service.email;
  yield* service.authChanges();
});
