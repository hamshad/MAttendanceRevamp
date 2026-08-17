import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/core/utils/aggressive_oem.dart';

void main() {
  group('AggressiveOem.isAggressiveBrand', () {
    test('MIUI/Xiaomi brands detected', () {
      expect(AggressiveOem.isAggressiveBrand('Xiaomi'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('Redmi'), isTrue);
      expect(AggressiveOem.isAggressiveBrand('POCO'), isTrue);
    });

    test('MI family only (user decision 2026-08-17): former aggressive '
        'families now regular', () {
      // Field-proven working without battery restrictions → no special
      // treatment, exact alarms or gates for these.
      expect(AggressiveOem.isAggressiveBrand('HONOR'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('Oppo'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('realme'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('OnePlus'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('vivo'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('Nothing'), isFalse);
      expect(AggressiveOem.isAggressiveBrand('samsung'), isFalse);
    });

    test('regular brands not detected', () {
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
