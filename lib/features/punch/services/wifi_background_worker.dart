import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/api/punch_state_interceptor.dart';
import '../../../core/offline/offline_queue.dart';
import '../../../core/offline/offline_sync_manager.dart';
import '../../../core/punch/punch_coordinator.dart';
import 'geofence_monitor.dart';
import '../../../core/utils/constants.dart';
import '../../../models/attendance.dart';
import '../../../models/offline_punch.dart';
import '../../../models/office.dart';

/// Background WiFi auto-punch worker.
///
/// Runs inside the same flutter_background_service isolate as
/// GeofenceMonitor. Monitors WiFi connect/disconnect via
/// connectivity_plus stream + 15s fallback poll. Matches current BSSID
/// against persisted wifiRouters on each office. Punches IN on match,
/// OUT on disconnect.
class WifiBackgroundWorker {
  final ServiceInstance _service;

  late final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _fallbackTimer;

  List<Office> _offices = [];
  bool _dataLoaded = false;

  // Re-entrancy guard — start() fires an immediate check AND the connectivity
  // stream emits an initial event, so two _checkCurrentWifi() calls can run
  // concurrently. Without this, the first scan can read a stale cached BSSID
  // (Android returns the last-known network at process start) → false IN,
  // while the second scan reads the real BSSID → false OUT, same second.
  bool _checkInProgress = false;

  // Server punch-state sync in flight at startup (see start()).  Checks wait
  // for it so a stale cross-day 'In' cannot cause a false OUT.
  Future<void>? _stateSyncFuture;

  // BSSID confirmation — Android can return a stale cached BSSID on the first
  // read after isolate spawn. We only punch IN when the SAME matched BSSID is
  // observed on two separate checks (like the geofence worker's 3-fix rule).
  String? _lastMatchedBssid;
  DateTime? _lastMatchedAt;
  static const Duration _bssidConfirmWindow = Duration(seconds: 30);

  // Cooldown guard — prevents rapid IN→OUT when two scans return
  // different results (e.g. fallback timer + connectivity stream).
  static const int _cooldownMs = 10000;
  int _lastActionTimestamp = 0;

  // SharedPreferences keys — shared with GeofenceMonitor
  // so both workers have a single source of truth for punch state
  static const _kLastBssid = 'wifi_bg_last_bssid';
  static const _kLastPunchType = 'gf_last_punch_type';
  static const _kLastPunchTime = 'gf_last_punch_time';
  static const _kMatchedOfficeName = 'gf_last_punch_office';
  static const _kDataLoadedAt = 'wifi_bg_data_loaded_at';

  // Cross-isolate disconnect guard — prevents both foreground and
  // background isolates from punching OUT for the same disconnect event.
  // Written by whichever isolate punches first; the other checks this
  // before punching and skips if within the cooldown window.
  static const _kDisconnectProcessedTs = 'wifi_disconnect_processed_ts';
  static const _disconnectGuardMs = 30000; // 30-second guard window

  // Pending OUT chamber — saves a failed OUT punch (no internet) and
  // retries it when connectivity returns, preserving the original
  // disconnect timestamp.
  static const _kPendingOut = 'wifi_pending_out';
  static const _kPendingOutTs = 'wifi_pending_out_ts';
  static const _kPendingOutBssid = 'wifi_pending_out_bssid';

  WifiBackgroundWorker(this._service);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  void start() {
    debugPrint('[WIFI_BG] start() called');

    // Sync real punch state from server BEFORE any check runs.  A stale
    // local 'In' from a previous day would otherwise cause a false OUT punch
    // when the worker wakes from an alarm while the user is at home.
    _stateSyncFuture = _syncPunchStateFromServer();

    // Subscribe to connectivity changes
    _connSub = Connectivity().onConnectivityChanged.listen(_onConnectivity);

    // 15s fallback poll (catches stream drops on some OEM ROMs)
    _fallbackTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _maybeStopAfterShift();
      _checkGeofenceContainment();
      _checkCurrentWifi();
    });

    // Immediate check on start — behind the state sync (see above).
    _stateSyncFuture!.whenComplete(() {
      _checkCurrentWifi();
    });

    // Listen for stop signal
    _service.on('stop_wifi_bg').listen((_) => stop());
  }

  void stop() {
    _connSub?.cancel();
    _connSub = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    debugPrint('[WIFI_BG] Monitoring stopped');
  }

  // ── Shift-end self-kill ─────────────────────────────────────────────────────
  //
  // The service was meant to live only around the shift: started by the
  // shift-start alarm, and killed once the shift is over and the user is no
  // longer being monitored (punched out — left the geofence / disconnected
  // from office WiFi).  Runs even when WiFi auto is disabled, so geofence-only
  // users get the same battery win.

  /// Shift over (past persisted shift end) AND no active punch → the
  /// background service has nothing left to do until the next shift-start
  /// alarm.  Ask the entrypoint to stop itself; its 'stop' listener cancels
  /// the 15-min restart safety-net so the kill sticks.
  Future<void> _maybeStopAfterShift() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final endRaw = prefs.getString('gf_shift_end_time');
      if (endRaw == null) return; // fail-safe: unknown → keep running
      final end = DateTime.tryParse(endRaw);
      if (end == null || !DateTime.now().isAfter(end)) return;
      if (prefs.getString('gf_last_punch_type') == 'In') return; // overtime
      debugPrint('[WIFI_BG] Shift over + punched out — stopping background service');
      FlutterBackgroundService().invoke('stop');
    } catch (e) {
      debugPrint('[WIFI_BG] Stop-after-shift check failed: $e');
    }
  }

  /// Geofence-only recovery: OS enter events can be deferred by OEM battery
  /// optimizations while the app is backgrounded, so a re-entry punch-out
  /// may never fire.  Re-check office containment on the poll cadence so an
  /// IN punch lands within ~15s of crossing back into the radius even when
  /// the OS never delivers the transition.  Geofence-only users still get
  /// this fallback because the combined service runs while geofence auto is
  /// enabled (see GeofenceScheduler.anyAutoFeatureEnabled).
  Future<void> _checkGeofenceContainment() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('geofence_auto_enabled') ?? false)) return;
      await GeofencePunchHandler.instance.reconcileContainment();
    } catch (e) {
      debugPrint('[WIFI_BG] Geofence containment check failed: $e');
    }
  }

  // ── Connectivity Listener ──────────────────────────────────────────────────

  void _onConnectivity(List<ConnectivityResult> results) {
    debugPrint('[WIFI_BG] Connectivity changed: $results');
    if (results.contains(ConnectivityResult.wifi)) {
      _clearNoConnectivityWarning();
      _checkCurrentWifi();
    } else if (results.contains(ConnectivityResult.mobile)) {
      _clearNoConnectivityWarning();
      // Mobile data only — flush pending OUT, don't check WiFi.
      // Mirror foreground behavior: on mobile data, only deliver
      // a previously-queued pending OUT; don't punch fresh OUT.
      // Checking WiFi here would trigger _handleDisconnect → _punchOut
      // which races with the foreground service (same event, two isolates).
      debugPrint('[WIFI_BG] Mobile data — flushing pending OUT only');
      _flushPendingOut();
    } else {
      // No connectivity at all (airplane mode / no signal) — warn once so
      // the employee knows punches will be saved and sent later.  The
      // re-check below still runs: if WiFi comes back before the poll it
      // will re-match and cancel the warning.
      _warnNoConnectivity();
      // Stream says no connectivity — but the phone may have already
      // transitioned to another WiFi.  Re-check before declaring
      // disconnect so we don't OUT just to IN again on a registered AP.
      _checkCurrentWifi();
    }
  }

  // ── Core Check ─────────────────────────────────────────────────────────────

  Future<void> _checkCurrentWifi() async {
    if (_checkInProgress) {
      debugPrint('[WIFI_BG] Check already in progress — skipping');
      return;
    }
    _checkInProgress = true;
    try {
      await _checkCurrentWifiInner();
    } finally {
      _checkInProgress = false;
    }
  }

  Future<void> _checkCurrentWifiInner() async {
    await _waitForStateSync();
    final enabled = await _isEnabled();
    if (!enabled) {
      debugPrint('[WIFI_BG] Not enabled — skipping check');
      return;
    }

    // No active shift → alignment warnings are irrelevant.  Clear any
    // leftover popups so a punched-out user at home (offline / GPS off)
    // stays quiet.
    if (!await _isPunchedIn()) {
      await _clearNoConnectivityWarning();
      await _clearBssidWarning();
    }

    // Cooldown guard: prevent rapid punch decisions when the
    // fallback timer and connectivity stream fire close together.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastActionTimestamp > 0 && (now - _lastActionTimestamp) < _cooldownMs) {
      debugPrint('[WIFI_BG] Cooldown active — skipping check');
      return;
    }

    try {
      // Verify WiFi is actually connected (BSSID can be stale on Android)
      final connectivity = await Connectivity().checkConnectivity();
      if (!connectivity.contains(ConnectivityResult.wifi)) {
        debugPrint('[WIFI_BG] No WiFi connectivity — treating as disconnected');
        _emitDebug(enabled: true);
        await _handleDisconnect();
        return;
      }

      // WiFi is up — any no-connectivity warning is resolved (covers the
      // fallback-timer path where the connectivity stream may have dropped).
      await _clearNoConnectivityWarning();

      // Load offices if not yet loaded or stale (>30 min)
      if (_offices.isEmpty || _isDataStale()) {
        await _loadOffices();
      }

      final bssid = await _getCurrentBssid();
      if (bssid == null) {
        // Connectivity above confirmed WiFi is connected, so "no BSSID"
        // means Android hid it (location/GPS off) or the radio is mid-scan —
        // NOT a disconnect.  Punching OUT here would falsely end an
        // employee's shift while they sit at the office.  Warn instead.
        debugPrint('[WIFI_BG] BSSID unreadable while connected (location off?) — skipping, no punch');
        _emitDebug(enabled: true);
        await _warnBssidUnreadable();
        return;
      }

      // BSSID readable — any previous "hidden network" warning is resolved.
      await _clearBssidWarning();

      debugPrint('[WIFI_BG] Current BSSID: $bssid');

      final matched = _matchBssid(bssid);
      final lastPunchType = await _getLastPunchType();

      // If user is back at a known office, cancel any pending OUT
      if (matched != null) {
        await _clearPendingOut();
        // Also drop queued WiFi OUTs from the offline queue — the disconnect
        // that triggered them never really happened (user reconnected).
        try {
          await OfflineQueueService().deleteQueuedByMethod('WiFi');
        } catch (e) {
          debugPrint('[WIFI_BG] clear queued WiFi punches error: $e');
        }
      }

      _emitDebug(
        enabled: true,
        bssid: bssid,
        matchedName: matched?.name,
        lastPunchType: lastPunchType,
      );
      // Persist to SP so notification can read status
      await _persistWifiStatus(bssid: bssid, matchedName: matched?.name);

      if (matched != null && lastPunchType != 'In') {
        // Unknown state guard: on fresh app start, lastPunchType is null
        // (no record in SharedPreferences yet).  Wait for the foreground
        // to sync the real state from the server before punching.
        if (lastPunchType == null) {
          debugPrint('[WIFI_BG] Unknown punch state (null) — deferring to foreground sync');
          return;
        }

        // Manual-out-on-wifi guard: suppress auto re-IN until WiFi disconnects
        if (await _isManualOutOnWifi()) {
          debugPrint('[WIFI_BG] Manual-out-on-wifi active — skip auto IN');
          return;
        }

        // ── BSSID confirmation gate ──────────────────────────────────────
        // Android can return a stale cached BSSID on the first scan after
        // isolate spawn (the last network the phone was connected to).  One
        // matching read is NOT proof of being at the office — the same BSSID
        // must be observed on two separate checks.  Prevents a false auto-IN
        // when the worker wakes from an alarm while the user is at home.
        final now = DateTime.now();
        if (_lastMatchedBssid != bssid ||
            _lastMatchedAt == null ||
            now.difference(_lastMatchedAt!) > _bssidConfirmWindow) {
          _lastMatchedBssid = bssid;
          _lastMatchedAt = now;
          debugPrint('[WIFI_BG] Match seen once ($bssid) — waiting for confirmation');
          return;
        }
        _lastMatchedBssid = null;
        _lastMatchedAt = null;
        debugPrint('[WIFI_BG] Match confirmed across two checks: ${matched.name} — punching IN');
        await _punchIn(matched, bssid);
      } else if (matched == null && lastPunchType == 'In') {
        // Not on a registered network — a pending BSSID confirmation from a
        // stale read must not fire later.  Clear it.
        _lastMatchedBssid = null;
        _lastMatchedAt = null;
        // Manual-out-on-wifi guard also applies for BSSID-mismatch OUT
        if (await _isManualOutOnWifi()) {
          debugPrint('[WIFI_BG] Manual-out-on-wifi active — skip auto OUT (no match)');
          return;
        }
        // Only punch OUT on BSSID mismatch if last IN was via WiFi.
        // Manual IN (GPS/NFC) or restored state should not be undone by WiFi.
        if (!await _isLastInByWifi()) {
          debugPrint('[WIFI_BG] Last IN not via WiFi — skip auto OUT (no match)');
          return;
        }

        // User not at known WiFi and was IN — flush any pending first,
        // then try fresh OUT
        await _flushPendingOut();
        final afterPunch = await _getLastPunchType();
        if (afterPunch == 'In') {
          debugPrint('[WIFI_BG] No match — punching OUT');
          final ok = await _punchOut(bssid);
          if (!ok) {
            await _savePendingOut(bssid: bssid);
          }
        }
      } else if (matched != null && lastPunchType == 'In') {
        // Phone connected to registered WiFi while already IN.  Mark last IN
        // as WiFi so a future disconnect triggers OUT correctly, even though
        _lastMatchedBssid = null;
        _lastMatchedAt = null;
        // we don't need to punch duplicate IN.
        await _setLastInByWifi();
        debugPrint('[WIFI_BG] Registered WiFi connected — already IN, marking lastIn=wifi');
      } else {
        debugPrint('[WIFI_BG] No match and not IN — noop');
      }
    } catch (e) {
      debugPrint('[WIFI_BG] _checkCurrentWifi error: $e');
    }
  }

  Future<void> _handleDisconnect() async {
    await _waitForStateSync();
    if (!await _isEnabled()) return;

    // Real disconnect — any network-hidden warning is resolved.  The
    // no-connectivity warning is NOT cleared here: a disconnect proves
    // nothing about connectivity returning (and _onConnectivity fires
    // _warnNoConnectivity before _checkCurrentWifi, so clearing here
    // would cancel the popup the same instant it posts).
    await _clearBssidWarning();

    // ── Cooldown guard: prevent rapid re-entry from timer + stream ──
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastActionTimestamp > 0 && (now - _lastActionTimestamp) < _cooldownMs) {
      debugPrint('[WIFI_BG] _handleDisconnect cooldown active — skip');
      return;
    }

    // ── Cross-isolate guard: only one isolate punches per disconnect ──
    if (await _isDisconnectAlreadyProcessed()) {
      debugPrint('[WIFI_BG] Disconnect already processed by other isolate — skip');
      // Still clear local state so UI reflects correct status
      await _clearLastInMethod();
      return;
    }

    // WiFi disconnect clears the manual-out-on-wifi guard
    if (await _isManualOutOnWifi()) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(manualOutOnWifiKey, false);
      debugPrint('[WIFI_BG] WiFi disconnected — manual-out-on-wifi guard CLEARED');
    }

    // Last-IN-method guard: only punch OUT if last IN was via WiFi
    final lastInByWifi = await _isLastInByWifi();
    if (!lastInByWifi) {
      debugPrint('[WIFI_BG] Last IN not via WiFi — skip auto OUT on disconnect');
      return;
    }

    // Read punch state BEFORE flush (flush may change it)
    final preFlushPunchType = await _getLastPunchType();

    // Clear last-in-method and manual IN — WiFi IN state is being left
    if (preFlushPunchType != 'In') {
      debugPrint('[WIFI_BG] WiFi disconnected — already OUT, clearing state');
    } else {
      debugPrint('[WIFI_BG] WiFi disconnected — punching OUT');
    }
    await _clearLastInMethod();
    if (await _isManualIn()) {
      await _clearManualIn();
      debugPrint('[WIFI_BG] WiFi disconnected — manual IN guard CLEARED');
    }

    // Ensure offices loaded so _getOfficeMac can find registered MAC
    if (_offices.isEmpty) {
      await _loadOffices();
    }

    // Flush any pending OUT before considering fresh punch
    await _flushPendingOut();

    // Re-read punch type AFTER flush — _flushPendingOut may have
    // succeeded (setting type to 'Out') so we don't punch twice.
    if (preFlushPunchType == 'In') {
      final freshPunchType = await _getLastPunchType();
      if (freshPunchType == 'In') {
        // Still IN after flush — punch OUT now.
        // Mark BEFORE HTTP so the cross-isolate guard prevents
        // the foreground from racing us.
        await _markDisconnectProcessed();
        final ok = await _punchOut('');
        if (!ok) {
          await _savePendingOut(bssid: '');
        }
      } else {
        // Flush already handled the OUT — still mark processed
        // so the foreground isolate skips its attempt.
        await _markDisconnectProcessed();
        debugPrint('[WIFI_BG] Flush already set punch to Out — no fresh punch needed');
      }
    }
  }

  // ── Office Data ────────────────────────────────────────────────────────────

  /// Wait for the startup server punch-state sync to settle (max 10s) so a
  /// stale cross-day local state can't drive a punch.  No-op if no sync is in
  /// flight (steady state) — checks then run on the last-known local state.
  Future<void> _waitForStateSync() async {
    final sync = _stateSyncFuture;
    if (sync == null) return;
    try {
      await sync.timeout(const Duration(seconds: 10));
    } catch (_) {
      // Sync failed or timed out — fall through on local state (legacy
      // behavior); the BSSID confirmation gate still protects the IN side.
    }
  }

  /// Fetch todayStatus from the server once and persist the current punch
  /// state so the worker never acts on a stale local 'In' carried over from
  /// a previous day / session (e.g. alarm-manager wake while at home).
  /// Mirrors [GeofencePunchHandler._syncPunchStateFromServer].
  Future<void> _syncPunchStateFromServer() async {
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[WIFI_BG] No auth token — cannot sync punch state');
        return;
      }
      final resp = await dio.get(ApiEndpoints.todayStatus);
      final data = resp.data['data'] as Map<String, dynamic>?;
      if (data == null) return;
      final status = EmployeeStatus.fromJson(data);

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final last = PunchCoordinator.lastPunchType(status);
      if (last != null && last != 'BreakStart') {
        await prefs.setString(_kLastPunchType, last);
        debugPrint('[WIFI_BG] Synced punch state — $last (from server)');
      }
    } catch (e) {
      debugPrint('[WIFI_BG] Failed to sync punch state from server: $e');
    }
  }

  Future<void> _loadOffices() async {
    debugPrint('[WIFI_BG] Loading offices...');
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[WIFI_BG] No auth token — cannot load offices');
        return;
      }

      final resp = await dio.get(ApiEndpoints.employeeOffices);
      final data = resp.data;
      final list = (data is List ? data : data['data'] ?? []) as List;

      _offices = list
          .map((e) => Office.fromJson(e as Map<String, dynamic>))
          .toList();
      _dataLoaded = true;

      // Persist load time for staleness check
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kDataLoadedAt, DateTime.now().millisecondsSinceEpoch);

      debugPrint('[WIFI_BG] Loaded ${_offices.length} offices');
      for (final o in _offices) {
        final routers = o.wifiRouters ?? [];
        debugPrint(
            '[WIFI_BG]   ${o.name}: ${routers.length} wifiRouters, legacyMAC=${o.wifiMAC}');
      }
    } catch (e) {
      debugPrint('[WIFI_BG] Failed to load offices: $e');
    }
  }

  // ── BSSID Reader ────────────────────────────────────────────────────────────

  Future<String?> _getCurrentBssid() async {
    try {
      final networkInfo = NetworkInfo();
      final bssid = await networkInfo.getWifiBSSID();
      if (bssid == null || bssid.isEmpty || bssid == '02:00:00:00:00:00') {
        return null;
      }
      return bssid.toUpperCase();
    } catch (e) {
      debugPrint('[WIFI_BG] Failed to get BSSID: $e');
      return null;
    }
  }

  bool _isDataStale() {
    if (!_dataLoaded) return true;
    // Force reload every 30 minutes
    return false; // handled by _kDataLoadedAt timestamp check
  }

  // ── BSSID Matching ─────────────────────────────────────────────────────────

  Office? _matchBssid(String currentBssid) {
    final normalized = _normalizeMac(currentBssid);

    for (final office in _offices) {
      // Check new wifiRouters list
      if (office.wifiRouters != null) {
        for (final router in office.wifiRouters!) {
          if (_normalizeMac(router.macId) == normalized) {
            debugPrint('[WIFI_BG] Match via wifiRouters: ${router.macId} → ${office.name}');
            return office;
          }
        }
      }

      // Fallback: legacy wifiMAC field
      if (office.wifiMAC != null && office.wifiMAC!.isNotEmpty) {
        if (_normalizeMac(office.wifiMAC!) == normalized) {
          debugPrint('[WIFI_BG] Match via legacy wifiMAC: ${office.wifiMAC} → ${office.name}');
          return office;
        }
      }
    }

    return null;
  }

  String _normalizeMac(String mac) {
    return mac.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toUpperCase();
  }

  // ── Punch ──────────────────────────────────────────────────────────────────

  Future<void> _punchIn(Office office, String bssid) async {
    _lastActionTimestamp = DateTime.now().millisecondsSinceEpoch;
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[WIFI_BG] No auth token — cannot punch IN');
        return;
      }

      // Server-truth gate — a biometric/website IN may already exist.
      final verdict =
          await PunchCoordinator.check(dio: dio, direction: 'In');
      if (verdict == PunchCheck.duplicate) {
        debugPrint('[WIFI_BG] skip IN — already punched in (biometric/website)');
        await _setLastPunchType('In');
        return;
      }
      if (verdict == PunchCheck.blocked) {
        debugPrint('[WIFI_BG] skip IN — blocked (break in progress?)');
        return;
      }

      String ip = '0.0.0.0';
      try {
        ip = await NetworkInfo().getWifiIP() ?? '0.0.0.0';
      } catch (_) {}

      final resp = await dio.post(
        ApiEndpoints.punch,
        data: {
          'Method': 'WiFi',
          'Direction': 'In',
          'WifiMAC': bssid,
          'IPAddress': ip,
        },
      );

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        debugPrint('[WIFI_BG] Punched IN at ${office.name}');
        await _setLastPunchType('In');
        await _setMatchedOffice(office.name);
        await _setLastPunchTime(DateTime.now());
        await _clearManualIn();
        await _setLastInByWifi();
        await _showNotification('Auto-Punch In', '${office.name} · ${_formatTime(DateTime.now())}');

        _service.invoke('wifi_punch', {
          'direction': 'In',
          'officeName': office.name,
          'time': DateTime.now().toIso8601String(),
        });
      }
    } on DioException catch (e) {
      debugPrint('[WIFI_BG] Punch IN DioException: ${e.message}');
      if (await _handleDuplicateError(e, 'In', office.name)) return;
      // Network failure or 5xx → queue for offline sync (keep local state in
      // sync so nothing re-triggers).
      if (_isTransientError(e) && await _queueWifiPunch('In', office, bssid)) {
        await _setLastPunchType('In');
        await _setMatchedOffice(office.name);
        await _setLastPunchTime(DateTime.now());
        await _clearManualIn();
        await _setLastInByWifi();
        await _showNotification('Auto-Punch In (queued)', '${office.name} · will sync when online');
      }
    } catch (e) {
      debugPrint('[WIFI_BG] Punch IN error: $e');
      if (await _queueWifiPunch('In', office, bssid)) {
        await _setLastPunchType('In');
        await _setMatchedOffice(office.name);
        await _setLastPunchTime(DateTime.now());
        await _clearManualIn();
        await _setLastInByWifi();
        await _showNotification('Auto-Punch In (queued)', '${office.name} · will sync when online');
      }
    }
  }

  /// Returns `true` if punch was accepted (200/201) or duplicate.
  Future<bool> _punchOut(String bssid) async {
    _lastActionTimestamp = DateTime.now().millisecondsSinceEpoch;
      final officeName = await _getMatchedOffice();
      final officeMac = _getOfficeMac(officeName);
      try {
        final dio = await _buildDio();
        if (dio == null) {
          debugPrint('[WIFI_BG] No auth token — cannot punch OUT');
          return false;
        }

        // Server-truth gate — a biometric/website OUT may already exist.
        final verdict =
            await PunchCoordinator.check(dio: dio, direction: 'Out');
        if (verdict == PunchCheck.duplicate) {
          debugPrint('[WIFI_BG] skip OUT — already punched out (biometric/website)');
          await _setLastPunchType('Out');
          await _setMatchedOffice('');
          return false;
        }
        if (verdict == PunchCheck.blocked) {
          debugPrint('[WIFI_BG] skip OUT — no IN punch today');
          return false;
        }

        String ip = '0.0.0.0';
        try {
          ip = await NetworkInfo().getWifiIP() ?? '0.0.0.0';
        } catch (_) {}

        final resp = await dio.post(
          ApiEndpoints.punch,
          data: {
            'Method': 'WiFi',
            'Direction': 'Out',
            'WifiMAC': officeMac.isNotEmpty ? officeMac : 'unknown',
            'IPAddress': ip,
            'remarks': 'Auto Punch-Out (WiFi disconnected)',
          },
        );

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        debugPrint('[WIFI_BG] Punched OUT');
        await _setLastPunchType('Out');
        await _setMatchedOffice('');
        await _setLastPunchTime(DateTime.now());
        await _clearManualIn();
        await _clearLastInMethod();
        await _showNotification('Auto-Punch Out', '${_formatTime(DateTime.now())}');

        _service.invoke('wifi_punch', {
          'direction': 'Out',
          'officeName': officeName,
          'time': DateTime.now().toIso8601String(),
        });
        return true;
      }
      return false;
    } on DioException catch (e) {
      debugPrint('[WIFI_BG] Punch OUT DioException: ${e.message}');
      if (await _handleDuplicateError(e, 'Out', '')) return true;
      // Network failure or 5xx → queue for offline sync.  Local state is
      // updated so the worker does not keep re-attempting the punch.
      if (_isTransientError(e) && await _queueWifiPunch('Out', null, bssid)) {
        await _setLastPunchType('Out');
        await _setMatchedOffice('');
        await _setLastPunchTime(DateTime.now());
        await _clearManualIn();
        await _clearLastInMethod();
        await _showNotification('Auto-Punch Out (queued)', '${_formatTime(DateTime.now())} · will sync when online');
        _service.invoke('wifi_punch', {
          'direction': 'Out',
          'officeName': officeName,
          'time': DateTime.now().toIso8601String(),
        });
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[WIFI_BG] Punch OUT error: $e');
      if (await _queueWifiPunch('Out', null, bssid)) {
        await _setLastPunchType('Out');
        await _setMatchedOffice('');
        await _setLastPunchTime(DateTime.now());
        await _clearManualIn();
        await _clearLastInMethod();
        await _showNotification('Auto-Punch Out (queued)', '${_formatTime(DateTime.now())} · will sync when online');
        _service.invoke('wifi_punch', {
          'direction': 'Out',
          'officeName': officeName,
          'time': DateTime.now().toIso8601String(),
        });
        return true;
      }
      return false;
    }
  }

  /// `true` when a DioException means "transient, retry later" — no response
  /// (no network / timeout) or server 5xx.  4xx (permanent rejection) and
  /// duplicates are excluded — those must NOT be queued.
  bool _isTransientError(DioException e) {
    final resp = e.response;
    if (resp != null && resp.statusCode != null) {
      return resp.statusCode! >= 500;
    }
    return true; // no response → network problem
  }

  /// Queue a WiFi auto punch that failed due to no connectivity.  OfflineSyncManager
  /// sends it when the network comes back.  Requests an immediate one-off sync.
  Future<bool> _queueWifiPunch(String direction, Office? office, String bssid) async {
    try {
      String mac = bssid;
      if (direction == 'Out' && office == null) {
        final officeName = await _getMatchedOffice();
        mac = _getOfficeMac(officeName);
      }
      final punch = OfflinePunch()
        ..method = 'WiFi'
        ..direction = direction
        ..wifiMAC = mac.isNotEmpty ? mac : 'unknown'
        ..createdAt = DateTime.now();
      await OfflineQueueService().enqueue(punch);
      await OfflineSyncManager.scheduleNow();
      debugPrint('[WIFI_BG] queued WiFi $direction offline');
      return true;
    } catch (e) {
      debugPrint('[WIFI_BG] offline queue enqueue failed: $e');
      return false;
    }
  }

  /// Returns `true` if the error was a duplicate (punch already accepted).
  Future<bool> _handleDuplicateError(DioException e, String direction, String officeName) async {
    if (e.response != null) {
      final body = e.response?.data;
      if (body is Map && body['message'] is String) {
        final msg = body['message'] as String;
        if (msg.contains('already recorded') || msg.contains('Duplicate')) {
          debugPrint('[WIFI_BG] Duplicate detected — syncing state');
          await _setLastPunchType(direction);
          if (direction == 'In') {
            await _setMatchedOffice(officeName);
            await _clearManualIn();
            await _setLastInByWifi();
          }
          return true;
        }
      }
    }
    debugPrint('[WIFI_BG] Punch $direction failed: ${e.message}');
    return false;
  }

  // ── Office MAC lookup ─────────────────────────────────────────────────────

  /// Returns the registered office MAC for OUT punches. Server validates
  /// WifiMAC against registered routers — non-matching MACs (hotspot BSSID)
  /// get rejected with "Unregistered WiFi network."
  String _getOfficeMac(String officeName) {
    if (officeName.isEmpty) return '';
    final office = _offices.cast<Office?>().firstWhere(
      (o) => o?.name == officeName,
      orElse: () => null,
    );
    if (office == null) return '';
    if (office.wifiRouters != null && office.wifiRouters!.isNotEmpty) {
      return office.wifiRouters!.first.macId;
    }
    return office.wifiMAC ?? '';
  }

  // ── SharedPreferences State ────────────────────────────────────────────────

  Future<String?> _getLastPunchType() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(_kLastPunchType);
  }

  /// True while the user is on an active shift — the only state in which
  /// alignment warnings (airplane mode, hidden network) make sense.
  Future<bool> _isPunchedIn() async =>
      await _getLastPunchType() == 'In';

  Future<void> _setLastPunchType(String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastPunchType, type);
  }

  Future<String> _getMatchedOffice() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kMatchedOfficeName) ?? '';
  }

  Future<void> _setMatchedOffice(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMatchedOfficeName, name);
  }

  Future<void> _setLastPunchTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastPunchTime, time.toIso8601String());
  }

  Future<bool> _isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    // Check the main isolate's Hive key via SharedPreferences mirror
    // Main isolate writes this when toggling WiFi auto-punch
    return prefs.getBool('wifi_auto_punch_enabled_bg') ?? true;
  }

  // ── HTTP Helpers ───────────────────────────────────────────────────────────

  Future<Dio?> _buildDio() async {
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

          debugPrint('[WIFI_BG] 401 on ${error.requestOptions.path} — attempting token refresh');

          try {
            final refreshed = await _refreshToken();
            if (refreshed == null) {
              return handler.next(error);
            }

            error.requestOptions.headers['Authorization'] = 'Bearer $refreshed';
            final retryResp = await dio.fetch(error.requestOptions);
            return handler.resolve(retryResp);
          } catch (e) {
            debugPrint('[WIFI_BG] Token refresh error: $e');
            return handler.next(error);
          }
        },
      ),
      PunchStateInterceptor(),
    ]);

    return dio;
  }

  Future<String?> _refreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Atomic cross-isolate lock claim (same protocol as TokenStorage):
    // write unique owner token, re-read, verify ownership.  If another
    // isolate wrote after us we lost the race → skip.
    final lockTs = prefs.getInt('bg_refresh_lock') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockTs > 0 && (now - lockTs) < 30000) {
      debugPrint('[WIFI_BG] Another isolate is refreshing — skipping');
      return null;
    }

    final owner = '$now-${DateTime.now().microsecondsSinceEpoch}';
    await prefs.setInt('bg_refresh_lock', now);
    await prefs.setString('bg_refresh_lock_owner', owner);
    await prefs.reload();
    final persistedOwner = prefs.getString('bg_refresh_lock_owner');
    final persistedTs = prefs.getInt('bg_refresh_lock') ?? 0;
    if (persistedOwner != owner || persistedTs != now) {
      debugPrint('[WIFI_BG] Lost refresh-lock race — skipping');
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
        debugPrint('[WIFI_BG] Session changed during refresh — discarding tokens');
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

      debugPrint('[WIFI_BG] Token refreshed successfully');
      return newAccess;
    } catch (e) {
      await prefs.remove('bg_refresh_lock');
      await prefs.remove('bg_refresh_lock_owner');

      debugPrint('[WIFI_BG] Token refresh failed — retaining tokens for main isolate');
      return null;
    }
  }

  // ── Last-in-method guard ─────────────────────────────────────────────────

  static const lastInMethodKey = 'wifi_last_in_method';

  /// Returns `true` if the last IN was done by WiFi auto-punch. Persisted
  /// across restarts so we don't unduly punch OUT a manual IN.
  Future<bool> _isLastInByWifi() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(lastInMethodKey) == 'wifi';
  }

  Future<void> _setLastInByWifi() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(lastInMethodKey, 'wifi');
  }

  Future<void> _clearLastInMethod() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(lastInMethodKey);
  }

  // ── Manual-out-on-wifi guard ────────────────────────────────────────────────

  static const manualOutOnWifiKey = 'wifi_manual_out_on_wifi';
  static const manualInKey = 'wifi_manual_in';

  Future<bool> _isManualOutOnWifi() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(manualOutOnWifiKey) ?? false;
  }

  Future<bool> _isManualIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(manualInKey) ?? false;
  }

  Future<void> _clearManualIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(manualInKey, false);
  }

  // ── Debug emit ──────────────────────────────────────────────────────────────

  void _emitDebug({
    required bool enabled,
    String? bssid,
    String? matchedName,
    String? lastPunchType,
  }) {
    _service.invoke('wifi_debug', {
      'ts': DateTime.now().toIso8601String(),
      'enabled': enabled,
      'bssid': bssid,
      'matchedName': matchedName,
      'lastPunchType': lastPunchType,
    });
  }

  Future<void> _persistWifiStatus({
    required String? bssid,
    required String? matchedName,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wifi_bg_bssid', bssid ?? '');
    await prefs.setString('wifi_bg_matched_name', matchedName ?? '');
    await prefs.setString('wifi_bg_ts', DateTime.now().toIso8601String());
  }

  // ── Pending OUT chamber ─────────────────────────────────────────────────────
  //
  // When WiFi drops and there's no internet (no mobile data), the OUT punch
  // can't be sent. We save it as "pending" and retry whenever connectivity
  // returns — even an hour later. The original disconnect timestamp is
  // preserved so the server records the correct punch-out time.

  Future<void> _savePendingOut({required String bssid}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPendingOut, true);
    await prefs.setString(_kPendingOutTs, DateTime.now().toIso8601String());
    await prefs.setString(_kPendingOutBssid, bssid);
    debugPrint('[WIFI_BG] Pending OUT saved — will retry when internet returns');
  }

  Future<void> _clearPendingOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPendingOut);
    await prefs.remove(_kPendingOutTs);
    await prefs.remove(_kPendingOutBssid);
  }

  Future<void> _flushPendingOut() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getBool(_kPendingOut) ?? false;
    if (!pending) return;

    // Check if any connectivity (mobile or wifi) is available now
    final conn = await Connectivity().checkConnectivity();
    final hasNetwork = conn.contains(ConnectivityResult.mobile) ||
        conn.contains(ConnectivityResult.wifi);
    if (!hasNetwork) {
      debugPrint('[WIFI_BG] Pending OUT: still no network — keeping for later');
      return;
    }

    final ts = prefs.getString(_kPendingOutTs) ?? '';
    final bssid = prefs.getString(_kPendingOutBssid) ?? '';
    debugPrint('[WIFI_BG] Flushing pending OUT (disconnected at $ts)');

    final ok = await _punchOut(bssid);
    if (ok) {
      await _clearPendingOut();
      debugPrint('[WIFI_BG] Pending OUT flushed successfully');
    } else {
      debugPrint('[WIFI_BG] Pending OUT still failing — keeping for later');
    }
  }

  // ── Cross-isolate disconnect guard ──────────────────────────────────────────
  //
  // Both foreground and background subscribe to the same connectivity stream
  // with independent cooldowns.  This guard ensures only ONE isolate punches
  // OUT per disconnect event — the first one to process marks the timestamp,
  // and the other skips.

  Future<bool> _isDisconnectAlreadyProcessed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ts = prefs.getInt(_kDisconnectProcessedTs) ?? 0;
    if (ts == 0) return false;
    final expired = (DateTime.now().millisecondsSinceEpoch - ts) >= _disconnectGuardMs;
    return !expired;
  }

  Future<void> _markDisconnectProcessed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kDisconnectProcessedTs, DateTime.now().millisecondsSinceEpoch);
    debugPrint('[WIFI_BG] Disconnect marked as processed (guard: ${_disconnectGuardMs}ms)');
  }

  // ── User Alignment Warnings ────────────────────────────────────────────────
  // Heads-up notifications that tell the employee (in plain words) when a
  // phone setting they changed is quietly breaking their auto punch, and
  // how to fix it.  Notification IDs are shared with the main-isolate
  // AlignmentMonitor so both isolates replace (not duplicate) each other.

  static const _kNoConnectivityWarned = 'wifi_bg_no_connectivity_warned';
  static const _kBssidWarnedTs = 'wifi_bg_bssid_warned_ts';
  static const _kAlignWarnCooldownMs = 10 * 60 * 1000; // 10 min
  static const _kNoConnectivityNotifId = 998;
  static const _kBssidHiddenNotifId = 997;

  /// Airplane mode / no signal at all — punches will be saved and sent later.
  /// Only nags while the user is punched in; at home, punched out, offline
  /// is normal and stays quiet.
  Future<void> _warnNoConnectivity() async {
    if (!await _isPunchedIn()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kNoConnectivityWarned) ?? false) return;
      await prefs.setBool(_kNoConnectivityWarned, true);
      await _showAlertNotification(
        _kNoConnectivityNotifId,
        'No network (airplane mode?)',
        'Attendance can\u2019t send or receive right now. WiFi punches will be '
        'saved and sent when you\u2019re back online. Swipe down from the top of '
        'your screen and turn off airplane mode.',
      );
    } catch (e) {
      debugPrint('[WIFI_BG] No-connectivity warning failed: $e');
    }
  }

  Future<void> _clearNoConnectivityWarning() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kNoConnectivityWarned) ?? false) {
        await prefs.setBool(_kNoConnectivityWarned, false);
        await _notifications.cancel(_kNoConnectivityNotifId);
      }
    } catch (e) {
      debugPrint('[WIFI_BG] No-connectivity warning clear failed: $e');
    }
  }

  /// Connected to WiFi but Android hides the network name (location/GPS off).
  /// Rate-limited so the 15s fallback poll doesn't spam the user.  Only nags
  /// while punched in.
  Future<void> _warnBssidUnreadable() async {
    if (!await _isPunchedIn()) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final lastWarned = prefs.getInt(_kBssidWarnedTs) ?? 0;
      if (now - lastWarned < _kAlignWarnCooldownMs) return;
      await prefs.setInt(_kBssidWarnedTs, now);
      await _showAlertNotification(
        _kBssidHiddenNotifId,
        'Connected to WiFi, but the app can\u2019t read it',
        'This happens when Location is off. Turn it on so auto punch can '
        'confirm you\u2019re on the office network. Phone Settings \u2192 Location.',
      );
    } catch (e) {
      debugPrint('[WIFI_BG] BSSID warning failed: $e');
    }
  }

  Future<void> _clearBssidWarning() async {
    try {
      await _notifications.cancel(_kBssidHiddenNotifId);
    } catch (e) {
      debugPrint('[WIFI_BG] BSSID warning clear failed: $e');
    }
  }

  /// Heads-up alert on the shared user-alignment channel.
  Future<void> _showAlertNotification(int id, String title, String body) async {
    try {
      await _notifications.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'user_alignment',
            'Attendance Alerts',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[WIFI_BG] Alert notification failed: $e');
    }
  }

  // ── Notification ───────────────────────────────────────────────────────────

  String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _showNotification(String title, String body) async {
    try {
      await _notifications.show(
        997,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'wifi_auto_punch_bg',
            'WiFi Auto-Punch (Background)',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[WIFI_BG] Notification failed: $e');
    }
  }
}
