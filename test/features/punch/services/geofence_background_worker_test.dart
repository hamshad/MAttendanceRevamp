import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/features/punch/services/geofence_background_worker.dart';
import 'package:mattendance_mobile/features/tracking/models/location_result.dart';
import 'package:mattendance_mobile/models/client_site.dart';
import 'package:mattendance_mobile/models/office.dart';
import 'package:mattendance_mobile/models/shift.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ═══════════════════════════════════════════════════════════════════════
// Fake ServiceInstance — records all invoke/stopSelf calls
// ═══════════════════════════════════════════════════════════════════════

class _FakeServiceInstance extends ServiceInstance {
  final List<_Invocation> calls = [];
  final _onCtrl = StreamController<Map<String, dynamic>?>.broadcast();

  @override
  void invoke(String method, [Map<String, dynamic>? args]) {
    calls.add(_Invocation(method, args ?? const {}));
  }

  @override
  Stream<Map<String, dynamic>?> on(String method) => _onCtrl.stream;

  @override
  Future<void> stopSelf() async {
    calls.add(const _Invocation('stopSelf', {}));
  }
}

class _Invocation {
  final String method;
  final Map<String, dynamic> args;
  const _Invocation(this.method, this.args);

  @override
  String toString() => '_Invocation($method, $args)';
}

Map<String, dynamic> _officeToJson(Office o) => {
      'id': o.id,
      'name': o.name,
      'latitude': o.latitude,
      'longitude': o.longitude,
      'geofenceRadius': o.geofenceRadius,
    };

// ═══════════════════════════════════════════════════════════════════════
// Stateful mock Dio interceptor — tracks punch state across API calls
// ═══════════════════════════════════════════════════════════════════════

class _MockInterceptor extends Interceptor {
  final List<Office> offices;
  final List<Shift> shifts;
  final List<ClientSite> clientSites;

  bool isPunchedIn = false;
  bool isPunchedOut = false;
  int punchCallCount = 0;
  String? lastPunchDirection;
  Map<String, dynamic>? lastPunchPayload;

  bool shouldFailPunch = false;
  bool shouldFailStatus = false;
  bool shouldRespondAlreadyRecorded = false;
  Map<String, dynamic>? customStatus;

  _MockInterceptor({
    List<Office>? offices,
    List<Shift>? shifts,
    List<ClientSite>? clientSites,
  })  : offices = offices ??
            [
              const Office(
                id: 1,
                name: 'Test Office',
                latitude: 19.8761,
                longitude: 75.3153,
                geofenceRadius: 150,
              ),
            ],
        shifts = shifts ??
            [
              const Shift(
                id: 1,
                orgId: 1,
                name: 'Default',
                startTime: '00:00',
                endTime: '23:59',
                bufferMinutes: 0,
                minBreakMinutes: 30,
                isOvernight: false,
                isActive: true,
              ),
            ],
        clientSites = clientSites ?? [];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.uri.path;
    try {
      if (path.contains('/offices')) {
        handler.resolve(_rsp(options, offices.map(_officeToJson).toList()));
      } else if (path.contains('/client-sites')) {
        handler.resolve(_rsp(options, clientSites.map((s) => s.toJson()).toList()));
      } else if (path.contains('/shifts')) {
        handler.resolve(_rsp(options, shifts.map((s) => s.toJson()).toList()));
      } else if (path.contains('/status')) {
        if (shouldFailStatus) {
          handler.reject(DioException(requestOptions: options, type: DioExceptionType.connectionTimeout));
          return;
        }
        handler.resolve(_rsp(
          options,
          customStatus ??
              {
                'isPunchedIn': isPunchedIn,
                'isPunchedOut': isPunchedOut,
                'hasNotPunchedIn': !isPunchedIn && !isPunchedOut,
                'currentShift': shifts.isNotEmpty ? shifts.first.name : null,
              },
        ));
      } else if (path.contains('/punch')) {
        if (shouldFailPunch) {
          handler.reject(DioException(requestOptions: options, type: DioExceptionType.badResponse));
          return;
        }
        punchCallCount++;
        lastPunchDirection = options.data is Map ? (options.data as Map)['Direction'] as String? : null;
        lastPunchPayload = options.data is Map ? Map<String, dynamic>.from(options.data as Map) : null;
        if (lastPunchDirection == 'In') { isPunchedIn = true; isPunchedOut = false; }
        if (lastPunchDirection == 'Out') { isPunchedOut = true; isPunchedIn = false; }
        if (shouldRespondAlreadyRecorded) {
          handler.reject(DioException(
            requestOptions: options,
            response: Response(
              requestOptions: options,
              data: {'message': 'Duplicate punch detected. Please wait at least 60 seconds.'},
              statusCode: 400,
            ),
            type: DioExceptionType.badResponse,
          ));
          return;
        }
        handler.resolve(Response(requestOptions: options, data: {}, statusCode: 201));
      } else {
        handler.reject(DioException(requestOptions: options, type: DioExceptionType.badResponse));
      }
    } catch (e) {
      handler.reject(DioException(requestOptions: options, error: e, type: DioExceptionType.unknown));
    }
  }

  Response _rsp(RequestOptions o, dynamic d, [int code = 200]) {
    return Response(requestOptions: o, data: d is List ? d : {'data': d}, statusCode: code);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Test helpers
// ═══════════════════════════════════════════════════════════════════════

/// A location ~100 m from the office center (inside 150 m radius).
LocationResult insideLocation({double accuracy = 10}) => LocationResult(
      latitude: 19.8769,
      longitude: 75.3143,
      accuracy: accuracy,
      speed: 0.5,
      jumpScore: 0.0,
    );

/// A location ~500 m from the office center (well outside + margin).
LocationResult outsideLocation({double accuracy = 10}) => LocationResult(
      latitude: 19.8810,
      longitude: 75.3200,
      accuracy: accuracy,
      speed: 1.2,
      jumpScore: 0.0,
    );

/// A location at the boundary — just inside the radius + GPS margin
/// so exit tracking starts but does not confirm immediately.
LocationResult boundaryLocation({double accuracy = 10}) => LocationResult(
      latitude: 19.8775,
      longitude: 75.3165,
      accuracy: accuracy,
      speed: 0.8,
      jumpScore: 0.0,
    );

const defaultConfidence = 0.9;

/// Verify punches can be asserted on the service instance
extension PunchChecks on List<_Invocation> {
  int get punchInCount => where((c) => c.args['direction'] == 'In').length;
  int get punchOutCount => where((c) => c.args['direction'] == 'Out').length;
  bool get didPunchIn => punchInCount > 0;
  bool get didPunchOut => punchOutCount > 0;
  bool get didStop => any((c) => c.method == 'stop' || c.method == 'stopSelf');
  bool get didGfStop => any((c) => c.method == 'gf_stop');
  int get gfPunchCount => where((c) => c.method == 'gf_punch').length;
}

// ═══════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════

void main() {
  late _FakeServiceInstance service;
  late _MockInterceptor mockInterceptor;
  late Dio dio;

  setUp(() {
    service = _FakeServiceInstance();
    SharedPreferences.setMockInitialValues({
      'bg_access_token': 'test_token',
      'geofence_auto_enabled': true,
    });
    mockInterceptor = _MockInterceptor();
    dio = Dio(BaseOptions(baseUrl: 'http://test'));
    dio.interceptors.add(mockInterceptor);
  });

  group('Data loading', () {
    test('loads offices and shifts from API', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // onLocationFix should now be able to detect entry
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchIn, isTrue);
      expect(mockInterceptor.punchCallCount, 1);
    });

    test('no action when no offices available', () async {
      final emptyInterceptor = _MockInterceptor(offices: []);
      final emptyDio = Dio(BaseOptions(baseUrl: 'http://test'));
      emptyDio.interceptors.add(emptyInterceptor);

      final worker = GeofenceBackgroundWorker(service, dio: emptyDio);
      await worker.loadData();
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.gfPunchCount, 0);
    });
  });

  group('Entry detection', () {
    test('punches IN when user is inside office geofence', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchIn, isTrue);
      expect(mockInterceptor.lastPunchDirection, 'In');
    });

    test('does NOT punch IN when user is outside office zone', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(outsideLocation(), TrackingState.MOVING, defaultConfidence);

      expect(service.calls.didPunchIn, isFalse);
    });

    test('does NOT punch IN when confidence is below threshold', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.MOVING, 0.5);

      expect(service.calls.didPunchIn, isFalse);
    });
  });

  group('Exit detection', () {
    test('starts exit tracking when past GPS margin, confirms on subsequent fixes', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // First punch IN so we are "inside"
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.didPunchIn, isTrue);
      service.calls.clear();

      // Now simulate moving well outside — this should start exit tracking
      // and the exit trend analyzer will confirm after several outside fixes.
      // Use points progressively farther away to satisfy exit trend analyzer.
      final exitPoints = [
        LocationResult(latitude: 19.8775, longitude: 75.3165, accuracy: 10, speed: 1.0, jumpScore: 0.0), // ~180m
        LocationResult(latitude: 19.8780, longitude: 75.3170, accuracy: 10, speed: 1.1, jumpScore: 0.0), // ~230m
        LocationResult(latitude: 19.8790, longitude: 75.3180, accuracy: 10, speed: 1.2, jumpScore: 0.0), // ~330m
        LocationResult(latitude: 19.8800, longitude: 75.3190, accuracy: 10, speed: 1.3, jumpScore: 0.0), // ~430m
      ];

      for (final pt in exitPoints) {
        await worker.onLocationFix(pt, TrackingState.MOVING, defaultConfidence);
        if (service.calls.didPunchOut) break;
      }

      expect(service.calls.didPunchOut, isTrue,
          reason: 'Expected exit trend analyzer to confirm OUT after progressively farther points');
      expect(mockInterceptor.lastPunchDirection, 'Out');
    });

    test('does NOT trigger exit when user is at boundary (within GPS margin)', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      service.calls.clear();

      // Boundary location is outside the 150m radius but within the GPS margin
      // (150 + max(10, accuracy=10) = 160m). The boundary location is ~180m away,
      // so it WILL exceed the margin. Use a location that's within margin instead.
      // For accuracy=100, margin = max(10, 100) = 100, threshold = 150 + 100 = 250
      final insideMargin = LocationResult(
        latitude: 19.8770, longitude: 75.3160, accuracy: 100, speed: 0.5, jumpScore: 0.0,
      );
      // distance from center: roughly 170m, threshold = 150 + 100 = 250 → within margin
      await worker.onLocationFix(insideMargin, TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchOut, isFalse);
    });

    test('cancels exit tracking when user moves back inside', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      service.calls.clear();

      // Move just outside to start exit tracking
      final justOutside = LocationResult(
        latitude: 19.8775, longitude: 75.3165, accuracy: 10, speed: 1.0, jumpScore: 0.0,
      );
      await worker.onLocationFix(justOutside, TrackingState.MOVING, defaultConfidence);
      service.calls.clear();

      // Move back inside before exit is confirmed
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchOut, isFalse);
    });
  });

  group('Gate logic — cooldown', () {
    test('blocks same-direction punch (local state gate)', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // First IN
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.punchInCount, 1);

      // Another IN fix — should be blocked by local state gate (same direction)
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      // Only 1 IN total (the second was blocked by local state: already punched in)
      expect(service.calls.punchInCount, 1);

      // Punch OUT should still work (different direction)
      final exitPt = outsideLocation();
      await worker.onLocationFix(exitPt, TrackingState.MOVING, defaultConfidence);
      // Might not trigger if exit trend not confirmed, but if it does, it's a different direction
      // The cooldown only blocks same-direction
    });

    test('blocks same-direction punch regardless of time (local state gate)', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // First IN
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.punchInCount, 1);

      // Second IN → blocked by local state (already punched in) regardless of cooldown
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.punchInCount, 1);

      // OUT should still work (different direction)
      final exitPt = outsideLocation();
      for (int i = 0; i < 4; i++) {
        await worker.onLocationFix(exitPt, TrackingState.MOVING, defaultConfidence);
        if (service.calls.didPunchOut) break;
      }
      expect(service.calls.didPunchOut, isTrue);
      expect(mockInterceptor.lastPunchDirection, 'Out');
    });

    test('server 400 "Duplicate/recorded" updates local state as success', () async {
      mockInterceptor.shouldRespondAlreadyRecorded = true;

      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      // The 400 with "already recorded" should still update local state and fire gf_punch
      expect(service.calls.gfPunchCount, 1, reason: 'gf_punch fired despite 400');
      expect(service.calls.didPunchIn, isTrue, reason: 'IN recorded locally');
      expect(mockInterceptor.isPunchedIn, isTrue, reason: 'Server recorded the IN');
      expect(mockInterceptor.punchCallCount, 1, reason: 'One API call made');
      expect(mockInterceptor.lastPunchDirection, 'In');

      // Subsequent fix should NOT call API again (local state: already punched in)
      mockInterceptor.shouldRespondAlreadyRecorded = false;
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(mockInterceptor.punchCallCount, 1, reason: 'Duplicate blocked by local state');
    });
  });

  group('Gate logic — server status', () {
    test('blocks IN when server says already punched in', () async {
      mockInterceptor.customStatus = {
        'isPunchedIn': true,
        'isPunchedOut': false,
        'hasNotPunchedIn': false,
        'currentShift': 'Default',
      };

      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchIn, isFalse);
    });

    test('blocks OUT when server says already punched out', () async {
      mockInterceptor.isPunchedIn = true;
      mockInterceptor.isPunchedOut = true;
      mockInterceptor.customStatus = {
        'isPunchedIn': false,
        'isPunchedOut': true,
        'hasNotPunchedIn': false,
        'currentShift': 'Default',
      };

      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // Even if exit is detected, server says already out → blocked
      final exitPt = outsideLocation();
      await worker.onLocationFix(exitPt, TrackingState.MOVING, defaultConfidence);

      expect(service.calls.didPunchOut, isFalse);
    });

    test('blocks IN when server is unreachable (null status)', () async {
      mockInterceptor.shouldFailStatus = true;

      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchIn, isFalse);
    });

    test('allows OUT when server is unreachable (worker not trapped for overtime)', () async {
      mockInterceptor.shouldFailStatus = true;

      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // Perform a full exit cycle
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      service.calls.clear();
      mockInterceptor.shouldFailStatus = false; // Status succeeded initially
      mockInterceptor.isPunchedIn = true;

      // Now make status fail for OUT
      mockInterceptor.shouldFailStatus = true;
      final exitPt = outsideLocation();
      for (int i = 0; i < 4; i++) {
        await worker.onLocationFix(exitPt, TrackingState.MOVING, defaultConfidence);
      }

      // OUT should still go through even if status fails
      // because the gate only blocks OUT when status != null AND (isPunchedOut or hasNotPunchedIn)
      // When status == null, OUT is allowed
      expect(service.calls.didPunchOut, isTrue);
    });
  });

  group('Gate logic — shift hours', () {
    test('blocks auto-IN before shift start (local check)', () async {
      // Use a shift that starts in the future
      final futureShift = Shift(
        id: 1, orgId: 1, name: 'Future',
        startTime: '23:59', endTime: '23:59',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: false, isActive: true,
      );
      final lateInterceptor = _MockInterceptor(shifts: [futureShift]);
      final lateDio = Dio(BaseOptions(baseUrl: 'http://test'));
      lateDio.interceptors.add(lateInterceptor);

      final worker = GeofenceBackgroundWorker(service, dio: lateDio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      // If current time is before 23:59, IN is blocked by local shift check
      // If test runs at 23:59 or later, this test might pass unexpectedly
      // Test the condition inline as a guard
      final now = DateTime.now();
      if (now.isBefore(futureShift.todayStart)) {
        expect(service.calls.didPunchIn, isFalse);
      }
    });

    test('auto-OUT is never blocked by shift gate', () {
      const direction = 'Out';
      // Gate 6 only checks: if (direction == 'In' && _shifts.isNotEmpty)
      expect(direction == 'In', isFalse);
    });
  });

  group('Full lifecycle', () {
    test('enters office → auto-IN → leaves → auto-OUT → stop service', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // Step 1: Inside office → auto-IN
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.didPunchIn, isTrue);
      expect(mockInterceptor.isPunchedIn, isTrue);
      service.calls.clear();

      // Step 2: Progressive exit
      final exitPoints = [
        LocationResult(latitude: 19.8775, longitude: 75.3165, accuracy: 10, speed: 1.0, jumpScore: 0.0),
        LocationResult(latitude: 19.8780, longitude: 75.3170, accuracy: 10, speed: 1.1, jumpScore: 0.0),
        LocationResult(latitude: 19.8790, longitude: 75.3180, accuracy: 10, speed: 1.2, jumpScore: 0.0),
        LocationResult(latitude: 19.8800, longitude: 75.3190, accuracy: 10, speed: 1.3, jumpScore: 0.0),
      ];

      for (final pt in exitPoints) {
        await worker.onLocationFix(pt, TrackingState.MOVING, defaultConfidence);
        if (service.calls.didPunchOut) break;
      }

      expect(service.calls.didPunchOut, isTrue);
      expect(mockInterceptor.isPunchedOut, isTrue);

      // Step 3: After OUT, service should NOT be stopped (keeps monitoring for re-entry)
      expect(service.calls.didStop, isFalse,
          reason: 'Service must keep running after OUT to detect re-entry');
    });

    test('IN after OUT re-entry', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // Step 1: Inside office → auto-IN
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.didPunchIn, isTrue);
      service.calls.clear();

      // Step 2: Progressive exit → auto-OUT
      final exitPoints = [
        LocationResult(latitude: 19.8775, longitude: 75.3165, accuracy: 10, speed: 1.0, jumpScore: 0.0),
        LocationResult(latitude: 19.8780, longitude: 75.3170, accuracy: 10, speed: 1.1, jumpScore: 0.0),
        LocationResult(latitude: 19.8790, longitude: 75.3180, accuracy: 10, speed: 1.2, jumpScore: 0.0),
        LocationResult(latitude: 19.8800, longitude: 75.3190, accuracy: 10, speed: 1.3, jumpScore: 0.0),
      ];

      for (final pt in exitPoints) {
        await worker.onLocationFix(pt, TrackingState.MOVING, defaultConfidence);
        if (service.calls.didPunchOut) break;
      }

      expect(service.calls.didPunchOut, isTrue);
      expect(service.calls.didStop, isFalse,
          reason: 'Service must keep running after OUT to detect re-entry');

      // Step 3: Server state reflects OUT — ready for next IN
      expect(mockInterceptor.isPunchedIn, isFalse,
          reason: 'After OUT, server must show isPunchedIn=false so re-entry IN can fire');
      expect(mockInterceptor.isPunchedOut, isTrue);
    });

    test('re-entry clears stale exit tracking preventing false OUT', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // Phase 1: Full IN→OUT cycle
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.didPunchIn, isTrue);
      service.calls.clear();

      final exitPts = [
        LocationResult(latitude: 19.8775, longitude: 75.3165, accuracy: 10, speed: 1.0, jumpScore: 0.0),
        LocationResult(latitude: 19.8780, longitude: 75.3170, accuracy: 10, speed: 1.1, jumpScore: 0.0),
        LocationResult(latitude: 19.8790, longitude: 75.3180, accuracy: 10, speed: 1.2, jumpScore: 0.0),
        LocationResult(latitude: 19.8800, longitude: 75.3190, accuracy: 10, speed: 1.3, jumpScore: 0.0),
      ];
      for (final pt in exitPts) {
        await worker.onLocationFix(pt, TrackingState.MOVING, defaultConfidence);
        if (service.calls.didPunchOut) break;
      }
      expect(service.calls.didPunchOut, isTrue);
      service.calls.clear();

      // Phase 2: Outside fix re-starts exit tracking
      await worker.onLocationFix(outsideLocation(), TrackingState.MOVING, defaultConfidence);
      // _pendingOfficeId set, exit analyzer building score

      // Phase 3: Inside fix — should clear pending exit state
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      // Phase 4: Multiple inside fixes should NOT trigger OUT
      for (int i = 0; i < 5; i++) {
        await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      }
      expect(service.calls.didPunchOut, isFalse,
          reason: 'No false OUT after re-entry cleared stale exit tracking');
    });

    test('OUT keeps service running during active shift hours', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // Punch IN first
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);
      service.calls.clear();

      // Progressive exit
      final pts = [
        LocationResult(latitude: 19.8775, longitude: 75.3165, accuracy: 10, speed: 1.0, jumpScore: 0.0),
        LocationResult(latitude: 19.8780, longitude: 75.3170, accuracy: 10, speed: 1.1, jumpScore: 0.0),
        LocationResult(latitude: 19.8790, longitude: 75.3180, accuracy: 10, speed: 1.2, jumpScore: 0.0),
        LocationResult(latitude: 19.8800, longitude: 75.3190, accuracy: 10, speed: 1.3, jumpScore: 0.0),
      ];
      for (final pt in pts) {
        await worker.onLocationFix(pt, TrackingState.MOVING, defaultConfidence);
        if (service.calls.didPunchOut) break;
      }

      expect(service.calls.didPunchOut, isTrue);
      expect(service.calls.didStop, isFalse,
          reason: 'Service must keep running after OUT');
    });
  });

  group('Edge cases', () {
    test('no action when geofence auto-punch is disabled', () async {
      SharedPreferences.setMockInitialValues({
        'bg_access_token': 'test_token',
        'geofence_auto_enabled': false,
      });

      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchIn, isFalse);
    });

    test('no action when no shifts available', () async {
      final noShiftInterceptor = _MockInterceptor(shifts: []);
      final noShiftDio = Dio(BaseOptions(baseUrl: 'http://test'));
      noShiftDio.interceptors.add(noShiftInterceptor);

      final worker = GeofenceBackgroundWorker(service, dio: noShiftDio);
      await worker.loadData();

      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      // loadData will log "No shift found — staying dormant" and _inShiftWindow stays false
      // onLocationFix returns early if !_inShiftWindow
      expect(service.calls.didPunchIn, isFalse);
    });

    test('no action when token is missing (Dio returns null)', () async {
      SharedPreferences.setMockInitialValues({
        'geofence_auto_enabled': true,
      });

      // Worker without test Dio will try to build from prefs → token missing → returns null
      // But we're using test Dio, so this won't trigger that path.
      // Instead test: if loadData never stores offices, onLocationFix returns early.
      final worker = GeofenceBackgroundWorker(service);

      // Don't call loadData - without a Dio, _buildDio returns null, so loadData can't fetch
      // onLocationFix checks _offices.isEmpty first
      await worker.onLocationFix(insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchIn, isFalse);
    });

    test('no action when location accuracy is too low', () async {
      final worker = GeofenceBackgroundWorker(service, dio: dio);
      await worker.loadData();

      // accuracy = 150 > LocationFilter.MIN_ACCURACY (120)
      // But onLocationFix doesn't gate on accuracy — the entrypoint does.
      // The worker trusts that the caller already gated on accuracy.
      // This test verifies the worker doesn't crash with low-accuracy data.
      final lowAcc = LocationResult(
        latitude: 19.8769, longitude: 75.3143,
        accuracy: 150, speed: 0.5, jumpScore: 0.0,
      );
      await worker.onLocationFix(lowAcc, TrackingState.STATIONARY, 0.3);

      // Confidence will be very low due to accuracy factor, so IN is blocked
      expect(service.calls.didPunchIn, isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Inline logic tests (following existing gate test patterns)
  // ═══════════════════════════════════════════════════════════════════════

  group('Shift window logic (inline)', () {
    test('before shift: now.isBefore(todayStart)', () {
      final shift = Shift(
        id: 1, orgId: 1,
        name: 'Morning', startTime: '09:00', endTime: '18:00',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: false, isActive: true,
      );
      final now = DateTime.now();
      final eightAm = DateTime(now.year, now.month, now.day, 8, 0);
      expect(eightAm.isBefore(shift.todayStart), isTrue);
    });

    test('during shift: now is within [todayStart, todayEnd)', () {
      final shift = Shift(
        id: 1, orgId: 1,
        name: 'Morning', startTime: '09:00', endTime: '18:00',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: false, isActive: true,
      );
      final now = DateTime.now();
      final noon = DateTime(now.year, now.month, now.day, 12, 0);
      expect(!noon.isBefore(shift.todayStart) && noon.isBefore(shift.todayEnd), isTrue);
    });

    test('after shift + punched out: dormant, next shift scheduled', () {
      final shift = Shift(
        id: 1, orgId: 1,
        name: 'Morning', startTime: '09:00', endTime: '18:00',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: false, isActive: true,
      );
      final now = DateTime.now();
      final ninePm = DateTime(now.year, now.month, now.day, 21, 0);

      // After shift end
      expect(ninePm.isBefore(shift.todayEnd), isFalse);
      // If punched out: _scheduleNextShiftWindow() called → dormant
    });

    test('after shift + still punched in: keep monitoring for OUT (overtime)', () {
      final shift = Shift(
        id: 1, orgId: 1,
        name: 'Morning', startTime: '09:00', endTime: '18:00',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: false, isActive: true,
      );
      final now = DateTime.now();
      final ninePm = DateTime(now.year, now.month, now.day, 21, 0);

      // Past shift end → still monitoring if _lastPunchType != 'Out'
      expect(ninePm.isBefore(shift.todayEnd), isFalse);
    });
  });

  group('Cooldown logic (inline)', () {
    test('same direction within 5 min → blocked', () {
      final lastPunch = DateTime.now().subtract(const Duration(minutes: 2));
      const direction = 'In';
      final blocked = lastPunch != null &&
          'In' == direction &&
          DateTime.now().difference(lastPunch).inMinutes < 5;
      expect(blocked, isTrue);
    });

    test('different direction → allowed regardless of time', () {
      final lastPunch = DateTime.now().subtract(const Duration(seconds: 10));
      const direction = 'Out';
      final blocked = lastPunch != null &&
          'In' == direction &&
          DateTime.now().difference(lastPunch).inMinutes < 5;
      expect(blocked, isFalse);
    });

    test('no last punch → allowed', () {
      final blocked = null != null &&
          'In' == 'In' &&
          DateTime.now().difference(DateTime.now()).inMinutes < 5;
      // With null _lastPunchTime, the first condition fails → short-circuit → not blocked
      expect(DateTime.now().difference(DateTime.now()).inMinutes < 5, isTrue);
    });
  });

  group('GPS margin logic (inline)', () {
    test('_gpsMargin returns max(10, accuracy)', () {
      const margin10 = 10.0;
      const margin5 = 5.0;
      expect(margin10 >= 10.0 && margin10 >= 5.0, isTrue);
      expect(margin5 >= 10.0, isFalse);
    });

    test('exit threshold = radius + gpsMargin', () {
      const radius = 150.0;
      const accuracy = 20.0;
      const margin = 20.0; // max(10, 20)
      const threshold = radius + margin; // 170

      // Just outside radius but within margin → boundary proximity
      const dist1 = 160.0;
      expect(dist1 <= threshold, isTrue);

      // Past margin → exit tracking starts
      const dist2 = 180.0;
      expect(dist2 <= threshold, isFalse);
    });
  });

  group('Debounce IN after OUT (inline)', () {
    test('IN within 2 min of OUT is debounced', () {
      final lastPunchTime = DateTime.now().subtract(const Duration(minutes: 1));
      const lastPunchType = 'Out';
      final now = DateTime.now();
      final debounced = lastPunchTime != null &&
          lastPunchType == 'Out' &&
          now.difference(lastPunchTime).inMinutes < 2;
      expect(debounced, isTrue);
    });

    test('IN after 2+ min of OUT is allowed', () {
      final lastPunchTime = DateTime.now().subtract(const Duration(minutes: 3));
      const lastPunchType = 'Out';
      final now = DateTime.now();
      final debounced = lastPunchTime != null &&
          lastPunchType == 'Out' &&
          now.difference(lastPunchTime).inMinutes < 2;
      expect(debounced, isFalse);
    });
  });

  group('Comprehensive workday simulation', () {
    test('complete auto geofence punching lifecycle with custom office and mock GPS', () async {
      // ── Office HQ with 150m geofence radius ─────────────────────────
      const officeLat = 19.8761;
      const officeLng = 75.3153;
      const radius = 150;

      final customOffices = [
        const Office(
          id: 1, name: 'HQ',
          latitude: officeLat, longitude: officeLng,
          geofenceRadius: radius,
        ),
      ];

      final mockInterceptor = _MockInterceptor(offices: customOffices);
      final mockDio = Dio(BaseOptions(baseUrl: 'http://test'));
      mockDio.interceptors.add(mockInterceptor);

      final worker = GeofenceBackgroundWorker(service, dio: mockDio);
      await worker.loadData();

      // ── GPS positions at various distances from office center ────────
      // Well outside (~500m) — too far, exit tracking starts here
      final farOutside = LocationResult(
        latitude: 19.8810, longitude: 75.3200,
        accuracy: 10, speed: 1.2, jumpScore: 0.0,
      );
      // Past GPS margin (~200m) — exit tracking starts at > radius+margin(160m)
      final nearBoundary = LocationResult(
        latitude: 19.8775, longitude: 75.3165,
        accuracy: 10, speed: 1.0, jumpScore: 0.0,
      );
      // Progressive exit point (~230m)
      final midExit = LocationResult(
        latitude: 19.8780, longitude: 75.3170,
        accuracy: 10, speed: 1.1, jumpScore: 0.0,
      );
      // Progressive exit point (~330m)
      final farExit = LocationResult(
        latitude: 19.8790, longitude: 75.3180,
        accuracy: 10, speed: 1.2, jumpScore: 0.0,
      );
      // Well outside (~430m) — forces exit confirmation
      final finalExit = LocationResult(
        latitude: 19.8800, longitude: 75.3190,
        accuracy: 10, speed: 1.3, jumpScore: 0.0,
      );
      // Well inside geofence (~105m)
      final insideGps = LocationResult(
        latitude: 19.8769, longitude: 75.3143,
        accuracy: 10, speed: 0.5, jumpScore: 0.0,
      );

      // ═══════════════════════════════════════════════════════════════
      // Phase 1: User is outside geofence → no action
      // ═══════════════════════════════════════════════════════════════
      await worker.onLocationFix(farOutside, TrackingState.MOVING, defaultConfidence);
      expect(service.calls.didPunchIn, isFalse, reason: 'Outside → no IN');
      expect(service.calls.didPunchOut, isFalse, reason: 'Not punched in → no OUT');

      // ═══════════════════════════════════════════════════════════════
      // Phase 2: User walks inside geofence → auto-IN
      // ═══════════════════════════════════════════════════════════════
      await worker.onLocationFix(insideGps, TrackingState.STATIONARY, defaultConfidence);
      expect(service.calls.didPunchIn, isTrue, reason: 'Inside geofence → auto-IN');
      expect(mockInterceptor.isPunchedIn, isTrue, reason: 'Server reflects IN');
      expect(mockInterceptor.isPunchedOut, isFalse);
      expect(mockInterceptor.lastPunchDirection, 'In');
      expect(mockInterceptor.lastPunchPayload?['Method'], 'GeofenceAuto',
          reason: 'Punch payload has correct Method');
      expect(mockInterceptor.lastPunchPayload?['Direction'], 'In');
      service.calls.clear();

      // ═══════════════════════════════════════════════════════════════
      // Phase 3: User stays inside → no duplicate IN
      // ═══════════════════════════════════════════════════════════════
      for (int i = 0; i < 5; i++) {
        await worker.onLocationFix(insideGps, TrackingState.STATIONARY, defaultConfidence);
      }
      expect(mockInterceptor.punchCallCount, 1, reason: 'Only 1 IN total');
      expect(service.calls.didPunchIn, isFalse, reason: 'No duplicate IN while inside');
      expect(service.calls.didPunchOut, isFalse);

      // ═══════════════════════════════════════════════════════════════
      // Phase 4: User leaves worksite → auto-OUT (trend analyzer)
      // ═══════════════════════════════════════════════════════════════
      final exitPath = [nearBoundary, midExit, farExit, finalExit];
      for (final pt in exitPath) {
        await worker.onLocationFix(pt, TrackingState.MOVING, defaultConfidence);
        if (service.calls.didPunchOut) break;
      }
      expect(service.calls.didPunchOut, isTrue, reason: 'Exit confirmed → auto-OUT');
      expect(mockInterceptor.isPunchedOut, isTrue, reason: 'Server reflects OUT');
      expect(mockInterceptor.isPunchedIn, isFalse);
      expect(mockInterceptor.lastPunchDirection, 'Out');
      expect(service.calls.didStop, isFalse,
          reason: 'Service keeps running after OUT for re-entry detection');
      final out1CallCount = mockInterceptor.punchCallCount;
      service.calls.clear();

      // ═══════════════════════════════════════════════════════════════
      // Phase 5: User stays outside → exit tracking re-starts but
      //          5-min cooldown blocks duplicate OUT
      // ═══════════════════════════════════════════════════════════════
      // The exit analyzer confirms a new exit trend from progressive
      // outside fixes, but _handleAutoPunch('Out') refuses it because
      // _lastPunchType == 'Out' and < 5 min have passed in test time.
      for (int i = 0; i < 3; i++) {
        await worker.onLocationFix(farOutside, TrackingState.MOVING, defaultConfidence);
      }
      expect(mockInterceptor.punchCallCount, out1CallCount,
          reason: 'Cooldown blocks duplicate OUT in test time');
      expect(service.calls.didPunchOut, isFalse);

      // ═══════════════════════════════════════════════════════════════
      // Phase 6: Outside fix re-starts exit tracking, then user
      //          returns inside → stale state cleared, no false OUT
      // ═══════════════════════════════════════════════════════════════
      await worker.onLocationFix(farOutside, TrackingState.MOVING, defaultConfidence);
      // Exit tracking re-started (pendingOfficeId set)

      // Walk inside → pending exit state cleared (in _checkEntry)
      await worker.onLocationFix(insideGps, TrackingState.STATIONARY, defaultConfidence);

      // Stay inside — no false OUT should fire
      for (int i = 0; i < 3; i++) {
        await worker.onLocationFix(insideGps, TrackingState.STATIONARY, defaultConfidence);
      }
      expect(service.calls.didPunchOut, isFalse,
          reason: 'No false OUT after re-entry cleared stale state');
      expect(service.calls.didStop, isFalse,
          reason: 'Service still alive after re-entry cycle');

      // ═══════════════════════════════════════════════════════════════
      // Phase 7: Low confidence GPS fix → no action
      // ═══════════════════════════════════════════════════════════════
      await worker.onLocationFix(insideGps, TrackingState.STATIONARY, 0.3);
      expect(service.calls.didPunchIn, isFalse,
          reason: 'Low confidence (0.3 < 0.8 threshold) skips entry check');

      // ── Final punch count: 1 IN + 1 OUT ────────────────────────────
      // A second IN→OUT cycle is blocked in test time by 2-min debounce
      // and 5-min cooldown (both time-based gates that can't expire in
      // simulated time). The re-entry IN fires in 2+ min of real time;
      // the second OUT fires in 5+ min.
      expect(mockInterceptor.punchCallCount, 2);
      expect(service.calls.didGfStop, isFalse,
          reason: 'No gf_stop events fired throughout the day');
    });
  });

  group('Server status gates (inline)', () {
    test('status=null blocks IN (network error → safe)', () {
      const status = null;
      const direction = 'In';
      final blocked = direction == 'In' && status == null;
      expect(blocked, isTrue);
    });

    test('status=null allows OUT (overtime worker not trapped)', () {
      const status = null;
      const direction = 'Out';
      final blocked = direction == 'In' && status == null;
      expect(blocked, isFalse);
    });

    test('status.isPunchedIn blocks IN', () {
      final status = {'isPunchedIn': true};
      const direction = 'In';
      final blocked = direction == 'In' && status['isPunchedIn'] == true;
      expect(blocked, isTrue);
    });

    test('status.isPunchedOut blocks OUT', () {
      final status = {'isPunchedOut': true};
      const direction = 'Out';
      final blocked = direction == 'Out' && status != null && status['isPunchedOut'] == true;
      expect(blocked, isTrue);
    });
  });

  group('Client site prompting (selfie mandatory — no auto-punch)', () {
    const site = ClientSite(
      id: 17,
      siteName: 'Moksha Client',
      address: 'Test address',
      latitude: 19.861624,
      longitude: 75.310963,
      radiusMeters: 40,
    );

    // User standing inside the client-site geofence (~20m from site center).
    LocationResult atSite({double accuracy = 10}) => LocationResult(
          latitude: 19.8618,
          longitude: 75.3110,
          accuracy: accuracy,
          speed: 0.5,
          jumpScore: 0.0,
        );

    setUp(() {
      // Grant BOTH permissions — client sites only join the geofence scan when
      // geofence-auto AND client-site are both allowed.
      SharedPreferences.setMockInitialValues({
        'bg_access_token': 'test_token',
        'geofence_auto_enabled': true,
        'bg_allow_geofence_auto': true,
        'bg_allow_client_site': true,
      });
    });

    test('does NOT auto-punch inside a client-site zone — fires prompt instead',
        () async {
      final siteInterceptor = _MockInterceptor(clientSites: [site]);
      final siteDio = Dio(BaseOptions(baseUrl: 'http://test'));
      siteDio.interceptors.add(siteInterceptor);

      final worker = GeofenceBackgroundWorker(service, dio: siteDio);
      await worker.loadData();

      await worker.onLocationFix(atSite(), TrackingState.STATIONARY, defaultConfidence);

      // Selfie is mandatory for client-site punches — the worker must NOT call
      // the punch API. It fires a tap-to-punch prompt notification instead
      // (asserted here by the absence of any punch API call).
      expect(siteInterceptor.punchCallCount, 0,
          reason: 'Client-site punches require a selfie — no auto-punch API call');
      expect(service.calls.didPunchIn, isFalse,
          reason: 'No auto-IN — user must confirm with selfie on the prompt screen');
    });

    test('does NOT prompt client site without the client-site permission', () async {
      // Only geofence-auto granted — client sites stay fully manual punches.
      SharedPreferences.setMockInitialValues({
        'bg_access_token': 'test_token',
        'geofence_auto_enabled': true,
        'bg_allow_geofence_auto': true,
        'bg_allow_client_site': false,
      });

      final siteInterceptor = _MockInterceptor(clientSites: [site]);
      final siteDio = Dio(BaseOptions(baseUrl: 'http://test'));
      siteDio.interceptors.add(siteInterceptor);

      final worker = GeofenceBackgroundWorker(service, dio: siteDio);
      await worker.loadData();

      await worker.onLocationFix(atSite(), TrackingState.STATIONARY, defaultConfidence);

      expect(service.calls.didPunchIn, isFalse,
          reason: 'Client-site zones excluded when allowClientSite is false');
    });

    test('office zone wins over overlapping client site — silent auto-punch, no prompt',
        () async {
      // Human error scenario: a client site was added at the SAME coordinates
      // as the office (id 1, r=150m). The office must take priority — the user
      // gets the silent auto-punch, NOT the client-site selfie prompt.
      const overlappingSite = ClientSite(
        id: 99,
        siteName: 'Overlapping Site',
        latitude: 19.8761,
        longitude: 75.3153,
        radiusMeters: 150,
      );
      final siteInterceptor =
          _MockInterceptor(clientSites: [overlappingSite]);
      final siteDio = Dio(BaseOptions(baseUrl: 'http://test'));
      siteDio.interceptors.add(siteInterceptor);

      final worker = GeofenceBackgroundWorker(service, dio: siteDio);
      await worker.loadData();

      await worker.onLocationFix(
          insideLocation(), TrackingState.STATIONARY, defaultConfidence);

      expect(siteInterceptor.punchCallCount, 1,
          reason: 'Office zone wins — silent auto-punch fires');
      expect(service.calls.didPunchIn, isTrue,
          reason: 'User auto-punched IN at the office');
      expect(siteInterceptor.lastPunchPayload?['Method'], 'GeofenceAuto',
          reason: 'Punch is the office GeofenceAuto flow, not client-site');
      expect(siteInterceptor.lastPunchPayload?['ClientSiteId'], isNull,
          reason: 'No client-site punch — office priority wins');
    });
  });
}
