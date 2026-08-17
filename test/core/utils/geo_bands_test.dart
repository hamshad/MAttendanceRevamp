import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:mattendance_mobile/core/utils/geo_bands.dart';

void main() {
  const officeLat = 12.9716;
  const officeLng = 77.5946;

  Position fixAt(double dLat, double dLng, {double accuracy = 10}) =>
      Position(
        latitude: officeLat + dLat,
        longitude: officeLng + dLng,
        timestamp: DateTime.now(),
        accuracy: accuracy,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  group('isOutsideOfficeBand', () {
    test('inside the band → false', () {
      // ~11m from center, 20m radius → inside 45m band.
      expect(
        isOutsideOfficeBand(
          fixAt(0.0001, 0.0),
          zoneLatitude: officeLat,
          zoneLongitude: officeLng,
          zoneRadius: 20.0,
        ),
        isFalse,
      );
    });

    test('outside band with honest GPS accuracy → true', () {
      // ~66m out, 20m radius → beyond 45m band, accuracy 10m trusted.
      expect(
        isOutsideOfficeBand(
          fixAt(0.0006, 0.0),
          zoneLatitude: officeLat,
          zoneLongitude: officeLng,
          zoneRadius: 20.0,
        ),
        isTrue,
      );
    });

    test('outside band but accuracy worse than the band → false '
        '(wifi-blend trust floor — the 68m false-OUT class)', () {
      // ~88m out, claiming 120m accuracy (fused wifi blend): must NOT
      // count as outside — defers the punch.
      expect(
        isOutsideOfficeBand(
          fixAt(0.00079, 0.0, accuracy: 120),
          zoneLatitude: officeLat,
          zoneLongitude: officeLng,
          zoneRadius: 20.0,
        ),
        isFalse,
      );
    });

    test('accuracy exactly at the band boundary → trusted (<=)', () {
      expect(
        isOutsideOfficeBand(
          fixAt(0.00079, 0.0, accuracy: 45),
          zoneLatitude: officeLat,
          zoneLongitude: officeLng,
          zoneRadius: 20.0,
        ),
        isTrue,
      );
    });

    test('custom slack respected', () {
      // 40m out with radius 20 + slack 15 (band 35m) → outside.
      expect(
        isOutsideOfficeBand(
          fixAt(0.00036, 0.0),
          zoneLatitude: officeLat,
          zoneLongitude: officeLng,
          zoneRadius: 20.0,
          slackM: 15,
        ),
        isTrue,
      );
      // Same fix with slack 25 (band 45m) → inside.
      expect(
        isOutsideOfficeBand(
          fixAt(0.00036, 0.0),
          zoneLatitude: officeLat,
          zoneLongitude: officeLng,
          zoneRadius: 20.0,
          slackM: 25,
        ),
        isFalse,
      );
    });
  });
}
