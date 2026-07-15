import 'package:cbe_tracker/core/ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uuidV4 has the right shape and version/variant bits', () {
    final id = uuidV4();
    expect(
      RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}$',
      ).hasMatch(id),
      isTrue,
      reason: 'got $id',
    );
  });

  test('manualReference is prefixed and unique', () {
    final refs = List.generate(500, (_) => manualReference());
    expect(refs.every((r) => r.startsWith('MANUAL-')), isTrue);
    // Uniqueness matters: reference is the UNIQUE duplicate guard (§FR-2).
    expect(refs.toSet().length, refs.length);
  });
}
