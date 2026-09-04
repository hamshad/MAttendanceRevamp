import 'package:geolocator/geolocator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/core/utils/mock_location.dart';

void main() {
  group('MockLocationDetector', () {
    group('isMocked', () {
      test('returns true when OS mock flag is set', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: true,
        );

        expect(MockLocationDetector.isMocked(fix), isTrue);
      });

      test('returns true for unrealistic accuracy (< 1m)', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 0.5, // Too precise for real GPS
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMocked(fix), isTrue);
      });

      test('returns true for unrealistic speed (> 100 m/s)', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 150.0, // 540 km/h — not human
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMocked(fix), isTrue);
      });

      test('returns true for unrealistic altitude (> 10000m)', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 15000.0, // Above Everest
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMocked(fix), isTrue);
      });

      test('returns true for unrealistic altitude (< -1000m)', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: -2000.0, // Below Dead Sea
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMocked(fix), isTrue);
      });

      test('returns false for normal GPS fix', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 15.0, // Normal urban GPS
          altitude: 500.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 1.4, // Walking speed
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMocked(fix), isFalse);
      });

      test('returns false for indoor GPS with poor accuracy', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 80.0, // Poor but real
          altitude: 500.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMocked(fix), isFalse);
      });

      test('returns false on exception (fail-open)', () {
        // We can't easily trigger an exception in isMocked, but we verify
        // the method doesn't throw on valid input
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(() => MockLocationDetector.isMocked(fix), returnsNormally);
      });
    });

    group('isMockedStream', () {
      test('returns true when current fix is mocked', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: true,
        );

        expect(MockLocationDetector.isMockedStream(fix, null), isTrue);
      });

      test('returns true for teleportation between fixes', () {
        final previous = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now().subtract(const Duration(seconds: 10)),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        final fix = Position(
          latitude: 19.8761 + 0.01, // ~1.1 km in 10 seconds = 110 m/s
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMockedStream(fix, previous), isTrue);
      });

      test('returns false for normal movement between fixes', () {
        final previous = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now().subtract(const Duration(seconds: 10)),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        final fix = Position(
          latitude: 19.8761 + 0.0001, // ~11m in 10 seconds = 1.1 m/s (walking)
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 1.1,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMockedStream(fix, previous), isFalse);
      });

      test('returns false when previous is null (first fix)', () {
        final fix = Position(
          latitude: 19.8761,
          longitude: 75.3400,
          timestamp: DateTime.now(),
          accuracy: 10.0,
          altitude: 100.0,
          altitudeAccuracy: 10.0,
          heading: 0.0,
          headingAccuracy: 10.0,
          speed: 0.0,
          speedAccuracy: 10.0,
          isMocked: false,
        );

        expect(MockLocationDetector.isMockedStream(fix, null), isFalse);
      });
    });
  });
}