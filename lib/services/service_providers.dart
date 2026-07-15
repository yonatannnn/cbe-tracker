/// Riverpod wiring for the OCR / AI / pipeline services (§6).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db/database_provider.dart';
import 'gemini_fallback_service.dart';
import 'ocr_service.dart';
import 'parse_pipeline.dart';

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
