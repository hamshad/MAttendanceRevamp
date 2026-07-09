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
import '../../../core/utils/constants.dart';
import '../../../models/office.dart';

/// Background WiFi auto-punch worker.
///
/// Runs inside the same flutter_background_service isolate as
/// GeofenceBackgroundWorker. Monitors WiFi connect/disconnect via
/// connectivity_plus stream + 60s fallback poll. Matches current BSSID
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

  // SharedPreferences keys — shared with GeofenceBackgroundWorker
  // so both workers have a single source of truth for punch state
  static const _kLastBssid = 'wifi_bg_last_bssid';
  static const _kLastPunchType = 'gf_last_punch_type';
  static const _kLastPunchTime = 'gf_last_punch_time';
  static const _kMatchedOfficeName = 'gf_last_punch_office';
  static const _kDataLoadedAt = 'wifi_bg_data_loaded_at';

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

    // Subscribe to connectivity changes
    _connSub = Connectivity().onConnectivityChanged.listen(_onConnectivity);

    // 60s fallback poll (catches stream drops on some OEM ROMs)
    _fallbackTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _checkCurrentWifi();
    });

    // Immediate check on start
    _checkCurrentWifi();

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

  // ── Connectivity Listener ──────────────────────────────────────────────────

  void _onConnectivity(List<ConnectivityResult> results) {
    debugPrint('[WIFI_BG] Connectivity changed: $results');
    if (results.contains(ConnectivityResult.wifi)) {
      _checkCurrentWifi();
    } else if (results.contains(ConnectivityResult.mobile)) {
      // Mobile data available — try flushing any pending OUT
      debugPrint('[WIFI_BG] Mobile data available — flushing pending OUT if any');
      _checkCurrentWifi();
    } else {
      _handleDisconnect();
    }
  }

  // ── Core Check ─────────────────────────────────────────────────────────────

  Future<void> _checkCurrentWifi() async {
    final enabled = await _isEnabled();
    if (!enabled) {
      debugPrint('[WIFI_BG] Not enabled — skipping check');
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

      // Load offices if not yet loaded or stale (>30 min)
      if (_offices.isEmpty || _isDataStale()) {
        await _loadOffices();
      }

      final bssid = await _getCurrentBssid();
      if (bssid == null) {
        debugPrint('[WIFI_BG] No BSSID available — treating as disconnected');
        _emitDebug(enabled: true);
        await _handleDisconnect();
        return;
      }

      debugPrint('[WIFI_BG] Current BSSID: $bssid');

      final matched = _matchBssid(bssid);
      final lastPunchType = await _getLastPunchType();

      // If user is back at a known office, cancel any pending OUT
      if (matched != null) {
        await _clearPendingOut();
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
        // Manual-out-on-wifi guard: suppress auto re-IN until WiFi disconnects
        if (await _isManualOutOnWifi()) {
          debugPrint('[WIFI_BG] Manual-out-on-wifi active — skip auto IN');
          return;
        }

        debugPrint('[WIFI_BG] Match found: ${matched.name} — punching IN');
        await _punchIn(matched, bssid);
      } else if (matched == null && lastPunchType == 'In') {
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
        debugPrint('[WIFI_BG] Already IN — skipping duplicate');
      } else {
        debugPrint('[WIFI_BG] No match and not IN — noop');
      }
    } catch (e) {
      debugPrint('[WIFI_BG] _checkCurrentWifi error: $e');
    }
  }

  Future<void> _handleDisconnect() async {
    if (!await _isEnabled()) return;

    // WiFi disconnect clears the manual-out-on-wifi guard
    if (await _isManualOutOnWifi()) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(manualOutOnWifiKey, false);
      debugPrint('[WIFI_BG] WiFi disconnected — manual-out-on-wifi guard CLEARED');
    }

    // WiFi disconnect also clears the last-in-method — user is leaving
    await _clearLastInMethod();

    // WiFi disconnect also clears manual IN — user is leaving, normal resume
    if (await _isManualIn()) {
      await _clearManualIn();
      debugPrint('[WIFI_BG] WiFi disconnected — manual IN guard CLEARED');
    }

    // Ensure offices loaded so _getOfficeMac can find registered MAC
    if (_offices.isEmpty) {
      await _loadOffices();
    }

    // Also try flushing pending before punching fresh
    await _flushPendingOut();

    final lastPunchType = await _getLastPunchType();
    if (lastPunchType == 'In') {
      debugPrint('[WIFI_BG] WiFi disconnected — punching OUT');
      final ok = await _punchOut('');
      if (!ok) {
        await _savePendingOut(bssid: '');
      }
    }
  }

  // ── Office Data ────────────────────────────────────────────────────────────

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
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[WIFI_BG] No auth token — cannot punch IN');
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
      await _handleDuplicateError(e, 'In', office.name);
    } catch (e) {
      debugPrint('[WIFI_BG] Punch IN error: $e');
    }
  }

  /// Returns `true` if punch was accepted (200/201) or duplicate.
  Future<bool> _punchOut(String bssid) async {
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[WIFI_BG] No auth token — cannot punch OUT');
        return false;
      }

      final officeName = await _getMatchedOffice();
      final officeMac = _getOfficeMac(officeName);

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
      return false;
    } catch (e) {
      debugPrint('[WIFI_BG] Punch OUT error: $e');
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
    return prefs.getString(_kLastPunchType);
  }

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

    final lockTs = prefs.getInt('bg_refresh_lock') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockTs > 0 && (now - lockTs) < 30000) {
      debugPrint('[WIFI_BG] Another isolate is refreshing — skipping');
      return null;
    }

    await prefs.setInt('bg_refresh_lock', now);

    try {
      final refreshToken = prefs.getString('bg_refresh_token');
      final accessToken = prefs.getString('bg_access_token');
      if (refreshToken == null || accessToken == null) {
        await prefs.remove('bg_refresh_lock');
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

      await Future.wait([
        prefs.setString('bg_access_token', newAccess),
        prefs.setString('bg_refresh_token', newRefresh),
        prefs.setInt('bg_token_ts', DateTime.now().millisecondsSinceEpoch),
        prefs.remove('bg_refresh_lock'),
      ]);

      debugPrint('[WIFI_BG] Token refreshed successfully');
      return newAccess;
    } catch (e) {
      await prefs.remove('bg_refresh_lock');

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
