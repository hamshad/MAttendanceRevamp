import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geofence_service/geofence_service.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/app_logger.dart';
import '../../../core/utils/constants.dart';
import '../../../models/office.dart';
import '../../tracking/models/location_result.dart';
import '../../tracking/services/filters/confidence_scorer.dart';
import '../../tracking/services/filters/location_filter.dart';
import '../../tracking/services/filters/exit_trend_analyzer.dart';
import 'attendance_service.dart';
import 'geofence_debug_bus.dart';
import 'shift_service.dart';
import '../../../models/shift.dart';

/// Geofencing Auto Punch Service
///
/// Monitors office geofences and performs automatic Punch In/Out.
class GeofenceAutoPunchService {
  final AttendanceService _attendanceService;
  final FlutterLocalNotificationsPlugin _notifications;
  final VoidCallback? _onPunch;

  final LocationFilter _filter = LocationFilter();
  TrackingState _state = TrackingState.MOVING;

  bool _running = false;
  bool get isRunning => _running;

  List<Office> _offices = [];
  DateTime? _lastPunchTime;
  String? _lastPunchType;
  List<Shift> _shifts = [];
  
  // High-reliability EXIT tracking
  final ExitTrendAnalyzer _exitAnalyzer = ExitTrendAnalyzer();
  
  // State for continuous tracking of a pending exit event
  Geofence? _pendingExitGeofence;
  double? _pendingExitRadius;
  
  // Independent exit polling (bypasses geofence service's mock location filter)
  StreamSubscription<geo.Position>? _exitPollSub;
  Timer? _exitPollTimer;
  DateTime? _lastStreamFix;
  bool _geofenceStarted = false;

  static const String _enabledKey = 'auto_punch_enabled';

  GeofenceAutoPunchService({
    required Dio dio,
    required FlutterLocalNotificationsPlugin notifications,
    VoidCallback? onPunch,
  })  : _attendanceService = AttendanceService(dio),
        _notifications = notifications,
        _onPunch = onPunch;

  static bool get isEnabled =>
      Hive.box(AppConstants.geofenceSettingsBox).get(_enabledKey, defaultValue: true);

  static Future<void> setEnabled(bool value) async {
    await Hive.box(AppConstants.geofenceSettingsBox).put(_enabledKey, value);
  }

  static bool get hasUserToggled =>
      _box.containsKey(_enabledKey);

  static Box get _box => Hive.box(AppConstants.geofenceSettingsBox);

  // ── Debug helper ────────────────────────────────────────────────────────────

  /// Emit a debug event to [GeofenceDebugBus] so it appears in the dev console.
  /// Also logs to terminal for easier debugging.
  void _emit(
    String event, {
    LocationResult? loc,
    String reason = '',
    String? geofenceId,
    double? distM,
    double? thresholdM,
    double? confidence,
    String? eligibility,
  }) {
    // 1. Log to Terminal
    final logMsg = StringBuffer('[GF_AUTO] $event: $reason');
    if (geofenceId != null) logMsg.write(' | Zone: $geofenceId');
    if (distM != null) logMsg.write(' | Dist: ${distM.toStringAsFixed(1)}m');
    if (thresholdM != null) logMsg.write(' / ${thresholdM.toStringAsFixed(1)}m (Punch Threshold: ${(thresholdM * 1.5).toStringAsFixed(1)}m)');
    if (confidence != null) logMsg.write(' | Conf: ${(confidence * 100).toStringAsFixed(0)}%');
    AppLogger.d(logMsg.toString());

    // 2. Broadcast to UI Dev Console
    GeofenceDebugBus.emit({
      'ts':          DateTime.now().toIso8601String(),
      'event':       event,
      'state':       _state.name,
      'lat':         loc?.latitude,
      'lng':         loc?.longitude,
      'accuracy':    loc?.accuracy,
      'speed':       loc?.speed,
      'reason':      reason,
      'geofenceId':  geofenceId,
      'distM':       distM,
      'thresholdM':  thresholdM,
      'confidence':  confidence,
      'eligibility': eligibility,
    });
  }

  /// GPS accuracy-aware margin in metres.
  ///
  /// Returns a buffer that accounts for typical GPS inaccuracy so that
  /// boundary-level fluctuations don't trigger false transitions.  The margin
  /// scales with the reported accuracy (minimum 10 m).
  static double _gpsMargin(double accuracy) => (accuracy * 2.0).clamp(10.0, 250.0);

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Starts the geofence monitoring.
  Future<bool> start() async {
    if (_running) return true;
    print('[GF_AUTO] Starting monitoring service');
    AppLogger.i('GEOFENCE_AUTO: Starting monitoring service');

    try {
      _offices = await _attendanceService.fetchOffices();
      print('[GF_AUTO] Fetched ${_offices.length} offices');

      // Fetch and cache shifts
      final shiftService = ShiftService(_attendanceService.dio);
      final fetched = await shiftService.fetchShifts();
      if (fetched.isNotEmpty) {
        _shifts = fetched;
        await ShiftService.cacheShifts(fetched);
        print('[GF_AUTO] Fetched ${fetched.length} shifts');
      } else {
        _shifts = ShiftService.loadCachedShifts();
        print('[GF_AUTO] Using ${_shifts.length} cached shifts (API returned empty)');
      }

      if (_offices.isEmpty) {
        _emit('gf_skip', reason: 'No offices returned by API — service will not start');
        return false;
      }

      // Try to start the native GeofenceService (may fail on emulators or
      // devices without Google Play Services).  Failure here does NOT prevent
      // the independent exit polling from working.
      try {
        final geofences = _offices
            .where((o) => o.hasCoordinates && o.geofenceRadius != null)
            .map((o) => Geofence(
                  id: 'office-${o.id}',
                  latitude: o.latitude!,
                  longitude: o.longitude!,
                  radius: [
                    GeofenceRadius(
                      id: 'radius_main',
                      length: o.geofenceRadius!.toDouble(),
                    ),
                  ],
                ))
            .toList();

        if (geofences.isNotEmpty) {
          GeofenceService.instance.setup(
            interval: 5000,
            accuracy: 100,
            loiteringDelayMs: 1000,
            statusChangeDelayMs: 3000,
            useActivityRecognition: true,
            allowMockLocations: false,
            printDevLog: kDebugMode,
            geofenceRadiusSortType: GeofenceRadiusSortType.DESC,
          );

          GeofenceService.instance.addGeofenceStatusChangeListener(_onGeofenceStatusChanged);
          GeofenceService.instance.addLocationChangeListener(_onLocationChanged);

          await GeofenceService.instance.start(geofences);
          _geofenceStarted = true;
          print('[GF_AUTO] Native GeofenceService started (${geofences.length} zones)');
        }
      } catch (e) {
        // Native geofence failed — polling still works independently.
        print('[GF_AUTO] Native GeofenceService failed (expected on emulators): $e');
      }

      _running = true;

      // Always start independent exit polling (bypasses mock-location filter,
      // works on emulators and devices where native geofencing is unreliable).
      _startExitPolling();
      print('[GF_AUTO] Independent exit polling started');

      _emit(
        'gf_start',
        reason: 'Monitoring ${_offices.length} office(s) with independent exit polling',
      );

      _checkInitialProximityRaw();

      AppLogger.i('GEOFENCE_AUTO: Monitoring active for ${_offices.length} offices');
      print('[GF_AUTO] Service fully started');
      return true;
    } catch (e) {
      AppLogger.e('GEOFENCE_AUTO: Failed to start service', e);
      _emit('gf_punch_err', reason: 'Service failed to start: $e');
      print('[GF_AUTO] FAILED to start: $e');
      return false;
    }
  }

  /// Stops the monitoring.
  Future<void> stop() async {
    if (!_running) return;
    _stopExitPolling();
    if (_geofenceStarted) {
      try {
        GeofenceService.instance.removeGeofenceStatusChangeListener(_onGeofenceStatusChanged);
        GeofenceService.instance.removeLocationChangeListener(_onLocationChanged);
        await GeofenceService.instance.stop();
      } catch (_) {}
      _geofenceStarted = false;
    }
    _running = false;
    _emit('gf_stop', reason: 'Geofence monitoring stopped');
    AppLogger.i('GEOFENCE_AUTO: Monitoring stopped');
    print('[GF_AUTO] Stopped');
  }

  /// Restarts for re-evaluation.
  Future<void> restart() async {
    if (!_running) return;
    await stop();
    await start();
  }

  // ── Internal Handlers ───────────────────────────────────────────────────────

  /// Shared processing for a raw location point.
  ///
  /// Called from both [GeofenceService]'s [_onLocationChanged] and the
  /// independent exit polling timer.
  void _processPosition(LocationResult raw) {
    print('[GF_AUTO] _processPosition: lat=${raw.latitude.toStringAsFixed(5)} lng=${raw.longitude.toStringAsFixed(5)} acc=${raw.accuracy.toStringAsFixed(1)}m');

    if (raw.accuracy > 250) {
      print('[GF_AUTO] Accuracy ${raw.accuracy.toStringAsFixed(0)}m > 250m — dropping fix');
      return;
    }
    _persistNearestOfficeForDebug(raw);

    final filtered = _filter.process(raw, _state);
    if (filtered != null) {
      final prevState = _state;
      _state = _filter.evaluateState(filtered, _state);

      if (_state != prevState) {
        print('[GF_AUTO] State: ${prevState.name} → ${_state.name}  spd:${filtered.speed.toStringAsFixed(1)}m/s');
        _emit(
          'gf_state',
          loc: filtered,
          reason: 'State: ${prevState.name} → ${_state.name}  '
              'spd:${filtered.speed.toStringAsFixed(1)}m/s',
        );
      }

      final score = ConfidenceScorer.score(filtered, _state, jumpScore: filtered.jumpScore);

      if (_pendingExitGeofence != null && _pendingExitRadius != null) {
        final distToPending = geo.Geolocator.distanceBetween(
          filtered.latitude,
          filtered.longitude,
          _pendingExitGeofence!.latitude,
          _pendingExitGeofence!.longitude,
        );
        print('[GF_AUTO] Feeding exit trend: dist=${distToPending.toStringAsFixed(1)}m pending_radius=${_pendingExitRadius!.toStringAsFixed(0)}m score=${_exitAnalyzer.score.toStringAsFixed(2)}');

        _processExitTrend(
          _pendingExitGeofence!,
          _pendingExitRadius!,
          filtered,
          distToPending,
          score,
        );
      } else {
        final nearest = _getNearestOfficeInfo(filtered);
        print('[GF_AUTO] No pending exit. Nearest: dist=${nearest?['dist']?.toStringAsFixed(1)}m radius=${nearest?['radius']?.toStringAsFixed(0)}m');

        // Before shift start: skip geofence proximity checks entirely
        // to conserve battery and avoid unnecessary GPS processing.
        final applicableShift = _findApplicableShift();
        final beforeShift = applicableShift != null &&
            _lastPunchType != 'In' &&
            DateTime.now().isBefore(applicableShift.todayStart);

        if (!beforeShift) {
          _checkAndAutoTriggerExit(filtered, score);
        }

        // Auto-IN via polling: if user could be inside an office zone
        // (accounting for GPS inaccuracy) with good confidence, call the API.
        // The server gate in _handleAutoPunch prevents duplicates.
        // This recovers from false exits and handles "walked back inside after
        // lunch" without relying solely on native geofence ENTER/DWELL events.
        if (!beforeShift &&
            score >= ConfidenceScorer.CONFIDENCE_THRESHOLD &&
            _lastPunchType != 'In' &&
            nearest != null) {
          final dist = nearest['dist']!;
          final radiusVal = nearest['radius']!;
          // Use only the raw radius for entry — no GPS margin. You must
          // actually be inside the office to auto-punch in.  GPS margin is
          // still applied for exit (radius + margin) to prevent false exits.
          if (dist <= radiusVal) {
            // Debounce: don't auto-IN for 2 minutes after an auto-OUT to
            // prevent rapid oscillation when GPS fluctuates near the boundary.
            final now = DateTime.now();
            if (_lastPunchTime != null &&
                _lastPunchType == 'Out' &&
                now.difference(_lastPunchTime!).inMinutes < 2) {
              print('[GF_AUTO] Auto-IN debounced: only ${now.difference(_lastPunchTime!).inSeconds}s since last OUT');
            } else {
              final officeId = _findOfficeIdByDist(filtered);
              if (officeId != null) {
                _handleAutoPunch('In', filtered, 'office-$officeId', score);
              }
            }
          }
        }

        _emit(
          'gf_state', 
          loc: filtered, 
          distM: nearest?['dist'], 
          thresholdM: nearest?['radius'],
        );
      }
    } else {
      final nearest = _getNearestOfficeInfo(raw);
      final reason = raw.accuracy > LocationFilter.MIN_ACCURACY
          ? 'Accuracy ${raw.accuracy.toStringAsFixed(1)}m > ${LocationFilter.MIN_ACCURACY}m gate'
          : 'Rejected by filter (acc:${raw.accuracy.toStringAsFixed(1)}m)';
      print('[GF_AUTO] FILTER REJECTED: $reason');
      _emit('gf_reject', loc: raw, distM: nearest?['dist'], reason: '🛡️ OUTLIER REJECTED: $reason');
    }
  }

  /// Called by [GeofenceService] on every location tick.
  void _onLocationChanged(Location location) {
    _processPosition(LocationResult(
      latitude: location.latitude,
      longitude: location.longitude,
      accuracy: location.accuracy,
      speed: location.speed,
      timestamp: location.timestamp,
    ));
  }

  /// Polls position using two independent sources:
  ///
  /// 1. **5 s timer** with [getCurrentPosition] — reliable in background even
  ///    on aggressive OEMs that kill stream subscriptions (each call is a
  ///    fresh GPS chip request).
  /// 2. **Hot GPS stream** ([getPositionStream]) — provides ±14 m accuracy
  ///    when the OS allows background streams, enabling faster exit/entry
  ///    decisions.
  ///
  /// Both paths feed [_processPosition]; the Kalman filter naturally
  /// deduplicates near-identical fixes.
  void _startExitPolling() {
    _exitPollSub?.cancel();
    _exitPollTimer?.cancel();

    // ── Primary: 5s timer (reliable in background) ──
    Future<void> poll() async {
      if (!_running) return;

      // Skip when stream is alive — its ±14m fixes would only be
      // contaminated by the timer's 80‑150m positions in the filter.
      if (_lastStreamFix != null &&
          DateTime.now().difference(_lastStreamFix!).inSeconds < 5) {
        if (_running) {
          _exitPollTimer = Timer(const Duration(seconds: 5), poll);
        }
        return;
      }

      try {
        final pos = await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
          ),
        );
        if (!_running) return;
        print('[GF_AUTO] Poll position: lat=${pos.latitude.toStringAsFixed(5)} lng=${pos.longitude.toStringAsFixed(5)} acc=${pos.accuracy.toStringAsFixed(1)}m');
        _processPosition(LocationResult(
          latitude: pos.latitude,
          longitude: pos.longitude,
          accuracy: pos.accuracy,
          speed: pos.speed,
          timestamp: pos.timestamp,
        ));
      } catch (e) {
        print('[GF_AUTO] Poll error: $e');
      }
      if (_running) {
        _exitPollTimer = Timer(const Duration(seconds: 5), poll);
      }
    }
    poll();

    // ── Secondary: hot GPS stream (better accuracy when alive) ──
    _exitPollSub = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      if (!_running) return;
      _lastStreamFix = DateTime.now();
      print('[GF_AUTO] Stream position: lat=${pos.latitude.toStringAsFixed(5)} lng=${pos.longitude.toStringAsFixed(5)} acc=${pos.accuracy.toStringAsFixed(1)}m');
      _processPosition(LocationResult(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
        timestamp: pos.timestamp,
      ));
    });
  }

  void _stopExitPolling() {
    _exitPollTimer?.cancel();
    _exitPollTimer = null;
    _exitPollSub?.cancel();
    _exitPollSub = null;
    _lastStreamFix = null;
  }

  /// Find the applicable shift from the local cache.
  /// Tries: first active shift → first shift → null.
  Shift? _findApplicableShift() {
    if (_shifts.isEmpty) return null;
    if (_shifts.length == 1) return _shifts.first;
    for (final s in _shifts) {
      if (s.isActive) return s;
    }
    return _shifts.first;
  }

  /// Finds the office ID whose geofence center is closest to [loc].
  /// Returns `null` if no office has coordinates.
  int? _findOfficeIdByDist(LocationResult loc) {
    if (_offices.isEmpty) return null;
    int? bestId;
    double bestDist = double.infinity;
    for (final o in _offices) {
      if (!o.hasCoordinates || o.geofenceRadius == null) continue;
      final d = geo.Geolocator.distanceBetween(
        loc.latitude, loc.longitude, o.latitude!, o.longitude!,
      );
      if (d < bestDist) {
        bestDist = d;
        bestId = o.id;
      }
    }
    return bestId;
  }

  Map<String, double>? _getNearestOfficeInfo(LocationResult loc) {
    if (_offices.isEmpty) return null;
    Office? nearest;
    double nearestDist = double.infinity;
    for (final o in _offices) {
      if (!o.hasCoordinates) continue;
      final d = geo.Geolocator.distanceBetween(
        loc.latitude, loc.longitude, o.latitude!, o.longitude!,
      );
      if (d < nearestDist) {
        nearestDist = d;
        nearest = o;
      }
    }
    if (nearest == null) return null;
    return {
      'dist': nearestDist,
      'radius': nearest.geofenceRadius?.toDouble() ?? 0.0,
    };
  }

  /// Checks if the user is outside any office geofence and auto-triggers
  /// exit trend analysis — even if the native EXIT event never fires.
  ///
  /// This makes the 5s polling the PRIMARY exit trigger, with the native
  /// geofence EXIT event as a secondary/supplementary trigger.
  void _checkAndAutoTriggerExit(LocationResult filtered, double confidence) {
    if (_offices.isEmpty || _pendingExitGeofence != null) {
      print('[GF_AUTO] Auto-trigger skipped: offices=${_offices.length} pending=${_pendingExitGeofence != null}');
      return;
    }

    Office? nearestOffice;
    double nearestDist = double.infinity;
    for (final o in _offices) {
      if (!o.hasCoordinates || o.geofenceRadius == null) continue;
      final d = geo.Geolocator.distanceBetween(
        filtered.latitude, filtered.longitude, o.latitude!, o.longitude!,
      );
      if (d < nearestDist) {
        nearestDist = d;
        nearestOffice = o;
      }
    }

    if (nearestOffice == null) {
      print('[GF_AUTO] Auto-trigger skipped: no office with coordinates found');
      return;
    }

    // Accuracy-aware margin: GPS is never perfect. Being a few meters
    // "outside" the radius with ±10-20m accuracy doesn't mean the user left.
    if (nearestDist <= nearestOffice.geofenceRadius!) {
      print('[GF_AUTO] Auto-trigger skipped: inside radius (${nearestDist.toStringAsFixed(1)}m <= ${nearestOffice.geofenceRadius}m)');
      return;
    }
    final margin = _gpsMargin(filtered.accuracy);
    final exitThreshold = nearestOffice.geofenceRadius! + margin;
    if (nearestDist <= exitThreshold) {
      print('[GF_AUTO] Auto-trigger skipped: boundary proximity (${nearestDist.toStringAsFixed(1)}m <= ${exitThreshold.toStringAsFixed(0)}m exit threshold — gps margin ${margin.toStringAsFixed(0)}m)');
      _emit('gf_boundary', loc: filtered, distM: nearestDist,
        thresholdM: nearestOffice.geofenceRadius!.toDouble(),
        confidence: confidence,
        reason: 'Boundary proximity: ${nearestDist.toStringAsFixed(1)}m outside '
            '${nearestOffice.geofenceRadius}m radius — within gps margin '
            '(${margin.toStringAsFixed(0)}m) — NOT triggering exit',
      );
      return;
    }
    print('[GF_AUTO] AUTO-TRIGGERING EXIT: ${nearestDist.toStringAsFixed(1)}m outside ${nearestOffice.name} (radius ${nearestOffice.geofenceRadius}m, exit threshold ${exitThreshold.toStringAsFixed(0)}m)');

    _pendingExitGeofence = Geofence(
      id: 'office-${nearestOffice.id}',
      latitude: nearestOffice.latitude!,
      longitude: nearestOffice.longitude!,
      radius: [GeofenceRadius(id: 'radius_main', length: nearestOffice.geofenceRadius!.toDouble())],
    );
    _pendingExitRadius = nearestOffice.geofenceRadius!.toDouble();

    _emit(
      'gf_auto_exit_trigger',
      loc: filtered,
      geofenceId: _pendingExitGeofence!.id,
      distM: nearestDist,
      thresholdM: _pendingExitRadius,
      confidence: confidence,
      reason: 'Auto-triggered exit: ${nearestDist.toStringAsFixed(1)}m outside ${nearestOffice.name} '
          '(radius ${nearestOffice.geofenceRadius}m)',
    );

    _processExitTrend(
      _pendingExitGeofence!,
      _pendingExitRadius!,
      filtered,
      nearestDist,
      confidence,
    );
    print('[GF_AUTO] First exit trend feed complete. score=${_exitAnalyzer.score.toStringAsFixed(2)} confirmed=${_exitAnalyzer.isConfirmed}');
  }

  void _persistNearestOfficeForDebug(LocationResult loc) {
    if (_offices.isEmpty) return;
    Office? nearest;
    double nearestDist = double.infinity;
    for (final o in _offices) {
      if (!o.hasCoordinates) continue;
      final d = geo.Geolocator.distanceBetween(
        loc.latitude, loc.longitude, o.latitude!, o.longitude!,
      );
      if (d < nearestDist) {
        nearestDist = d;
        nearest = o;
      }
    }
    if (nearest == null) return;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setDouble('dbg_geofence_lat',    nearest!.latitude!);
      prefs.setDouble('dbg_geofence_lng',    nearest.longitude!);
      prefs.setDouble('dbg_geofence_radius', nearest.geofenceRadius?.toDouble() ?? 0.0);
      prefs.setString('dbg_geofence_name',   nearest.name);
    });
  }

  Future<void> _onGeofenceStatusChanged(
    Geofence geofence,
    GeofenceRadius geofenceRadius,
    GeofenceStatus geofenceStatus,
    Location location,
  ) async {
    // 1. Setup RAW data
    final raw = LocationResult(
      latitude: location.latitude,
      longitude: location.longitude,
      accuracy: location.accuracy,
      speed: location.speed,
      timestamp: location.timestamp,
    );
    final rawDist = geo.Geolocator.distanceBetween(
      raw.latitude, raw.longitude,
      geofence.latitude, geofence.longitude,
    );

    _emit(
      'gf_event',
      loc: raw,
      geofenceId: geofence.id,
      distM: rawDist,
      reason: '📡 ${geofenceStatus.name.toUpperCase()} trigger (Raw dist: ${rawDist.toStringAsFixed(1)}m, Acc: ${raw.accuracy.toStringAsFixed(1)}m)',
    );

    // 2. Process through Kalman Filter Pipeline
    final filtered = _filter.process(raw, _state);
    if (filtered == null) {
      _emit(
        'gf_acc_fail',
        loc: raw,
        geofenceId: geofence.id,
        reason: '❌ Filter rejected point: Accuracy ${raw.accuracy.toStringAsFixed(1)}m > ${LocationFilter.MIN_ACCURACY}m',
      );
      // For EXIT events, still set pending state so that future
      // onLocationChanged ticks (which may have better accuracy) can
      // pick up the exit confirmation.
      if (geofenceStatus == GeofenceStatus.EXIT) {
        _pendingExitGeofence = geofence;
        _pendingExitRadius = geofenceRadius.length;
      }
      return;
    }

    final filteredDist = geo.Geolocator.distanceBetween(
      filtered.latitude, filtered.longitude,
      geofence.latitude, geofence.longitude,
    );

    // 3. Confidence Check (Includes Soft Jump Rejection)
    final confidence = ConfidenceScorer.score(filtered, _state, jumpScore: filtered.jumpScore);
    final inEligibility = _getInEligibility(filteredDist, geofenceRadius.length, confidence);

    if (filtered.jumpScore > 0.5) {
      _emit(
        'gf_jump_soft',
        loc: filtered,
        geofenceId: geofence.id,
        distM: filteredDist,
        thresholdM: geofenceRadius.length,
        confidence: confidence,
        eligibility: inEligibility,
        reason: '⚠️ Soft Jump detected (Score: ${filtered.jumpScore.toStringAsFixed(2)}). Point kept but confidence reduced.',
      );
    }

    if (confidence < ConfidenceScorer.CONFIDENCE_THRESHOLD) {
      if (geofenceStatus != GeofenceStatus.EXIT) {
        _emit(
          'gf_conf_fail',
          loc: filtered,
          geofenceId: geofence.id,
          distM: filteredDist,
          thresholdM: geofenceRadius.length,
          confidence: confidence,
          eligibility: inEligibility,
          reason: '⚠️ Low confidence: ${(confidence * 100).toStringAsFixed(0)}% < threshold',
        );
        return;
      }
    }

    // 4. Handle ENTER / DWELL (Fast Punch-In)
    if (geofenceStatus == GeofenceStatus.ENTER || geofenceStatus == GeofenceStatus.DWELL) {
      _exitAnalyzer.reset();
      _pendingExitGeofence = null;
      _pendingExitRadius = null;

      if (filteredDist <= geofenceRadius.length) {
        if (confidence < ConfidenceScorer.CONFIDENCE_THRESHOLD) {
           _emit(
            'gf_conf_fail',
            loc: filtered,
            geofenceId: geofence.id,
            distM: filteredDist,
            thresholdM: geofenceRadius.length,
            confidence: confidence,
            eligibility: inEligibility,
            reason: '⚠️ Punch-In blocked: Confidence ${(confidence * 100).toStringAsFixed(0)}% < threshold',
          );
          return;
        }

        _emit(
          'gf_enter',
          loc: filtered,
          geofenceId: geofence.id,
          distM: filteredDist,
          thresholdM: geofenceRadius.length,
          confidence: confidence,
          eligibility: 'READY',
          reason: '✅ ENTER: Point at ${filteredDist.toStringAsFixed(1)}m inside ${geofenceRadius.length.toStringAsFixed(0)}m zone.',
        );
        await _handleAutoPunch('In', filtered, geofence.id, confidence);
      } else {
        _emit(
          'gf_blocked',
          loc: filtered,
          geofenceId: geofence.id,
          distM: filteredDist,
          thresholdM: geofenceRadius.length,
          eligibility: inEligibility,
          reason: '🛡 ENTER blocked: Filtered pos (${filteredDist.toStringAsFixed(1)}m) still outside radius',
        );
      }
    } 
    
    // 5. Handle EXIT (High Reliability Trend Analysis)
    else if (geofenceStatus == GeofenceStatus.EXIT) {
      _pendingExitGeofence = geofence;
      _pendingExitRadius = geofenceRadius.length;
      
      await _processExitTrend(
        geofence,
        geofenceRadius.length,
        filtered,
        filteredDist,
        confidence,
      );
    }
  }

  String _getInEligibility(double dist, double radius, double confidence) {
    if (dist > radius) return 'OUTSIDE_ZONE';
    if (confidence < ConfidenceScorer.CONFIDENCE_THRESHOLD) return 'LOW_CONF';
    return 'READY_FOR_IN';
  }

  String _getOutEligibility(double score) {
    if (score >= 1.0) return 'READY_FOR_OUT';
    return 'ANALYZING (${(score * 100).toStringAsFixed(0)}%)';
  }

  /// Evaluates movement trend to confirm exit.
  Future<void> _processExitTrend(
    Geofence geofence,
    double radius,
    LocationResult filtered,
    double filteredDist,
    double confidence,
  ) async {
    // 5a. User moved back inside? Reset immediately.
    if (filteredDist <= radius) {
      print('[GF_AUTO] EXIT RESET: dist=${filteredDist.toStringAsFixed(1)}m <= radius=${radius.toStringAsFixed(0)}m');
      if (_exitAnalyzer.score > 0) {
        _emit('gf_reset', reason: 'User moved back inside radius (${filteredDist.toStringAsFixed(1)}m). Resetting exit analyzer.');
      }
      _exitAnalyzer.reset(force: false);
      return;
    }

    // 5c. Update Trend Analyzer
    print('[GF_AUTO] EXIT TREND BEFORE: score=${_exitAnalyzer.score.toStringAsFixed(2)} outside=${_exitAnalyzer.moveAwayStreak}');
    _exitAnalyzer.update(filteredDist, radius, confidence, filtered.jumpScore, _state);
    print('[GF_AUTO] EXIT TREND AFTER:  score=${_exitAnalyzer.score.toStringAsFixed(2)} reasoning=${_exitAnalyzer.getReasoning()}');
    final outEligibility = _getOutEligibility(_exitAnalyzer.score);

    if (!_exitAnalyzer.checkConfirmation(filteredDist, radius)) {
      final streak = _exitAnalyzer.moveAwayStreak;
      String streakMsg = '';
      if (streak > 0) {
        final suffix = (streak == 1) ? 'st' : (streak == 2) ? 'nd' : (streak == 3) ? 'rd' : 'th';
        streakMsg = ' ($streak$suffix distance away)';
      }

      _emit(
        'gf_wait',
        loc: filtered,
        geofenceId: geofence.id,
        distM: filteredDist,
        thresholdM: radius,
        confidence: confidence,
        eligibility: outEligibility,
        reason: '⏳ EXIT analyzing: ${_exitAnalyzer.getReasoning()}$streakMsg',
      );
      return;
    }

    // 5e. Final Confirmation
    print('[GF_AUTO] EXIT CONFIRMED! score=${_exitAnalyzer.score.toStringAsFixed(2)} reasoning=${_exitAnalyzer.getReasoning()}');
    _emit(
      'gf_exit',
      loc: filtered,
      geofenceId: geofence.id,
      distM: filteredDist,
      thresholdM: radius,
      confidence: confidence,
      eligibility: 'READY',
      reason: '✅ EXIT confirmed! Trend analysis reached confidence threshold. '
             '(${_exitAnalyzer.getReasoning()})',
    );
    
    await _handleAutoPunch('Out', filtered, geofence.id, confidence);
    _exitAnalyzer.reset();
    _pendingExitGeofence = null;
    _pendingExitRadius = null;
  }

  Future<void> _handleAutoPunch(
    String direction,
    LocationResult location,
    String geofenceId,
    double confidence,
  ) async {
    final now = DateTime.now();

    // ── GATE 4: Cooldown ────────────────────────────────────────────────────
    if (_lastPunchTime != null &&
        _lastPunchType == direction &&
        now.difference(_lastPunchTime!).inMinutes < 5) {
      final minutesAgo = now.difference(_lastPunchTime!).inMinutes;
      _emit(
        'gf_skip',
        loc: location,
        geofenceId: geofenceId,
        reason: '⏱ Cooldown active: "$direction" punch was done ${minutesAgo}m ago '
            '(wait ${5 - minutesAgo}m more)',
      );
      return;
    }

    try {
      // ── GATE 6a: Shift hours check (local, no server) ───────────────────────
      // Block auto-IN before shift start using locally cached shifts.
      // No server ping needed — saves battery and prevents pre-shift network calls.
      if (direction == 'In' && _shifts.isNotEmpty) {
        final shift = _findApplicableShift();
        if (shift != null) {
          final shiftStart = shift.todayStart;
          if (now.isBefore(shiftStart)) {
            _emit(
              'gf_skip',
              loc: location,
              geofenceId: geofenceId,
              reason: '⏰ Before shift start (${shift.startTime}) — '
                  'auto-IN blocked (local check). Punch manually.',
            );
            return;
          }
        }
      }

      // ── GATE 5: Server status check ────────────────────────────────────────
      final status = await _attendanceService.getTodayStatus();
      if (direction == 'In') {
        if (status == null) {
          _emit(
            'gf_skip',
            loc: location,
            geofenceId: geofenceId,
            reason: '⏭ Skip Punch-In: cannot reach server to verify current status',
          );
          return;
        }
        if (status.isPunchedIn) {
          _emit(
            'gf_skip',
            loc: location,
            geofenceId: geofenceId,
            reason: '⏭ Skip Punch-In: server confirms already punched in today',
          );
          return;
        }
      }
      if (direction == 'Out') {
        if (status != null) {
          if (status.isPunchedOut) {
            _emit(
              'gf_skip',
              loc: location,
              geofenceId: geofenceId,
              reason: '⏭ Skip Punch-Out: server confirms already punched out today',
            );
            return;
          }
          if (status.hasNotPunchedIn) {
            _emit(
              'gf_skip',
              loc: location,
              geofenceId: geofenceId,
              reason: '⏭ Skip Punch-Out: server says no Punch-In exists for today',
            );
            return;
          }
        }
      }

      // ── GATE 6b: Shift hours check (with server's currentShift) ─────────────
      // Secondary validation using the server-reported shift name.
      if (direction == 'In' && _shifts.isNotEmpty) {
        final shiftName = status?.currentShift;
        if (shiftName != null) {
          final shift = ShiftService.findShiftByName(_shifts, shiftName);
          if (shift != null) {
            final shiftStart = shift.todayStart;
            if (now.isBefore(shiftStart)) {
              final diffMin = shiftStart.difference(now).inMinutes;
              _emit(
                'gf_skip',
                loc: location,
                geofenceId: geofenceId,
                reason: '⏰ Before shift start (${shift.startTime}) — '
                    'auto-IN blocked (${diffMin}m early). Punch manually.',
              );
              return;
            }
          }
        }
      }

      // ── All gates passed → call API ────────────────────────────────────────
      
      // Calculate exact distance to the specific geofence for the log dump
      double? actualDist;
      double? radius;
      try {
        final officeId = int.tryParse(geofenceId.replaceAll('office-', ''));
        final office = _offices.firstWhere((o) => o.id == officeId);
        if (office.hasCoordinates) {
          actualDist = geo.Geolocator.distanceBetween(
            location.latitude, location.longitude, 
            office.latitude!, office.longitude!
          );
          radius = office.geofenceRadius?.toDouble();
        }
      } catch (_) {}

      final dump = StringBuffer();
      dump.writeln('==================================================');
      dump.writeln('🚨 AUTO GEOFENCE API TRIGGERED: $direction 🚨');
      dump.writeln('==================================================');
      dump.writeln('Zone ID    : $geofenceId');
      dump.writeln('Distance   : ${actualDist?.toStringAsFixed(1) ?? 'Unknown'}m (Radius: ${radius?.toStringAsFixed(1) ?? 'Unknown'}m)');
      dump.writeln('Accuracy   : ${location.accuracy.toStringAsFixed(1)}m (Filter limit: ${LocationFilter.MIN_ACCURACY}m)');
      dump.writeln('Speed      : ${location.speed.toStringAsFixed(1)}m/s (Checked for jumps)');
      dump.writeln('Confidence : ${(confidence * 100).toStringAsFixed(1)}% (Threshold: ${(ConfidenceScorer.CONFIDENCE_THRESHOLD * 100).toStringAsFixed(1)}%)');
      dump.writeln('State      : ${_state.name}');
      dump.writeln('Lat/Lng    : ${location.latitude.toStringAsFixed(6)}, ${location.longitude.toStringAsFixed(6)}');
      dump.writeln('==================================================');
      
      debugPrint(dump.toString());
      AppLogger.d(dump.toString());

      _emit(
        'gf_api_call',
        loc: location,
        geofenceId: geofenceId,
        confidence: confidence,
        reason: '🌐 Calling punch API: direction=$direction  '
            'conf:${(confidence * 100).toStringAsFixed(0)}%  '
            'lat:${location.latitude.toStringAsFixed(5)}  '
            'lng:${location.longitude.toStringAsFixed(5)}',
      );

      final success = await _attendanceService.punch(
        method: 'GeofenceAuto',
        direction: direction,
        latitude: location.latitude,
        longitude: location.longitude,
        address: 'Auto-detected (Conf: ${(confidence * 100).toStringAsFixed(0)}%)',
      );

      if (success) {
        _lastPunchTime = now;
        _lastPunchType = direction;

        _emit(
          'gf_punch',
          loc: location,
          geofenceId: geofenceId,
          confidence: confidence,
          reason: '🎉 Punch-$direction SUCCESS  '
              'conf:${(confidence * 100).toStringAsFixed(0)}%',
        );

        _showNotification(
          'Auto Punch-$direction Success',
          'Confidence: ${(confidence * 100).toStringAsFixed(0)}% at office zone.',
        );

        _onPunch?.call();
      } else {
        _lastPunchTime = now;
        _lastPunchType = direction;
        _emit(
          'gf_punch_err',
          loc: location,
          geofenceId: geofenceId,
          reason: '❌ Punch-$direction API returned false (server rejected)',
        );
      }
    } catch (e) {
      _lastPunchTime = now;
      _lastPunchType = direction;
      _emit(
        'gf_punch_err',
        loc: location,
        geofenceId: geofenceId,
        reason: '❌ Punch-$direction error: $e',
      );
      AppLogger.e('GEOFENCE_AUTO: Error during $direction punch', e);
    }
  }

  Future<void> _checkInitialProximityRaw() async {
    _emit('gf_event', reason: 'Checking initial proximity on service start…');
    try {
      final pos = await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(accuracy: geo.LocationAccuracy.high),
      );

      final loc = LocationResult(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
        timestamp: pos.timestamp,
      );

      _emit(
        'gf_event',
        loc: loc,
        reason: 'Initial position fix  acc:${loc.accuracy.toStringAsFixed(1)}m',
      );

      final filtered = _filter.process(loc, _state);
      if (filtered == null) {
        _emit(
          'gf_acc_fail',
          loc: loc,
          reason: 'Initial position rejected by filter  '
              'acc:${loc.accuracy.toStringAsFixed(1)}m',
        );
        return;
      }

      final confidence = ConfidenceScorer.score(filtered, _state);
      if (confidence < ConfidenceScorer.CONFIDENCE_THRESHOLD) {
        _emit(
          'gf_conf_fail',
          loc: filtered,
          confidence: confidence,
          reason: 'Initial position confidence too low: '
              '${(confidence * 100).toStringAsFixed(0)}%',
        );
        return;
      }

      bool foundInside = false;
      for (final o in _offices) {
        if (!o.hasCoordinates || o.geofenceRadius == null) continue;
        final dist = geo.Geolocator.distanceBetween(
          filtered.latitude, filtered.longitude, o.latitude!, o.longitude!,
        );
        if (dist <= o.geofenceRadius!) {
          _emit(
            'gf_enter',
            loc: filtered,
            geofenceId: 'office-${o.id}',
            distM: dist,
            thresholdM: o.geofenceRadius!.toDouble(),
            confidence: confidence,
            reason: 'Already inside zone at startup: '
                '${dist.toStringAsFixed(1)}m < ${o.geofenceRadius}m → Punch-In',
          );
          await _handleAutoPunch('In', filtered, 'office-${o.id}', confidence);
          foundInside = true;
          break;
        } else {
          _emit(
            'gf_skip',
            loc: filtered,
            geofenceId: 'office-${o.id}',
            distM: dist,
            thresholdM: o.geofenceRadius!.toDouble(),
            reason: 'Outside zone at startup: '
                '${dist.toStringAsFixed(1)}m > ${o.geofenceRadius}m',
          );
        }
      }

      if (!foundInside) {
        _emit('gf_skip', reason: 'Not inside any office zone at startup — no auto punch-in');
      }
    } catch (e) {
      _emit('gf_punch_err', reason: 'Initial proximity check failed: $e');
    }
  }

  Future<void> _showNotification(String title, String body, {bool isAlert = false}) async {
    final android = AndroidNotificationDetails(
      'geofence_auto_punch',
      'Geofence Auto-Punch',
      importance: isAlert ? Importance.max : Importance.high,
      priority: isAlert ? Priority.max : Priority.high,
    );
    await _notifications.show(999, title, body, NotificationDetails(android: android));
  }
}
