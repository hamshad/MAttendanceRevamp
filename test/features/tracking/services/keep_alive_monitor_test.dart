import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mattendance_mobile/features/punch/services/geofence_monitor.dart';
import 'package:mattendance_mobile/features/tracking/services/field_tracking_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const officeLat = 12.9716;
  const officeLng = 77.5946;

  String zoneJson(Map<String, Object?> fields) => jsonEncode({
        'name': 'HQ',
        'lat': officeLat,
        'lng': officeLng,
        'radius': 20.0,
        'isClientSite': false,
        'officeId': 1,
        ...fields,
      });

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

  group('keepAliveOfficeZones', () {
    test('loads office zones and skips client sites', () async {
      SharedPreferences.setMockInitialValues({
        'gf_zone_ids': ['office_1', 'site_9'],
        'gf_zone_office_1': zoneJson({}),
        'gf_zone_site_9': zoneJson({'isClientSite': true}),
      });
      final prefs = await SharedPreferences.getInstance();
      final zones = keepAliveOfficeZones(prefs);
      expect(zones.length, 1);
      expect(zones.single.id, 'office_1');
    });

    test('empty when no zones persisted', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(keepAliveOfficeZones(prefs), isEmpty);
    });

    test('corrupt zone metadata skipped', () async {
      SharedPreferences.setMockInitialValues({
        'gf_zone_ids': ['office_1', 'office_2'],
        'gf_zone_office_1': zoneJson({}),
        'gf_zone_office_2': 'not-json{',
      });
      final prefs = await SharedPreferences.getInstance();
      final zones = keepAliveOfficeZones(prefs);
      expect(zones.length, 1);
      expect(zones.single.id, 'office_1');
    });
  });

  group('isOutsideAllOffices', () {
    const zone = GeofenceZone(
      id: 'office_1',
      name: 'HQ',
      latitude: officeLat,
      longitude: officeLng,
      radius: 20.0,
      isClientSite: false,
      officeId: 1,
    );

    test('inside radius → false', () {
      expect(isOutsideAllOffices(fixAt(0.0001, 0.0), [zone]), isFalse);
    });

    test('just outside radius → false (accuracy margin absorbs it)', () {
      // ~27m from center, 20m radius, 10m accuracy → margin 20m → inside.
      expect(isOutsideAllOffices(fixAt(0.00024, 0.0), [zone]), isFalse);
    });

    test('clearly outside every office → true', () {
      expect(isOutsideAllOffices(fixAt(0.001, 0.001), [zone]), isTrue);
    });

    test('outside one office but inside another → false', () {
      const other = GeofenceZone(
        id: 'office_2',
        name: 'Remote',
        latitude: officeLat + 0.001, // ~111m north of HQ
        longitude: officeLng,
        radius: 100.0,
        isClientSite: false,
        officeId: 2,
      );
      // Fix at ~66m north: outside HQ's 20m radius (66 > 20+20) but inside
      // `other`'s 100m radius (45m from its center, 45 < 100+20).
      expect(isOutsideAllOffices(fixAt(0.0006, 0.0), [zone, other]), isFalse);
    });

    test('poor accuracy widens the margin', () {
      // ~44m out, 20m radius, accuracy 60 → margin 120 → still inside.
      expect(isOutsideAllOffices(fixAt(0.0004, 0.0, accuracy: 60), [zone]),
          isFalse);
      // Same fix, tight accuracy → outside.
      expect(isOutsideAllOffices(fixAt(0.0004, 0.0, accuracy: 10), [zone]),
          isTrue);
    });

    test('no zones → false', () {
      expect(isOutsideAllOffices(fixAt(0.001, 0.001), []), isFalse);
    });
  });
}
