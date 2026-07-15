/// Identifier helpers (pure Dart).
library;

import 'dart:math';

final _random = Random.secure();

/// RFC-4122 v4 UUID. Hand-rolled so we don't add a package beyond §5.
String uuidV4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 1
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Reference for manually entered transactions, where no FT number could be
/// read. Still satisfies the UNIQUE reference guard (§FR-2).
String manualReference() => 'MANUAL-${uuidV4()}';
