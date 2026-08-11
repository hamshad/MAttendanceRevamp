import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:mattendance_mobile/features/punch/services/geofence_monitor.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════════
// Fake notifications platform — records which notification ids were shown
// (skip-notification hygiene: own-source echoes silent, id 995, cooldown).
// ═══════════════════════════════════════════════════════════════════════

class _FakeNotifications extends AndroidFlutterLocalNotificationsPlugin
    with MockPlatformInterfaceMixin {
  final List<int> shown = [];

  @override
  Future<void> show(
    int id,
    String? title,
    String? body, {
    AndroidNotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add(id);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Fake geolocator platform — controls the "fresh fix" returned by the
// hybrid-verification step.
// ═══════════════════════════════════════════════════════════════════════

class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  geo.Position? position;
  geo.Position? lastKnownPosition;
  bool locationServicesEnabled = true;

  /// Optional queue of fresh fixes — popped in order, then [position] is
  /// used.  Lets tests feed two DIFFERENT fixes (inline OUT confirmation).
  List<geo.Position> positionQueue = [];

  /// Fresh-fix call counter — asserts GPS-radio budgets (reconcile must
  /// reuse cached positions and respect its fix-budget window).
  int currentPositionCalls = 0;

  @override
  Future<geo.Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    currentPositionCalls++;
    if (positionQueue.isNotEmpty) return positionQueue.removeAt(0);
    final p = position;
    if (p == null) throw Exception('no fix in test');
    return p;
  }

  @override
  Future<geo.Position?> getLastKnownPosition({
    LocationSettings? locationSettings,
    bool forceLocationManager = false,
  }) async =>
      lastKnownPosition;

  @override
  Future<bool> isLocationServiceEnabled() async => locationServicesEnabled;
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

  /// Method of the recorded punches (Biometric / GeofenceAuto / WiFi ...).
  String punchMethod = 'Biometric';

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
        'method': punchMethod,
      });
    }
    if (isPunchedOut) {
      punches.add({
        'id': 2,
        'punchTime': '2026-08-08T18:00:00.000Z',
        'punchType': 'Out',
        'method': punchMethod,
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

/// Client-site coordinates ~1.4km from the office — non-overlapping by
/// default, so prompt tests stay independent of the office-first guard.
const _siteLat = 19.88;
const _siteLng = 75.35;

Map<String, Object> _zoneMeta(String id,
        {bool isClientSite = false,
        double lat = _officeLat,
        double lng = _officeLng}) =>
    {
      'gf_zone_$id': jsonEncode({
        'name': id == _officeId ? 'HQ' : 'Client A',
        'lat': lat,
        'lng': lng,
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
      // Registration always persists the zone-id list — the office-first
      // guard keys off it.
      'gf_zone_ids': [_officeId],
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

geo.Position _fixAt(double dLat, double dLng) =>
    _fixNear(_officeLat, _officeLng, dLat, dLng);

/// Fix offset from an arbitrary base point (e.g. a client site).
geo.Position _fixNear(double baseLat, double baseLng, double dLat, double dLng) =>
    geo.Position(
      latitude: baseLat + dLat,
      longitude: baseLng + dLng,
      timestamp: DateTime.now(),
      accuracy: 20,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// Fix with an explicit age (for stale-cache tests).
geo.Position _fixAged(double dLat, double dLng, Duration age) {
  final base = _fixAt(dLat, dLng);
  return geo.Position(
    latitude: base.latitude,
    longitude: base.longitude,
    timestamp: DateTime.now().subtract(age),
    accuracy: base.accuracy,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeGeolocatorPlatform fakeGeo;
  late _MockInterceptor mock;
  late _FakeNotifications notifications;

  setUp(() {
    notifications = _FakeNotifications();
    FlutterLocalNotificationsPlatform.instance = notifications;
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

    test('exit with OS crossing location → punch AT crossing, not the later fix',
        () async {
      // The 95m repro: OS fires exit at the boundary (~133m from center,
      // just outside the 100m radius) but deferred processing's fresh fix
      // is already ~300m away.  Punch must record the crossing, not the fix.
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      mock.isPunchedIn = true; // punched in earlier today
      fakeGeo.position = _fixAt(0.0027, 0.0027); // ~300m — late processing fix
      final crossing = const Location(
        latitude: _officeLat + 0.0012,
        longitude: _officeLng,
      ); // ~133m — just outside the 100m radius

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(_officeId, GeofenceEvent.exit,
          triggerLoc: crossing));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
      final lat = double.parse(mock.lastPayload!['Latitude'] as String);
      final lng = double.parse(mock.lastPayload!['Longitude'] as String);
      expect(lat, closeTo(crossing.latitude, 1e-6));
      expect(lng, closeTo(crossing.longitude, 1e-6));
    });

    test('exit with OS crossing outside + fix still inside → punches at crossing',
        () async {
      // OS crossing outranks the later fix: the exit transition IS the
      // boundary-crossing signal, even if a processing-time fix still shows
      // inside (user walked back / fix churn at the edge).
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      mock.isPunchedIn = true;
      fakeGeo.position = _fixAt(0.0002, 0.0002); // ~28m — still inside radius
      final crossing = const Location(
        latitude: _officeLat + 0.0012,
        longitude: _officeLng,
      );

      await GeofencePunchHandler.forTest(_dioWith(mock)).handleEvent(
          _params(_officeId, GeofenceEvent.exit, triggerLoc: crossing));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
    });

    test('exit + no fresh fix + OS crossing outside → punch OUT at crossing',
        () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      mock.isPunchedIn = true;
      fakeGeo.position = null; // fix unavailable
      final crossing = const Location(
        latitude: _officeLat + 0.0012,
        longitude: _officeLng,
      );

      await GeofencePunchHandler.forTest(_dioWith(mock)).handleEvent(
          _params(_officeId, GeofenceEvent.exit, triggerLoc: crossing));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
    });
  });

  group('Punch gates', () {
    test('server already punched in + local In → no duplicate IN', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true; // server agrees user is already IN

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

    test('stale local IN from yesterday → server decides, IN punches', () async {
      // Local state left over from a previous day would silently skip
      // today's IN (missed punch).  Server truth runs FIRST now.
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      // Server mock default: no punches today → IN is valid.

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'In');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In');
    });

    test('offline + stale local IN → skipped, no queue, no punch', () async {
      // Server unreachable: local state is the only truth — a stale 'In'
      // must not re-punch IN (server would toggle it to OUT).
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.failStatus = true;

      var queued = false;
      await GeofencePunchHandler.forTest(
        _dioWith(mock),
        queueOverride: (direction, lat, lng) async {
          queued = true;
          return true;
        },
      ).handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      expect(queued, isFalse);
    });

    test('own-source echo (GeofenceAuto) → silent skip, no notification',
        () async {
      // OS re-delivered ENTER after a re-registration: server says the last
      // punch was OUR OWN GeofenceAuto punch → duplicate must NOT notify
      // ("already punched via another source" while user sits at the office).
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true;
      mock.punchMethod = 'GeofenceAuto';

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      expect(notifications.shown.where((id) => id == 995), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In');
    });

    test('WiFi echo → silent skip, no notification', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true;
      mock.punchMethod = 'WiFi';

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      expect(notifications.shown.where((id) => id == 995), isEmpty);
    });

    test('real other-source duplicate (Biometric) → notification id 995',
        () async {
      // A REAL duplicate — user punched via the biometric machine → tell
      // them, using id 995 (999 is reserved for the permission alert).
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true; // default punchMethod: Biometric

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      expect(notifications.shown, contains(995));
    });

    test('skip notification rate-limited per zone+direction (30 min)',
        () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        'gf_zone_ids': [_officeId, 'office_2'],
        ..._zoneMeta('office_2'),
      });
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true; // Biometric → notifiable duplicate

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));
      expect(notifications.shown.where((id) => id == 995).length, 1);

      // Second duplicate for the SAME zone+direction within the window →
      // suppressed (cooldown key from the first notification).
      await h.handleEvent(_params(_officeId, GeofenceEvent.enter));
      expect(notifications.shown.where((id) => id == 995).length, 1);

      // Different zone → separate cooldown slot, not suppressed.
      await h.handleEvent(_params('office_2', GeofenceEvent.enter));
      expect(notifications.shown.where((id) => id == 995).length, 2);
    });
  });

  group('Background containment reconcile', () {
    test('punched out + inside office → punches IN in background', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      fakeGeo.position = _fixAt(0.0002, 0.0002); // ~30m inside 100m radius

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isTrue);
      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'In');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In');
    });

    test('already punched in → no redundant punch', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
    });

    test('outside office radius → no punch', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      fakeGeo.position = _fixAt(0.005, 0.005); // ~770m away

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
    });

    test('fix budget: second call within 90s window skips GPS', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      fakeGeo.position = _fixAt(0.005, 0.005); // outside — no punch

      final h = GeofencePunchHandler.forTest(_dioWith(mock));

      await h.reconcileContainment();
      expect(fakeGeo.currentPositionCalls, 1);

      // Same budget window → no fresh fix, no punch (battery budget held).
      expect(await h.reconcileContainment(), isFalse);
      expect(fakeGeo.currentPositionCalls, 1);
      expect(mock.punchCalls, 0);
    });

    test('fresh cached position reused → no GPS radio', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      // OS cache already has a recent inside-office fix — punch must use it.
      fakeGeo.lastKnownPosition = _fixAt(0.0002, 0.0002);

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isTrue);
      expect(mock.punchCalls, 1);
      expect(fakeGeo.currentPositionCalls, 0); // GPS never turned on
    });

    test('stale cached position ignored → fresh fix taken', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      // Yesterday's office fix must NOT fabricate today's IN.
      fakeGeo.lastKnownPosition =
          _fixAged(0.0002, 0.0002, const Duration(hours: 24));
      fakeGeo.position = _fixAt(0.005, 0.005); // real position: home

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
      expect(fakeGeo.currentPositionCalls, 1);
    });

    test('on registered office WiFi → wifi worker owns IN (no GPS, no punch)',
        () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'Out'),
        'wifi_bg_matched_name': 'HQ Office', // wifi worker will punch IN
      });
      fakeGeo.position = _fixAt(0.0002, 0.0002); // inside radius anyway

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
      expect(fakeGeo.currentPositionCalls, 0);
    });

    test('geofence disabled → no punch', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'Out'),
        'geofence_auto_enabled': false,
      });
      fakeGeo.position = _fixAt(0.0002, 0.0002);

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
    });

    test('server unreachable → IN queued offline, not lost', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.failStatus = true;

      var queued = false;
      final punched = await GeofencePunchHandler.forTest(
        _dioWith(mock),
        queueOverride: (direction, lat, lng) async {
          queued = true;
          return true;
        },
      ).reconcileContainment();

      expect(punched, isTrue);
      expect(mock.punchCalls, 0);
      expect(queued, isTrue);
    });

    test('biometric IN exists on server → skip, sync local state', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      mock.isPunchedIn = true; // user already IN via biometric machine

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isTrue);
      expect(mock.punchCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In'); // state synced
    });

    test('punched in + outside all offices across 2 polls → OUT punches',
        () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      fakeGeo.position = _fixAt(0.005, 0.005); // ~770m outside radius
      mock.isPunchedIn = true; // server agrees user is IN

      final h = GeofencePunchHandler.forTest(_dioWith(mock));

      // Poll #1: outside → marker recorded, no punch yet (jump guard).
      expect(await h.reconcileContainment(), isFalse);
      expect(mock.punchCalls, 0);

      // Poll #2 (~15s later, same position): confirms outside → OUT.
      expect(await h.reconcileContainment(), isTrue);
      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'Out');
    });

    test('confirmOut: punched in + outside on both fixes → punches OUT',
        () async {
      // The user's bug: OS exit missed while backgrounded, app opened,
      // still no OUT — the two-poll flow records poll #1 and waits for a
      // second poll that never comes (geofence-only mode has no background
      // poller).  confirmOut resolves it in a single call.
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      mock.isPunchedIn = true; // server agrees: last punch In
      fakeGeo.position = _fixAt(0.005, 0.005); // ~770m outside

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment(confirmOut: true);

      expect(punched, isTrue);
      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'Out');
      // Inline confirmation = two fixes, one call.
      expect(fakeGeo.currentPositionCalls, 2);
    });

    test('confirmOut: second fix inside → no OUT', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      mock.isPunchedIn = true;
      // Fix 1 outside, fix 2 back inside → contradictory → conservative no.
      fakeGeo.positionQueue = [
        _fixAt(0.005, 0.005),
        _fixAt(0.0002, 0.0002),
      ];

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment(confirmOut: true);

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
    });

    test('confirmOut: implausible jump between fixes → no OUT', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      mock.isPunchedIn = true;
      // ~890m apart — noise, not movement.
      fakeGeo.positionQueue = [
        _fixAt(0.005, 0.005),
        _fixAt(0.013, 0.005),
      ];

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment(confirmOut: true);

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
    });

    test('confirmOut: inside on first fix → no OUT, no second fix', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      mock.isPunchedIn = true;
      fakeGeo.position = _fixAt(0.0002, 0.0002); // still at the office

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment(confirmOut: true);

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
      expect(fakeGeo.currentPositionCalls, 1);
    });

    test('punched in + inside a different office → no OUT', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
        ..._zoneMeta('office_2',
            isClientSite: false, lat: _siteLat, lng: _siteLng),
        'gf_zone_ids': [_officeId, 'office_2'],
      });
      // User moved to office_2 (site coords) — still inside A registered
      // office → must NOT punch OUT.
      fakeGeo.position = _fixNear(_siteLat, _siteLng, 0.0002, 0.0002);
      mock.isPunchedIn = true;

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      expect(await h.reconcileContainment(), isFalse);
      expect(await h.reconcileContainment(), isFalse);
      expect(mock.punchCalls, 0);
    });

    test('punched in + outside + implausible jump between polls → no OUT',
        () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      mock.isPunchedIn = true;

      final h = GeofencePunchHandler.forTest(_dioWith(mock));

      // Poll #1: outside at A.
      fakeGeo.position = _fixAt(0.02, 0.02); // ~3km from office
      expect(await h.reconcileContainment(), isFalse);

      // Poll #2: jumps 2km+ — noise, confirmation marker resets to B.
      fakeGeo.position = _fixAt(-0.02, -0.02);
      expect(await h.reconcileContainment(), isFalse);
      expect(mock.punchCalls, 0);

      // Poll #3: stable at B — marker refreshed at B → confirms → OUT.
      expect(await h.reconcileContainment(), isTrue);
      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
    });
  });

  group('GPS off & OUT zone identity', () {
    test('GPS off → enter event rejected, no punch', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      fakeGeo.locationServicesEnabled = false;

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
    });

    test('GPS off → exit event rejected, no bogus punch-out', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'In'));
      fakeGeo.position = _fixAt(0.0002, 0.0002); // user still inside office
      fakeGeo.locationServicesEnabled = false;

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.exit));

      expect(mock.punchCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In'); // still punched in
    });

    test('GPS off → reconcile defers, no punch-in', () async {
      SharedPreferences.setMockInitialValues(_basePrefs(lastType: 'Out'));
      fakeGeo.position = _fixAt(0.0002, 0.0002);
      fakeGeo.locationServicesEnabled = false;

      final punched = await GeofencePunchHandler.forTest(_dioWith(mock))
          .reconcileContainment();

      expect(punched, isFalse);
      expect(mock.punchCalls, 0);
    });

    test('exit of a zone user is NOT punched into → rejected (batch exit)',
        () async {
      // User punched into the India office; the UAE fence fires a spurious
      // exit (GPS toggle / provider drop batch).  Must NOT punch OUT "of
      // UAE office".
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
        ..._zoneMeta('uae_1',
            isClientSite: false, lat: 24.4539, lng: 54.3773),
        'gf_zone_ids': [_officeId, 'uae_1'],
      });
      fakeGeo.position = _fixAt(0.0002, 0.0002); // user in India

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params('uae_1', GeofenceEvent.exit));

      expect(mock.punchCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_last_punch_type'), 'In');
    });

    test('exit of the punched-in zone still punches OUT', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      fakeGeo.position = _fixAt(0.0027, 0.0027); // ~400m outside radius
      mock.isPunchedIn = true; // server agrees user is IN

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_officeId, GeofenceEvent.exit));

      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
    });

    test('far-away exit trigger point → not an exit of this fence', () async {
      // OS reports an exit for the office fence with a trigger location
      // thousands of km away (batch exit) — must fall back to the fix
      // check instead of trusting the crossing point.
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(lastType: 'In'),
        'gf_last_punch_zone_id': _officeId,
      });
      fakeGeo.position = _fixAt(0.0027, 0.0027); // genuinely outside
      mock.isPunchedIn = true;

      final farTrigger = const Location(latitude: 55.7558, longitude: 37.6173);
      await GeofencePunchHandler.forTest(_dioWith(mock)).handleEvent(
          _params(_officeId, GeofenceEvent.exit, triggerLoc: farTrigger));

      // Fresh fix strictly outside the radius confirms the exit regardless
      // of the bogus trigger point.
      expect(mock.punchCalls, 1);
      expect(mock.lastDirection, 'Out');
    });
  });

  group('Client sites', () {
    test('enter client site → prompt, never auto-punch', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        ..._zoneMeta(_siteId,
            isClientSite: true, lat: _siteLat, lng: _siteLng),
      });
      fakeGeo.position = _fixNear(_siteLat, _siteLng, 0.0002, 0.0002);

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_siteId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_prompt_site_5'), isNotNull);
    });

    test('client-site prompt cooldown → single prompt', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        ..._zoneMeta(_siteId,
            isClientSite: true, lat: _siteLat, lng: _siteLng),
        'gf_prompt_site_5': DateTime.now().subtract(const Duration(minutes: 2))
            .toIso8601String(),
      });
      fakeGeo.position = _fixNear(_siteLat, _siteLng, 0.0002, 0.0002);

      final h = GeofencePunchHandler.forTest(_dioWith(mock));
      await h.handleEvent(_params(_siteId, GeofenceEvent.enter));

      final prefs = await SharedPreferences.getInstance();
      final before = prefs.getString('gf_prompt_site_5');
      await h.handleEvent(_params(_siteId, GeofenceEvent.enter));
      final after = prefs.getString('gf_prompt_site_5');
      expect(before, after); // unchanged → no re-prompt
    });

    test('enter client site overlapping office → office wins, no prompt',
        () async {
      // Office + client site share coordinates (site inside office compound).
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        ..._zoneMeta(_siteId,
            isClientSite: true, lat: _officeLat, lng: _officeLng),
        'gf_zone_ids': [_officeId, _siteId],
      });
      fakeGeo.position = _fixAt(0.0002, 0.0002); // ~30m from office center

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_siteId, GeofenceEvent.enter));

      expect(mock.punchCalls, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_prompt_site_5'), isNull); // no prompt
    });

    test('enter client site near office but outside radius → prompt fires',
        () async {
      // Site is registered but ~1.4km from the office — office-first guard
      // must NOT suppress the prompt here.
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        ..._zoneMeta(_siteId,
            isClientSite: true, lat: _siteLat, lng: _siteLng),
        'gf_zone_ids': [_officeId, _siteId],
      });
      fakeGeo.position = _fixNear(_siteLat, _siteLng, 0.0002, 0.0002);

      await GeofencePunchHandler.forTest(_dioWith(mock))
          .handleEvent(_params(_siteId, GeofenceEvent.enter));

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_prompt_site_5'), isNotNull);
    });
  });
}
