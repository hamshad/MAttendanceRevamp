import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/core/utils/aggressive_oem.dart';

void main() {
  group('AggressiveOem.isAggressiveBrand', () {
    test('MIUI/Xiaomi brands detected', () {
      expect(AggressiveOem.isAggressiveBrand('Xiaomi'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('Redmi'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('POCO'), isTrue);
    });

    test('other aggressive OEM families detected', () {
      expect(AggressiveOem.isAggressiveBrand('HONOR'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('Oppo'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('realme'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('OnePlus'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('vivo'), isTrue);
    });

    test('regular brands not detected', () {
      expect(AggressiveOem.isAggressiveBrand('samsung'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('Google'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('motorola'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('nokia'), isFalse);
      expect(AggressiveOem.isAggressiveBrand(''), isFalse);
    });

    test('manufacturer string with model suffix matched', () {
      // Native combines BRAND + MANUFACTURER, e.g. "Xiaomi Redmi Note 12".
      expect(AggressiveOem.isAggressiveBrand('Xiaomi Redmi Note 12'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('LGE Nexus 5'), isFalse);
    });
  });
}
