/// ML Kit text-recognition wrapper (§6). On-device, no network (§2).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

/// Seam so the parse pipeline can be tested without ML Kit.
abstract class OcrService {
  /// Returns all text found in [image], or an empty string when none.
  Future<String> extractText(File image);

  /// Releases native resources.
  Future<void> dispose();
}

/// Real on-device OCR via Google ML Kit (Latin script — CBE messages are
/// English, §2).
class MlKitOcrService implements OcrService {
  MlKitOcrService();

  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  /// Longest edge we feed ML Kit. Screenshots above this are downscaled to
  /// keep memory sane; smaller images are passed through untouched — we never
  /// upscale, since inventing pixels can only hurt recognition.
  ///
  /// 2800 on purpose: a modern phone screenshot is ~1080×2400, and the old
  /// 2000 cap put every single one through decode + Flutter's slow PNG
  /// re-encode + a temp file — half a second to two seconds per image that
  /// bought ML Kit nothing, times fifty in a bulk run. The guard now only
  /// catches genuinely huge imports (camera photos, scans).
  static const int _maxEdge = 2800;

  @override
  Future<String> extractText(File image) async {
    final prepared = await _downscaleIfHuge(image);
    try {
      final result = await _recognizer.processImage(
        InputImage.fromFile(prepared),
      );
      return result.text;
    } finally {
      // Only delete files we created ourselves.
      if (prepared.path != image.path) {
        try {
          await prepared.delete();
        } on FileSystemException {
          // Best-effort cleanup; a stale temp file must never fail OCR.
        }
      }
    }
  }

  /// Returns [image] unchanged when it's already within [_maxEdge], otherwise
  /// a downscaled temp copy. Any failure falls back to the original file.
  Future<File> _downscaleIfHuge(File image) async {
    try {
      final bytes = await image.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      final longest = math.max(width, height);

      if (longest <= _maxEdge) {
        descriptor.dispose();
        return image; // never upscale
      }

      final scale = _maxEdge / longest;
      final codec = await descriptor.instantiateCodec(
        targetWidth: (width * scale).round(),
        targetHeight: (height * scale).round(),
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      codec.dispose();
      descriptor.dispose();
      if (data == null) return image;

      final dir = await getTemporaryDirectory();
      final out = File(
        '${dir.path}/ocr_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await out.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return out;
    } on Object {
      // Decoding is best-effort: if anything goes wrong, OCR the original.
      return image;
    }
  }

  @override
  Future<void> dispose() => _recognizer.close();
}
