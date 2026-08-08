import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:mattendance_mobile/features/punch/services/geofence_monitor.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════════
// Fake geolocator platform — controls the "fresh fix" returned by the
// hybrid-verification step.
// ═══════════════════════════════════════════════════════════════════════

class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  geo.Position? position;

  @override
  Future<geo.Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    final p = position;
    if (p == null) throw Exception('no fix in test');
    return p;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Stateful mock Dio — tracks punch calls + server status
// ═══════════════════════════════════════════════════════════════════════

class _MockInterceptor extends Interceptor {
  bool isPunchedIn = false;
  bool isPunchedOut = false;
  bool hasNotPunchedIn = false;
  bool failStatus = false;
  bool failPunch = false;

  int punchCalls = 0;
  String? lastDirection;
  Map<String, dynamic>? lastPayload;

  /// Model-valid /attendance/status payload (EmployeeStatus.fromJson).
  Map<String, dynamic> _statusJson() {
    final punches = <Map<String, dynamic>>[];
    if (isPunchedIn) {
      punches.add({
        'id': 1,
        'punchTime': '2026-08-08T09:00:00.000Z',
        'punchType': 'In',
        'method': 'Biometric',
      });
    }
    if (isPunchedOut) {
      punches.add({
        'id': 2,
        'punchTime': '2026-08-08T18:00:00.000Z',
        'punchType': 'Out',
        'method': 'Biometric',
      });
    }
    return {
      'empId': 1,
      'fullName': 'Test',
      'date': '2026-08-08',
      'status': 'Present',
      'firstInTime': isPunchedIn ? '2026-08-08T09:00:00.000Z' : null,
      'lastOutTime': isPunchedOut ? '2026-08-08T18:00:00.000Z' : null,
      'workMinutes': 0,
      'breakMinutes': 0,
      'isLateIn': false,
      'isOnBreak': false,
      'currentShift': 'Morning',
      'officeName': 'HQ',
      'todaysPunches': punches,
    };
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    final path = options.path;
    if (path.endsWith('/status')) {
      if (failStatus) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'network down',
          ),
        );
      } else {
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: {'data': _statusJson()},
          ),
        );
      }
      return;
    }
    if (path.endsWith('/punch')) {
      punchCalls++;
      lastDirection = (options.data as Map)['Direction'] as String?;
      lastPayload = (options.data as Map).cast<String, dynamic>();
      if (failPunch) {
        handler.reject(
          DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            error: 'network down',
          ),
        );
      } else {
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: {'message': 'ok'}),
        );
      }
      return;
    }
    handler.next(options);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Fixtures
// ═══════════════════════════════════════════════════════════════════════

const _officeId = 'office_1';
const _officeLat = 19.8761;
const _officeLng = 75.3400;
const _officeRadius = 100.0;

const _siteId = 'site_5';

Map<String, Object> _zoneMeta(String id, {bool isClientSite = false}) => {
      'gf_zone_$id': jsonEncode({
        'name': id == _officeId ? 'HQ' : 'Client A',
        'lat': _officeLat,
        'lng': _officeLng,
        'radius': _officeRadius,
        'isClientSite': isClientSite,
        'officeId': isClientSite ? null : 1,
        'clientSiteId': isClientSite ? 5 : null,
      }),
    };

Map<String, Object> _basePrefs({String? lastType}) => {
      'geofence_auto_enabled': true,
      'bg_allow_geofence_auto': true,
      'bg_access_token': 'token',
      'bg_refresh_token': 'refresh',
      'auth_session_id': 'sess',
      if (lastType != null) 'gf_last_punch_type': lastType,
      ..._zoneMeta(_officeId),
    };

Dio _dioWith(_MockInterceptor mock) =>
    Dio(BaseOptions(baseUrl: 'https://api.mattendance.com'))
      ..interceptors.add(mock);

GeofenceCallbackParams _params(
  String zoneId,
  GeofenceEvent event, {
  Location? triggerLoc,
}) =>
    GeofenceCallbackParams(
      geofences: [
        ActiveGeofence(
          id: zoneId,
          location: const Location(
            latitude: _officeLat,
            longitude: _officeLng,
          ),
          radiusMeters: _officeRadius,
          triggers: {GeofenceEvent.enter, GeofenceEvent.exit},
          androidSettings: null,
        ),
      ],
      event: event,
      location: triggerLoc,
    );

geo.Position _fixAt(double dLat, double dLng) => geo.Position(
      latitude: _officeLat + dLat,
      longitude: _officeLng + dLng,
      timestamp: DateTime.now(),
      accuracy: 20,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeGeolocatorPlatform fakeGeo;
  late _MockInterceptor mock;

  setUp(() {
    fakeGeo = _FakeGeolocatorPlatform();
    geo.GeolocatorPlatform.instance = fakeGeo;
    mock = _MockInterceptor();
  });

  group('Gates', () {
    test('disabled in prefs → no punch', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        'geofence_auto_enabled': false,
      });
      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));
      expect(mock.punchCalls, 0);
    });

    test('backend permission denied → no punch', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        'bg_allow_geofence_auto': false,
      });
      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));
      expect(mock.punchCalls, 0);
    });

    test('no auth token → no punch', () async {
      final prefs = Map<String, Object>.from(_basePrefs())
        ..remove('bg_access_token');
      SharedPreferences.setMockInitialValues(prefs);
      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));
      expect(mock.punchCalls, 0);
    });

    test('unknown zone (no metadata) → no punch', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params('office_999', GeofenceEvent.enter));
      expect(mock.punchCalls, 0);
    });
  });

  group('Hybrid verification', () {
    test('enter + fresh fix inside radius → punch IN', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002); // ~30m from center

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'In');
      expect(mock.lastPayload!['Method'], 'GeofenceAuto');
      expect(mock.lastPayload!['Address'], 'HQ');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In');
    });

    test('enter + fresh fix far away (OS false fire) → rejected', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.009, 0.009); // ~1km away

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
    });

    test('enter + no fresh fix + OS trigger location inside → punch IN',
        () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = null; // fix unavailable

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(
        _officeId,
        GeofenceEvent.enter,
        triggerLoc: const Location(
          latitude: _officeLat + 0.0002,
          longitude: _officeLng + 0.0002,
        ),
      ));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'In');
    });

    test('enter + no fix + trigger location outside → rejected', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = null;

      await GeofencePunchHandler.forTest(_dioWith(mock)).handleEvent(
          _params(_officeId, GeofenceEvent.enter,
              triggerLoc: const Location(
                  latitude: _officeLat + 0.009, longitude: _officeLng)));

      expect(mock.punchCalls, 0);
    });

    test('exit + fresh fix outside → punch OUT', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0027, 0.0027); // ~300m away
      mock.isPunchedIn = true; // punched in earlier today (e.g. biometric)

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(_officeId, GeofenceEvent.exit));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'Out');
    });

    test('exit + fresh fix still inside → rejected', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0004, 0.0004); // ~60m — still within radius

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.exit));

      expect(mock.punchCalls, 0);
    });
  });

  group('Punch gates', () {
    test('already punched in locally → no duplicate IN', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
    });

    test('server already punched in → skip + adopt local state', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true;

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In');
    });

    test('server says no IN today → no OUT', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0027, 0.0027);
      mock.hasNotPunchedIn = true;

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.exit));

      expect(mock.punchCalls, 0);
    });

    test('duplicate event within dedupe window → single punch', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 1);
    });

    test('punch network failure → no local state adoption', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.failPunch = true;

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), isNull);
    });
  });

  group('PunchCoordinator gate', () {
    test('server unreachable on IN → queued offline, never dropped', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.failStatus = true;

      final queued = <String>[];
      final h = GeofencePunchHandler.forTest(
        _dioWith(mock),
        queueOverride: (direction, lat, lng) async {
          queued.add(direction);
          return true;
        },
      );
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      expect(queued, ['In']);
    });

    test('server unreachable + queue unavailable → no crash, no punch',
        () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.failStatus = true;

      final h = GeofencePunchHandler.forTest(
        _dioWith(mock),
        queueOverride: (direction, lat, lng) async => false,
      );
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
    });

    test('server unreachable on OUT → still attempts punch (falls to queue)',
        () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0027, 0.0027);
      mock.failStatus = true;

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.exit));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
    });

    test('biometric IN already recorded → skip, no punch, no queue', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true; // punch made via biometric machine

      var queued = false;
      final h = GeofencePunchHandler.forTest(
        _dioWith(mock),
        queueOverride: (direction, lat, lng) async {
          queued = true;
          return true;
        },
      );
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      expect(queued, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In');
    });
  });

  group('Client sites', () {
    test('enter client site → prompt, never auto-punch', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        ..._zoneMeta(_siteId, isClientSite: true),
      });
      fakeGeo.position = _fixAt(0.0002, 0.0002);

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_siteId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_prompt_site_5'), isNotNull);
    });

    test('client-site prompt cooldown → single prompt', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        ..._zoneMeta(_siteId, isClientSite: true),
        'gf_prompt_site_5': DateTime.now().subtract(const Duration(minutes: 2))
            .toIso8601String(),
      });
      fakeGeo.position = _fixAt(0.0002, 0.0002);

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(_siteId, GeofenceEvent.enter));

      final prefs = await SharedPreferences.getInstance();
      final before = prefs.getString('gf_prompt_site_5');
      await h.handleEvent(_params(_siteId, GeofenceEvent.enter));
      final after = prefs.getString('gf_prompt_site_5');
      expect(before, after); // unchanged → no re-prompt
    });
  });
}
