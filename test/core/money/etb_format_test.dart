import 'package:cbe_tracker/core/money/etb_format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatCents', () {
    test('zero', () {
      expect(formatCents(0), 'ETB 0.00');
    });

    test('sub-birr cents keep two fraction digits', () {
      expect(formatCents(5), 'ETB 0.05');
      expect(formatCents(50), 'ETB 0.50');
      expect(formatCents(99), 'ETB 0.99');
    });

    test('whole birr', () {
      expect(formatCents(100), 'ETB 1.00');
      expect(formatCents(85000), 'ETB 850.00');
    });

    test('thousands separator boundaries', () {
      expect(formatCents(99900), 'ETB 999.00');
      expect(formatCents(100000), 'ETB 1,000.00');
      expect(formatCents(14520000), 'ETB 145,200.00');
    });

    test('the 1,250,000.00 case', () {
      expect(formatCents(125000000), 'ETB 1,250,000.00');
    });

    test('negatives keep the sign attached', () {
      expect(formatCents(-500000), '−ETB 5,000.00');
      expect(formatCents(-5), '−ETB 0.05');
      expect(formatCents(-125000000), '−ETB 1,250,000.00');
    });
  });

  group('formatSignedCents', () {
    test('positive gets a plus', () {
      expect(formatSignedCents(500000), '+ ETB 5,000.00');
      expect(formatSignedCents(125000000), '+ ETB 1,250,000.00');
    });

    test('negative gets a minus sign (U+2212, not a hyphen)', () {
      expect(formatSignedCents(-500000), '− ETB 5,000.00');
      expect(formatSignedCents(-500000).codeUnitAt(0), 0x2212);
    });

    test('zero is unsigned', () {
      expect(formatSignedCents(0), 'ETB 0.00');
    });
  });

  group('parseCentsInput', () {
    test('accepts grouped, plain, and short-fraction input', () {
      expect(parseCentsInput('5,000.00'), 500000);
      expect(parseCentsInput('5000'), 500000);
      expect(parseCentsInput('850.5'), 85050);
      expect(parseCentsInput('0.05'), 5);
      expect(parseCentsInput('1,250,000.00'), 125000000);
      expect(parseCentsInput(' 5 000.00 '), 500000);
    });

    test('rejects junk rather than guessing', () {
      expect(parseCentsInput(''), isNull);
      expect(parseCentsInput('abc'), isNull);
      expect(parseCentsInput('5.000'), isNull); // 3 fraction digits
      expect(parseCentsInput('-5.00'), isNull);
      expect(parseCentsInput('5..0'), isNull);
    });

    test('round-trips through centsToInput', () {
      for (final cents in [0, 5, 85050, 500000, 125000000]) {
        expect(parseCentsInput(centsToInput(cents)), cents);
      }
    });
  });
}
