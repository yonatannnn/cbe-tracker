/// Riverpod wiring for the OCR / AI / pipeline services (§6).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/db/database_provider.dart';
import '../data/profiles/profile_provider.dart';
import 'backup_service.dart';
import 'cloud_backup_service.dart';
import 'gemini_fallback_service.dart';
import 'image_store.dart';
import 'ocr_service.dart';
import 'parse_pipeline.dart';
import 'supabase_config.dart';

export '../data/profiles/profile_provider.dart' show appDocsDirProvider;

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

/// Screenshots live in the ACTIVE USER's directory, beside her database, so
/// two users' evidence never mixes and a backup of one never carries the
/// other's images.
final imageStoreProvider = Provider<ImageStore>(
  (ref) => ImageStore(ref.watch(profileDirProvider)),
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
