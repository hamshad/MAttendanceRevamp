import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/api/punch_state_interceptor.dart';
import '../../../core/offline/offline_queue.dart';
import '../../../core/offline/offline_sync_manager.dart';
import '../../../core/utils/constants.dart';
import '../../../models/offline_punch.dart';
import '../../../models/office.dart';
import '../../../models/shift.dart';
import '../../tracking/models/location_result.dart';
import '../../tracking/services/filters/confidence_scorer.dart';
import '../../tracking/services/filters/exit_trend_analyzer.dart';
import 'geofence_scheduler.dart';

/// Geofence auto-punch logic designed to run inside the background isolate.
///
/// Created inside [FieldTrackingService]'s [_serviceEntrypoint].
/// Processes each GPS fix for proximity-based auto IN/OUT.
/// Fetches offices + shifts itself via HTTP (same token as field tracking).
class GeofenceBackgroundWorker {
  final ServiceInstance _service;

  late final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final ExitTrendAnalyzer _exitAnalyzer = ExitTrendAnalyzer();

  List<Office> _offices = [];
  List<Shift> _shifts = [];
  bool _dataLoaded = false;

  DateTime? _lastPunchTime;
  String? _lastPunchType;
  bool _punchInProgress = false;
  bool _isInsideGeofence = false;

  final Dio? _testDio;

  // Pending exit tracking state
  int? _pendingOfficeId;
  double? _pendingRadius;
  double _pendingLat = 0;
  double _pendingLng = 0;

  // One-fix debounce: after exit analyzer confirms, wait one more fix
  // before punching OUT. Catches false confirmations from single noisy fixes.
  bool _pendingOutConfirm = false;

  // Consecutive inside-fix counter — only allow exit tracking after
  // at least 3 fixes confirm the user is genuinely inside the geofence.
  int _consecutiveInsideFixes = 0;

  // Shift-window scheduling
  Timer? _shiftTimer;
  bool _inShiftWindow = false;
  DateTime? _cachedShiftStart;
  DateTime? _cachedShiftEnd;

  // Simulate-exit flag — set by UI debug button, skip entry for 30s
  DateTime? _simulateExitUntil;

  // Periodic punch-state restore guard — re-syncs with main isolate
  // SharedPreferences writes every 60s so the worker never goes stale.
  DateTime _lastRestoreCheck = DateTime(2000);

  static const _kPersistPunchType = 'gf_last_punch_type';
  static const _kPersistPunchTime = 'gf_last_punch_time';
  static const _kPersistPunchOffice = 'gf_last_punch_office';

  GeofenceBackgroundWorker(this._service, {Dio? dio}) : _testDio = dio {
    _service.on('simulate_exit').listen((_) {
      _simulateExitUntil = DateTime.now().add(const Duration(seconds: 60));
      debugPrint('[GF_BG] SIMULATE_EXIT: flag set — skip entry for 60s');
    });
  }

  /// Fetch offices and shifts from the API.
  Future<void> loadData() async {
    debugPrint('[GF_BG] loadData() called — _dataLoaded=$_dataLoaded');
    if (_dataLoaded) return;

    // Check if a native AlarmManager alarm fired while we were not running.
    // If so, immediately treat this as a shift-start event.
    final missedAlarm = await GeofenceScheduler.consumeMissedAlarmFlag();
    if (missedAlarm) {
      debugPrint('[GF_BG] Native alarm was missed — forcing shift window open');
      _inShiftWindow = true;
    }

    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[GF_BG] No token — skipping data load');
        return;
      }
      _offices = await _fetchOffices(dio);
      _shifts = await _fetchShifts(dio);
      _dataLoaded = true;
      debugPrint('[GF_BG] Loaded ${_offices.length} offices, ${_shifts.length} shifts — calling scheduleShiftWindow');
      _scheduleShiftWindow();
      _proactivelyScheduleAlarm();
      _restorePunchState();
      await _syncPunchStateFromServer(dio);
      debugPrint('[GF_BG] loadData complete');
    } catch (e) {
      debugPrint('[GF_BG] Failed to load data: $e');
    }
  }

  /// Fetch todayStatus from the server once and persist the current punch
  /// state so the notification shows the correct IN/OUT from the very first
  /// GPS fix (or immediately if the user never moves).
  Future<void> _syncPunchStateFromServer(Dio dio) async {
    try {
      final resp = await dio.get(ApiEndpoints.todayStatus);
      final status = resp.data['data'] as Map<String, dynamic>?;
      if (status == null) return;

      final prefs = await SharedPreferences.getInstance();
      if (status['isPunchedIn'] == true) {
        _lastPunchType = 'In';
        await prefs.setString(_kPersistPunchType, 'In');
        debugPrint('[GF_BG] Synced punch state — IN (from server)');
      } else if (status['isPunchedOut'] == true) {
        _lastPunchType = 'Out';
        await prefs.setString(_kPersistPunchType, 'Out');
        debugPrint('[GF_BG] Synced punch state — OUT (from server)');
      }
    } catch (e) {
      debugPrint('[GF_BG] Failed to sync punch state from server: $e');
    }
  }

  Future<void> _restorePunchState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _lastPunchType = prefs.getString(_kPersistPunchType);
      final timeStr = prefs.getString(_kPersistPunchTime);
      if (timeStr != null) _lastPunchTime = DateTime.tryParse(timeStr);

      // If no longer punched in, reset geofence state so entry detection re-runs
      if (_lastPunchType != 'In') {
        _isInsideGeofence = false;
        _consecutiveInsideFixes = 0;
      }

      debugPrint('[GF_BG] _restorePunchState: type=$_lastPunchType, time=$_lastPunchTime, isInside=$_isInsideGeofence');
    } catch (_) {
      debugPrint('[GF_BG] _restorePunchState failed');
    }
  }

  Future<void> _persistPunchState(String type, DateTime time, {String? officeName}) async {
    _lastPunchType = type;
    _lastPunchTime = time;
    debugPrint('[GF_BG] _persistPunchState: type=$type, time=$time, office=$officeName');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPersistPunchType, type);
      await prefs.setString(_kPersistPunchTime, time.toIso8601String());
      if (officeName != null) {
        await prefs.setString(_kPersistPunchOffice, officeName);
      }
    } catch (_) {}
  }

  /// Must be called for every GPS fix that passes the accuracy gate.
  Future<void> onLocationFix(
    LocationResult filtered,
    TrackingState state,
    double confidence,
  ) async {
    final fixAcc = filtered.accuracy;
    final fixConf = confidence;
    final fixJump = filtered.jumpScore;
    debugPrint('[GF_BG] FIX: lat=${filtered.latitude.toStringAsFixed(5)} lng=${filtered.longitude.toStringAsFixed(5)} acc=${fixAcc.toStringAsFixed(1)}m conf=${fixConf.toStringAsFixed(2)} jump=${fixJump.toStringAsFixed(2)} inShift=$_inShiftWindow inside=$_isInsideGeofence pendingOut=$_pendingOfficeId');
    if (_offices.isEmpty) {
      debugPrint('[GF_BG] GATE FAIL: _offices is empty');
      return;
    }
    if (!await _isEnabled()) {
      debugPrint('[GF_BG] GATE FAIL: _isEnabled() returned false');
      return;
    }
    if (!_inShiftWindow) {
      // User may have manually punched in after shift end (overtime) or
      // before the shift timer activated. Re-read and re-evaluate — if the
      // main isolate wrote 'In' after our last check, the worker should
      // activate for exit monitoring.
      //
      // Note: we do NOT return early here even if still outside shift
      // window. Entry detection (auto-IN) always runs regardless of shift
      // hours — matching the original proximity-based behavior at commit
      // 55dd962. Only exit tracking is gated by shift window.
      await _restorePunchState();
      _scheduleShiftWindow();
    }

    // Periodic restore — re-sync punch state from SharedPreferences every 60s
    // so the worker knows about manual punches made by the main isolate.
    if (DateTime.now().difference(_lastRestoreCheck).inSeconds >= 60) {
      await _restorePunchState();
      _lastRestoreCheck = DateTime.now();
    }

    // ── Accuracy gate ──────────────────────────────────────────────────
    // GPS accuracy > 250m means position error circle larger than any
    // meaningful geofence decision. Drop the fix entirely — preserves
    // current IN/OUT state until good GPS returns.
    if (filtered.accuracy > 250) {
      debugPrint('[GF_BG] GATE FAIL: acc ${filtered.accuracy.toStringAsFixed(0)}m > 250m — DROP');
      return;
    }
    debugPrint('[GF_BG] GATE PASS: acc ${filtered.accuracy.toStringAsFixed(1)}m ≤ 250m');

    // ── Simulate exit (debug) — skip entry for 60s ───────────────────────
    final simulateActive = _simulateExitUntil != null && DateTime.now().isBefore(_simulateExitUntil!);
    if (_simulateExitUntil != null && !simulateActive) {
      _simulateExitUntil = null;
      debugPrint('[GF_BG] SIMULATE_EXIT: expired — entry re-enabled');
    }
    if (simulateActive && _pendingOfficeId == null) {
      _pendingOfficeId = null; // force re-init
      double nearestDist = double.infinity;
      Office? nearest;
      for (final o in _offices) {
        if (!o.hasCoordinates || o.geofenceRadius == null) continue;
        final d = geo.Geolocator.distanceBetween(
          filtered.latitude, filtered.longitude, o.latitude!, o.longitude!,
        );
        if (d < nearestDist) { nearestDist = d; nearest = o; }
      }
      if (nearest != null) {
        debugPrint('[GF_BG] SIMULATE_EXIT: forcing exit for ${nearest.name} dist=$nearestDist');
        _isInsideGeofence = false;
        _pendingOfficeId = nearest.id;
        _pendingLat = nearest.latitude!;
        _pendingLng = nearest.longitude!;
        _pendingRadius = nearest.geofenceRadius!.toDouble();
        _exitAnalyzer.reset();
        _consecutiveInsideFixes = 3;
      }
    }

    // ── Entry check ──────────────────────────────────────────────────────
    // Always check entry on every high-confidence fix — the server status
    // gate in _handleAutoPunch ('In') prevents duplicate INs.
    if (!simulateActive && confidence >= ConfidenceScorer.CONFIDENCE_THRESHOLD) {
      await _checkEntry(filtered, confidence);
    }

    // Track consecutive inside fixes — only allow exit after 3+ inside.

    if (_isInsideGeofence) {
      _consecutiveInsideFixes = (_consecutiveInsideFixes + 1).clamp(0, 20);
    } else {
      if (_consecutiveInsideFixes > 0) {
        debugPrint('[GF_BG] STATE: insideFixes reset (was $_consecutiveInsideFixes) — not inside');
      }
      _consecutiveInsideFixes = 0;
    }

    // ── Exit check ───────────────────────────────────────────────────────
    if (_pendingOfficeId != null) {
      await _processExitTrend(filtered, confidence);
    } else {
      await _checkExit(filtered, confidence);
    }
    debugPrint('[GF_BG] ─── FIX END ───');
  }

  /// Find the applicable shift and set the shift window.
  /// Before shift: schedule a timer to activate at start.
  /// After shift + punched out: stay dormant until next shift.
  void _scheduleShiftWindow() {
    _shiftTimer?.cancel();
    _shiftTimer = null;

    final shift = _findCurrentShift();
    if (shift == null) {
      debugPrint('[GF_BG] No shift found — staying dormant');
      _inShiftWindow = false;
      return;
    }

    final now = DateTime.now();
    _cachedShiftStart = shift.todayStart;
    _cachedShiftEnd = shift.todayEnd;

    if (now.isBefore(_cachedShiftStart!)) {
      // Before shift → sleep until shift start
      _inShiftWindow = false;
      final duration = _cachedShiftStart!.difference(now);
      _shiftTimer = Timer(duration, () {
        _inShiftWindow = true;
        debugPrint('[GF_BG] Shift window started (${shift.name})');
      });
      debugPrint('[GF_BG] ${duration.inMinutes}m until shift ${shift.name} — dormant');
    } else if (now.isBefore(_cachedShiftEnd!)) {
      // Inside shift window — clear any stale shift-ended flag from
      // a previous day (safety net if shift-start alarm was missed).
      _inShiftWindow = true;
      SharedPreferences.getInstance()
          .then((sp) => sp.remove('gf_shift_ended'));
      debugPrint('[GF_BG] In shift window (${shift.name}) — monitoring active');
    } else {
      // After shift end
      _inShiftWindow = false;
      if (_lastPunchType == 'Out') {
        debugPrint('[GF_BG] Shift ended and punched out — stopping service');
        SharedPreferences.getInstance().then((sp) => sp.setBool('gf_shift_ended', true));
        GeofenceScheduler.scheduleNextShift(shift)
            .then((_) => _service.invoke('stop'))
            .catchError((_) {});
      } else {
        // Still punched in (overtime) — keep monitoring until OUT
        debugPrint('[GF_BG] After shift end but still punched in — monitoring for OUT');
        _inShiftWindow = true;
      }
    }
  }

  /// Register a Workmanager alarm for the next shift start and a short-term
  /// restart safety net during active shift hours. The restart alarm ensures
  /// the service resumes within ~15 min if the process is killed mid-shift.
  void _proactivelyScheduleAlarm() {
    if (_shifts.isEmpty) return;
    final shift = _findCurrentShift();
    if (shift == null) return;
    GeofenceScheduler.scheduleNextShift(shift)
        .then((_) => debugPrint('[GF_BG] Proactive next-shift alarm scheduled'))
        .catchError((_) {});

    if (_inShiftWindow) {
      GeofenceScheduler.scheduleRestartAlarm()
          .then((_) => debugPrint('[GF_BG] Restart safety-net alarm scheduled'))
          .catchError((_) {});
    }
  }

  /// Find the currently applicable shift from cached data.
  /// Tries: cached shift name → first active shift → first shift.
  Shift? _findCurrentShift() {
    if (_shifts.isEmpty) return null;
    if (_shifts.length == 1) return _shifts.first;

    // Fall back to first active shift
    for (final s in _shifts) {
      if (s.isActive) return s;
    }
    return _shifts.first;
  }

  Future<void> _checkEntry(LocationResult filtered, double confidence) async {
    // Skip entry during simulated exit window
    if (_simulateExitUntil != null && DateTime.now().isBefore(_simulateExitUntil!)) {
      return;
    }
    // Don't clear pending exit state while one-fix debounce is active
    if (_pendingOutConfirm) {
      return;
    }
    // Clear stale shift-ended flag before entry check so a missed shift-start
    // alarm never blocks next-day auto-punch-IN.  The 2-minute debounce below
    // still prevents immediate re-punch after shift-end OUT.
    await _clearShiftEndedFlag();
    final now = DateTime.now();
    for (final o in _offices) {
      if (!o.hasCoordinates || o.geofenceRadius == null) {
        debugPrint('[GF_BG] ENTRY: ${o.name} skipped (no coords/radius)');
        continue;
      }
      final dist = geo.Geolocator.distanceBetween(
        filtered.latitude, filtered.longitude,
        o.latitude!, o.longitude!,
      );
      final margin = _gpsMargin(filtered.accuracy);
      final zone = o.geofenceRadius! + margin;
      debugPrint('[GF_BG] ENTRY: ${o.name} dist=${dist.toStringAsFixed(1)}m r=${o.geofenceRadius}m margin=${margin.toStringAsFixed(1)}m (acc=${filtered.accuracy.toStringAsFixed(1)}m × 2.0) zone=${zone.toStringAsFixed(1)}m');
      if (dist <= o.geofenceRadius! + margin) {
        debugPrint('[GF_BG] ENTRY: INSIDE ${o.name} — clearing exit state');
        _pendingOfficeId = null;
        _pendingRadius = null;
        _pendingOutConfirm = false;
        _exitAnalyzer.reset();
        _isInsideGeofence = true;

        if (_lastPunchTime != null &&
            _lastPunchType == 'Out' &&
            now.difference(_lastPunchTime!).inMinutes < 2) {
          debugPrint('[GF_BG] ENTRY: IN debounced — ${now.difference(_lastPunchTime!).inSeconds}s since OUT');
          return;
        }
        if (_lastPunchType == 'In') {
          debugPrint('[GF_BG] ENTRY: already IN — skip auto-punch');
          return;
        }
        await _handleAutoPunch('In', filtered, o, dist, confidence, now);
        return;
      }
    }
  }

  Future<void> _checkExit(LocationResult filtered, double confidence) async {
    if (!_isInsideGeofence && _pendingOfficeId == null) {
      debugPrint('[GF_BG] EXIT: skip — not inside, no pending');
      return;
    }
    debugPrint('[GF_BG] EXIT: scanning offices — inside=$_isInsideGeofence pending=$_pendingOfficeId insideFixes=$_consecutiveInsideFixes');

    Office? nearest;
    double nearestDist = double.infinity;
    for (final o in _offices) {
      if (!o.hasCoordinates || o.geofenceRadius == null) continue;
      final d = geo.Geolocator.distanceBetween(
        filtered.latitude, filtered.longitude,
        o.latitude!, o.longitude!,
      );
      if (d < nearestDist) {
        nearestDist = d;
        nearest = o;
      }
    }
    if (nearest == null) {
      debugPrint('[GF_BG] EXIT: no nearest office found');
      return;
    }

    final margin = _gpsMargin(filtered.accuracy);
    final zone = nearest.geofenceRadius! + margin;
    debugPrint('[GF_BG] EXIT: ${nearest.name} dist=${nearestDist.toStringAsFixed(1)}m r=${nearest.geofenceRadius}m margin=${margin.toStringAsFixed(1)}m (acc=${filtered.accuracy.toStringAsFixed(1)}m × 2.0) zone=${zone.toStringAsFixed(1)}m');

    if (nearestDist <= nearest.geofenceRadius!) {
      debugPrint('[GF_BG] EXIT: ${nearest.name} inside radius — no exit');
      return;
    }
    if (nearestDist <= nearest.geofenceRadius! + margin) {
      debugPrint('[GF_BG] EXIT: ${nearest.name} within margin zone — no exit');
      return;
    }

    if (_consecutiveInsideFixes < 3) {
      debugPrint('[GF_BG] EXIT: need 3+ inside fixes (have $_consecutiveInsideFixes) — wait');
      return;
    }

    // Past margin → start exit tracking
    _pendingOfficeId = nearest.id;
    _pendingRadius = nearest.geofenceRadius!.toDouble();
    _pendingLat = nearest.latitude!;
    _pendingLng = nearest.longitude!;
    debugPrint('[GF_BG] EXIT_TRACKING_START: ${nearest.name} — ${nearestDist.toStringAsFixed(1)}m > zone ${zone.toStringAsFixed(1)}m');

    _exitAnalyzer.reset();
    await _processExitTrend(filtered, confidence);
  }

  Future<void> _processExitTrend(
    LocationResult filtered,
    double confidence,
  ) async {
    if (_pendingOfficeId == null || _pendingRadius == null) return;

    final distToCenter = geo.Geolocator.distanceBetween(
      filtered.latitude, filtered.longitude,
      _pendingLat, _pendingLng,
    );

    // Moved back inside → reset
    if (distToCenter <= _pendingRadius!) {
      _exitAnalyzer.update(distToCenter, _pendingRadius!, confidence, filtered.jumpScore);
      _exitAnalyzer.reset(force: false);
      debugPrint('[GF_BG] EXIT_TREND: back within radius (${distToCenter.toStringAsFixed(1)}m ≤ ${_pendingRadius}m) score=${_exitAnalyzer.score.toStringAsFixed(2)}');
      if (_exitAnalyzer.score <= 0) {
        _pendingOfficeId = null;
        _pendingRadius = null;
        _pendingOutConfirm = false;
        _isInsideGeofence = true;
        debugPrint('[GF_BG] EXIT_TREND: fully reset — back inside');
      }
      return;
    }

    _exitAnalyzer.update(distToCenter, _pendingRadius!, confidence, filtered.jumpScore);
    debugPrint('[GF_BG] EXIT_TREND: dist=${distToCenter.toStringAsFixed(1)}m conf=${confidence.toStringAsFixed(2)} jump=${filtered.jumpScore.toStringAsFixed(2)} score=${_exitAnalyzer.score.toStringAsFixed(2)} ${_exitAnalyzer.getReasoning()}');

    if (_exitAnalyzer.isConfirmed) {
      if (_pendingOutConfirm) {
        // Second consecutive fix confirming exit → punch OUT
        final office = _offices.where((o) => o.id == _pendingOfficeId).firstOrNull;
        if (office != null) {
          debugPrint('[GF_BG] EXIT: CONFIRMED (2nd fix) — punching OUT');
          await _handleAutoPunch('Out', filtered, office, distToCenter, confidence, DateTime.now());
        }
        _exitAnalyzer.reset();
        _pendingOfficeId = null;
        _pendingRadius = null;
        _pendingOutConfirm = false;
      } else {
        debugPrint('[GF_BG] EXIT: CONFIRMED (1st fix) — waiting for 2nd fix');
        _pendingOutConfirm = true;
      }
      return;
    } else {
      _pendingOutConfirm = false;
    }
  }

  Future<void> _handleAutoPunch(
    String direction,
    LocationResult location,
    Office office,
    double dist,
    double confidence,
    DateTime now,
  ) async {
    // ── GATE 3.5: Concurrency guard ─────────────────────────────────────
    if (_punchInProgress) {
      debugPrint('[GF_BG] Punch already in progress — skipping $direction');
      return;
    }

    // ── GATE 3.6: Local punch state ─────────────────────────────────────
    // Never send the same direction twice — the server treats a second IN
    // as an OUT toggle.  Once we have successfully punched IN we do not
    // send another IN until an OUT has been sent (and vice versa).
    if (_lastPunchType == direction) {
      debugPrint('[GF_BG] Skip $direction — already ${direction == 'In' ? 'punched in' : 'punched out'} (local)');
      if (direction == 'In') _isInsideGeofence = true;
      return;
    }

    // ── GATE 4: Cooldown ────────────────────────────────────────────────
    if (_lastPunchTime != null &&
        _lastPunchType == direction &&
        now.difference(_lastPunchTime!).inMinutes < 5) {
      debugPrint('[GF_BG] Cooldown — skipping $direction (${now.difference(_lastPunchTime!).inMinutes}m ago)');
      return;
    }

    // Acquire concurrency lock BEFORE any async operation.
    // Gate 3.5 above will block any concurrent fix from entering.
    _punchInProgress = true;
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[GF_BG] No token — skipping $direction');
        return;
      }

      // ── GATE 5: Server status ──────────────────────────────────────────
      Map<String, dynamic>? status;
      try {
        final resp = await dio.get(ApiEndpoints.todayStatus);
        status = resp.data['data'] as Map<String, dynamic>?;
      } catch (e) {
        debugPrint('[GF_BG] Status check failed: $e');
      }

      if (direction == 'In') {
        if (status == null) {
          debugPrint('[GF_BG] Skip IN — cannot reach server');
          return;
        }
        if (status['isPunchedIn'] == true) {
          debugPrint('[GF_BG] Skip IN — already punched in');
          _isInsideGeofence = true;
          await _persistPunchState('In', now);
          await _clearShiftEndedFlag();
          return;
        }
      }
      if (direction == 'Out') {
        if (status != null) {
          if (status['isPunchedOut'] == true) {
            debugPrint('[GF_BG] Skip OUT — already punched out');
            await _persistPunchState('Out', now);
            return;
          }
          if (status['hasNotPunchedIn'] == true) {
            debugPrint('[GF_BG] Skip OUT — no IN today');
            return;
          }
        }
      }

      // ── All gates passed → call punch API ──────────────────────────────
      final margin = _gpsMargin(location.accuracy);
      debugPrint('[GF_BG] PUNCH_API: $direction — ${office.name} dist=${dist.toStringAsFixed(1)}m margin=${margin.toStringAsFixed(1)}m (acc=${location.accuracy.toStringAsFixed(1)}m × 2.0)');

      bool punchAccepted = false;
      try {
        final punchResp = await dio.post(ApiEndpoints.punch, data: {
          'Method': 'GeofenceAuto',
          'Direction': direction,
          'Latitude': location.latitude.toString(),
          'Longitude': location.longitude.toString(),
          'Address': office.name,
          'IPAddress': 'Background-Service',
        });
        if (punchResp.statusCode == 200 || punchResp.statusCode == 201) {
          punchAccepted = true;
        } else {
          debugPrint('[GF_BG] PUNCH_API: ${punchResp.statusCode} — ${punchResp.data}');
        }
      } on DioException catch (e) {
        debugPrint('[GF_BG] PUNCH_API DioException: ${e.message}');
        final resp = e.response;
        if (resp != null &&
            resp.statusCode != null &&
            resp.statusCode! >= 400 &&
            resp.statusCode! < 500) {
          // Permanent rejection — do NOT queue (server said no: duplicate,
          // invalid state, etc). Punch is dropped.
          if (resp.data is Map && resp.data['message'] is String) {
            final msg = resp.data['message'] as String;
            if (msg.contains('already recorded') || msg.contains('Duplicate punch')) {
              debugPrint('[GF_BG] PUNCH_API: server rejected (duplicate) — $msg');
            }
          }
        } else if (await _queueOfflinePunch(direction, location)) {
          // Network failure or 5xx — queue for offline sync.
          punchAccepted = true;
        }
      } catch (e) {
        debugPrint('[GF_BG] PUNCH_API error: $e');
        if (await _queueOfflinePunch(direction, location)) {
          punchAccepted = true;
        }
      }

      if (punchAccepted) {
        _lastPunchTime = now;
        _lastPunchType = direction;
        _isInsideGeofence = direction == 'In';
        debugPrint('[GF_BG] $direction SUCCESS via background');
        await _showPunchNotification(direction, office.name);

        await _persistPunchState(direction, now, officeName: office.name);

        if (direction == 'In') {
          await _clearShiftEndedFlag();
        }

        _service.invoke('gf_punch', {
          'direction': direction,
          'time': now.toIso8601String(),
          'officeName': office.name,
        });

        // On punch-out after shift end: schedule next-shift alarm and
        // stop the background service — no need to monitor for re-entry
        // until the next shift starts.
        if (direction == 'Out') {
          try {
            final shift = _findCurrentShift();
            if (shift != null && now.isAfter(shift.todayEnd)) {
              // Signal the main shell that shift ended — it should stop
              // geofence tracking instead of keeping it running for re-entry.
              final sp = await SharedPreferences.getInstance();
              await sp.setBool('gf_shift_ended', true);
              await GeofenceScheduler.scheduleNextShift(shift);
              _service.invoke('stop');
            }
          } catch (_) {
            // Non-critical — Workmanager alarm is the primary wake-up
          }
        }
      }
    } finally {
      _punchInProgress = false;
    }
  }

  /// Enqueue an auto punch that failed due to no network / server 5xx.
  /// OfflineSyncManager picks it up when connectivity returns.  Also requests
  /// an immediate one-off sync (Workmanager runs it once online).
  Future<bool> _queueOfflinePunch(
    String direction,
    LocationResult location,
  ) async {
    try {
      final punch = OfflinePunch()
        ..method = 'GeofenceAuto'
        ..direction = direction
        ..latitude = location.latitude
        ..longitude = location.longitude
        ..createdAt = DateTime.now();
      await OfflineQueueService().enqueue(punch);
      await OfflineSyncManager.scheduleNow();
      debugPrint('[GF_BG] queued $direction offline (no network)');
      return true;
    } catch (e) {
      debugPrint('[GF_BG] offline queue enqueue failed: $e');
      return false;
    }
  }

  // ── HTTP helpers ────────────────────────────────────────────────────────

  /// Build a Dio instance with the background access token and a 401
  /// interceptor that attempts token refresh (mirroring the main isolate's
  /// [DioClient] refresh logic, but self-contained in SharedPreferences).
  Future<Dio?> _buildDio() async {
    if (_testDio != null) return _testDio;
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('bg_access_token');
    if (token == null) return null;

    final dio = Dio(BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Authorization': 'Bearer $token',
        'X-Client-Type': 'mobile',
        'X-Platform': Platform.isAndroid ? 'android' : 'ios',
      },
    ));

    dio.interceptors.addAll([
      InterceptorsWrapper(
        onError: (error, handler) async {
          if (error.response?.statusCode != 401) {
            return handler.next(error);
          }

          debugPrint('[GF_BG] 401 on ${error.requestOptions.path} — attempting token refresh');

          try {
            final refreshed = await _refreshToken();
            if (refreshed == null) {
              debugPrint('[GF_BG] Token refresh failed — cannot retry');
              return handler.next(error);
            }

            error.requestOptions.headers['Authorization'] = 'Bearer $refreshed';
            final retryResp = await dio.fetch(error.requestOptions);
            return handler.resolve(retryResp);
          } catch (e) {
            debugPrint('[GF_BG] Token refresh error: $e');
            return handler.next(error);
          }
        },
      ),
      PunchStateInterceptor(),
    ]);

    return dio;
  }

  /// Attempt to refresh the access token using the stored refresh token.
  /// Returns the new access token on success, null on failure.
  Future<String?> _refreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Atomic cross-isolate lock claim (same protocol as TokenStorage):
    // write unique owner token, re-read, verify ownership.  If another
    // isolate wrote after us we lost the race → skip.
    final lockTs = prefs.getInt('bg_refresh_lock') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockTs > 0 && (now - lockTs) < 30000) {
      debugPrint('[GF_BG] Another isolate is refreshing — skipping');
      return null;
    }

    final owner = '$now-${DateTime.now().microsecondsSinceEpoch}';
    await prefs.setInt('bg_refresh_lock', now);
    await prefs.setString('bg_refresh_lock_owner', owner);
    await prefs.reload();
    final persistedOwner = prefs.getString('bg_refresh_lock_owner');
    final persistedTs = prefs.getInt('bg_refresh_lock') ?? 0;
    if (persistedOwner != owner || persistedTs != now) {
      debugPrint('[GF_BG] Lost refresh-lock race — skipping');
      return null;
    }

    try {
      // Capture session generation BEFORE refreshing.  If it changes while
      // we are on the network (logout/relogin elsewhere), discard results —
      // prevents token resurrection after logout.
      final sessionId = prefs.getString('auth_session_id');
      final refreshToken = prefs.getString('bg_refresh_token');
      final accessToken = prefs.getString('bg_access_token');
      if (sessionId == null || refreshToken == null || accessToken == null) {
        await prefs.remove('bg_refresh_lock');
        await prefs.remove('bg_refresh_lock_owner');
        return null;
      }

      final refreshDio = Dio(BaseOptions(
        baseUrl: AppConstants.apiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
      ));

      final resp = await refreshDio.post('/api/v1/auth/refresh', data: {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
      });

      final newAccess = resp.data['accessToken'] as String;
      final newRefresh = resp.data['refreshToken'] as String;

      // Session guard: verify session marker is unchanged before persisting.
      await prefs.reload();
      if (prefs.getString('auth_session_id') != sessionId) {
        debugPrint('[GF_BG] Session changed during refresh — discarding tokens');
        await prefs.remove('bg_refresh_lock');
        await prefs.remove('bg_refresh_lock_owner');
        return null;
      }

      await Future.wait([
        prefs.setString('bg_access_token', newAccess),
        prefs.setString('bg_refresh_token', newRefresh),
        prefs.setInt('bg_token_ts', DateTime.now().millisecondsSinceEpoch),
        prefs.remove('bg_refresh_lock'),
        prefs.remove('bg_refresh_lock_owner'),
      ]);

      debugPrint('[GF_BG] Token refreshed successfully');
      return newAccess;
    } catch (e) {
      await prefs.remove('bg_refresh_lock');
      await prefs.remove('bg_refresh_lock_owner');

      debugPrint('[GF_BG] Token refresh failed — retaining tokens for main isolate');
      return null;
    }
  }

  Future<List<Office>> _fetchOffices(Dio dio) async {
    try {
      final resp = await dio.get(ApiEndpoints.employeeOffices);
      final data = resp.data;
      final list = (data is List ? data : data['data'] ?? []) as List;
      return list.map((e) => Office.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[GF_BG] Fetch offices failed: $e');
      return [];
    }
  }

  Future<List<Shift>> _fetchShifts(Dio dio) async {
    try {
      final resp = await dio.get(ApiEndpoints.shifts);
      final data = resp.data;
      final list = (data is List ? data : data['data'] ?? []) as List;
      return list.map((e) => Shift.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      debugPrint('[GF_BG] Fetch shifts failed: $e');
      return [];
    }
  }

  Future<bool> _isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final val = prefs.getBool('geofence_auto_enabled') ?? false;
    // Permission gate: block ONLY when the server definitively denied geofence
    // auto.  Flag absent (never fetched / offline) → treated as unknown and
    // allowed — preserves legacy behavior, never blocks a permitted user.
    final allow = prefs.getBool('bg_allow_geofence_auto');
    final permitted = allow != false;
    debugPrint('[GF_BG] _isEnabled = $val, allowGeofenceAuto = ${allow == null ? 'unknown' : allow}');
    return val && permitted;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  Future<void> _clearShiftEndedFlag() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove('gf_shift_ended');
      debugPrint('[GF_BG] Cleared stale gf_shift_ended flag');
    } catch (_) {}
  }

  double _gpsMargin(double accuracy) {
    return (accuracy * 2.0).clamp(10.0, 250.0);
  }

  Future<void> _showPunchNotification(String direction, String officeName) async {
    final isIn = direction == 'In';
    final title = isIn ? 'Auto-Punched In' : 'Auto-Punched Out';
    final body = isIn
        ? 'Auto-punched IN at $officeName'
        : 'Auto-punched OUT from $officeName';
    try {
      await _notifications.show(
        998,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'geofence_auto_punch',
            'Geofence Auto-Punch',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[GF_BG] Notification failed: $e');
    }
  }
}
