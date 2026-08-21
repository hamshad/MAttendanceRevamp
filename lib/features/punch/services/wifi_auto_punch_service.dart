import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/services/office_data_service.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/app_logger.dart';
import '../../../models/office.dart';
import './wifi_service.dart';
import './punch_state_service.dart';

class WifiAutoPunchService {
  static const _enabledKey = 'wifiAutoPunchEnabled';
  static const _registeredSsidKey = 'wifiAutoRegisteredSsid';
  static const _lastMacKey = 'wifiAutoLastMac';
  static const _currentOfficeNameKey = 'wifiAutoCurrentOfficeName';

  // Track last punch state
  static const _lastPunchStatusKey = 'wifiLastPunchStatus';

  // Manual-out-on-wifi flag: when user manually punches OUT while connected
  // to office WiFi, suppress auto re-IN until WiFi disconnects (trigger edge).
  // Day-boundary expiry: set-time is stored alongside so a manual OUT on one
  // day can't silently block next-day auto IN when iOS never delivers a WiFi
  // disconnect event (phone stays connected overnight / auto-rejoins).
  static const _manualOutOnWifiKey = 'wifiManualOutOnWifi';
  static const _manualOutOnWifiTimeKey = 'wifiManualOutOnWifiTime';

  // Manual IN flag: when user manually punches IN (GPS, NFC, etc.), suppress
  // auto WiFi OUT — don't let WiFi undo a manual punch.
  static const _manualInKey = 'wifiManualIn';

  // Pending OUT keys (mirrors wifi_background_worker.dart)
  static const _pendingOutKey = 'wifi_pending_out';
  static const _pendingOutTsKey = 'wifi_pending_out_ts';
  static const _pendingOutBssidKey = 'wifi_pending_out_bssid';

  static const String defaultCompanySsid = 'Moksha_Office';

  final Dio _dio;
  final FlutterLocalNotificationsPlugin _notifications;
  final WifiService _wifiService = WifiService();

  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _running = false;
  bool get isRunning => _running;

  final void Function()? onPunch;
 
   WifiAutoPunchService({
     required Dio dio,
     required FlutterLocalNotificationsPlugin notifications,
     this.onPunch,
   })  : _dio = dio,
         _notifications = notifications {
     print('WIFI_AUTO: Service instance created');
   }

  // ── Preferences ─────────────────────────────────────────────

  static bool get isEnabled {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_enabledKey, defaultValue: false) as bool;
  }

  static Future<void> setEnabled(bool value) async {
    await Hive.box(AppConstants.cacheBox).put(_enabledKey, value);
    // Mirror to SharedPreferences so background worker can read it
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_auto_punch_enabled_bg', value);
  }

  static String get registeredSsid {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_registeredSsidKey, defaultValue: defaultCompanySsid) as String;
  }

  static Future<void> setRegisteredSsid(String ssid) =>
      Hive.box(AppConstants.cacheBox).put(_registeredSsidKey, ssid);

  // ✅ NEW: Punch state
  static String get lastPunchStatus {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_lastPunchStatusKey, defaultValue: '') as String;
  }

  static String get lastMac {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_lastMacKey, defaultValue: '') as String;
  }

  static String get currentOfficeName {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_currentOfficeNameKey, defaultValue: '') as String;
  }

  static Future<void> setLastMac(String mac) =>
      Hive.box(AppConstants.cacheBox).put(_lastMacKey, mac);

  static Future<void> setCurrentOfficeName(String name) =>
      Hive.box(AppConstants.cacheBox).put(_currentOfficeNameKey, name);

  static Future<void> setLastPunchStatus(String status) async {
    await Hive.box(AppConstants.cacheBox).put(_lastPunchStatusKey, status);
    // NOTE: do NOT stamp gf_last_punch_time here — PunchStateInterceptor
    // (dio) is the single source of truth and stamps it on real punch API
    // responses. Writing it here on every status sync (app open/resume)
    // makes the 30s rate limiter in _isRateLimited() self-block the
    // auto-punch check that runs right after the sync.
  }

  static bool get manualOutOnWifi {
    final box = Hive.box(AppConstants.cacheBox);
    final flag = box.get(_manualOutOnWifiKey, defaultValue: false) as bool;
    if (!flag) return false;

    // Day-boundary expiry: a manual OUT is a same-day trigger-edge guard.
    // If it was set on a previous calendar day — OR was written by an older
    // build that didn't record a timestamp (time == 0) — treat as expired:
    // the user is back for a new shift and the disconnect event may never
    // have fired (iOS keeps the phone on office WiFi). Clearing lazily also
    // unblocks devices carrying a legacy stuck flag from before this change.
    final setTime =
        box.get(_manualOutOnWifiTimeKey, defaultValue: 0) as int;
    if (setTime <= 0) {
      AppLogger.i('WIFI_AUTO: manual-out-on-wifi has no timestamp (legacy) — clearing');
      clearManualOutOnWifi(); // fire-and-forget, getter stays sync
      return false;
    }
    final setDay = DateTime.fromMillisecondsSinceEpoch(setTime);
    final now = DateTime.now();
    final isSameDay = setDay.year == now.year &&
        setDay.month == now.month &&
        setDay.day == now.day;
    if (!isSameDay) {
      AppLogger.i('WIFI_AUTO: manual-out-on-wifi expired (set ${setDay.toIso8601String()}) — clearing');
      clearManualOutOnWifi(); // fire-and-forget, getter stays sync
      return false;
    }
    return true;
  }

  static Future<void> setManualOutOnWifi() async {
    await Hive.box(AppConstants.cacheBox).put(_manualOutOnWifiKey, true);
    final now = DateTime.now().millisecondsSinceEpoch;
    await Hive.box(AppConstants.cacheBox).put(_manualOutOnWifiTimeKey, now);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_manual_out_on_wifi', true);
    // Prefs mirror keeps the background worker on the same expiry schedule.
    await prefs.setInt('wifi_manual_out_on_wifi_time', now);
    AppLogger.i('WIFI_AUTO: Manual-out-on-wifi flag SET');
  }

  static Future<void> clearManualOutOnWifi() async {
    await Hive.box(AppConstants.cacheBox).put(_manualOutOnWifiKey, false);
    await Hive.box(AppConstants.cacheBox).put(_manualOutOnWifiTimeKey, 0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_manual_out_on_wifi', false);
    await prefs.setInt('wifi_manual_out_on_wifi_time', 0);
    AppLogger.d('WIFI_AUTO: Manual-out-on-wifi flag CLEARED');
  }

  static bool get manualIn {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_manualInKey, defaultValue: false) as bool;
  }

  static Future<void> setManualIn() async {
    await Hive.box(AppConstants.cacheBox).put(_manualInKey, true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_manual_in', true);
    AppLogger.i('WIFI_AUTO: Manual IN flag SET');
  }

  static Future<void> clearManualIn() async {
    await Hive.box(AppConstants.cacheBox).put(_manualInKey, false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_manual_in', false);
    AppLogger.d('WIFI_AUTO: Manual IN flag CLEARED');
  }

  // Last-IN method (persisted via SP for bg worker compatibility)
  static const _lastInMethodKey = 'wifi_last_in_method';

  static String get lastInMethod {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_lastInMethodKey, defaultValue: '') as String;
  }

  static Future<void> markLastInByWifi() async {
    await Hive.box(AppConstants.cacheBox).put(_lastInMethodKey, 'wifi');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastInMethodKey, 'wifi');
  }

  static Future<void> markLastInManual() async {
    await Hive.box(AppConstants.cacheBox).put(_lastInMethodKey, 'manual');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastInMethodKey, 'manual');
  }

  static Future<void> clearLastInMethod() async {
    await Hive.box(AppConstants.cacheBox).put(_lastInMethodKey, '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastInMethodKey);
  }

  Future<void> syncState({required String status, String? officeName}) async {
    AppLogger.i('WIFI_AUTO: Syncing state from UI -> $status (Office: $officeName)');
    await setLastPunchStatus(status);
    if (officeName != null) {
      await setCurrentOfficeName(officeName);
    }

    // Manual IN resets the manual-out-on-wifi guard — user wants to be tracked.
    if (status == 'In') {
      await clearManualOutOnWifi();
    } else if (status == 'Out') {
      await clearLastInMethod();
    }
    
    // If user is IN, try to capture and "learn" the current WiFi as the office WiFi
    if (status == 'In') {
      try {
        final info = await _wifiService.getCurrentWifi();
        if (info.ssid.isNotEmpty && info.bssid.isNotEmpty) {
          AppLogger.i('WIFI_AUTO: Learning WiFi for $officeName -> SSID: ${info.ssid}, MAC: ${info.bssid}');
          await setLastMac(info.bssid);
          // We could also save SSID specifically if needed
        }
      } catch (_) {}
    }
  }
 
  Future<void> updateLastPunchStatus(String status) => syncState(status: status);

  // ── Pending OUT ────────────────────────────────────────────

  static Future<bool> hasPendingOut() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_pendingOutKey) ?? false;
  }

  static Future<String> getPendingOutBssid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pendingOutBssidKey) ?? '';
  }

  Future<void> _savePendingOut() async {
    AppLogger.i('WIFI_AUTO: Saving pending OUT (no internet)');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_pendingOutKey, true);
    await prefs.setString(_pendingOutTsKey, DateTime.now().toIso8601String());
    await prefs.setString(_pendingOutBssidKey, lastMac);
  }

  Future<void> _flushPendingOut() async {
    if (!await hasPendingOut()) return;

    AppLogger.i('WIFI_AUTO: Flushing pending OUT');
    final prefs = await SharedPreferences.getInstance();
    final bssid = prefs.getString(_pendingOutBssidKey) ?? lastMac;

    try {
      String ip = '0.0.0.0';
      try {
        ip = await _wifiService.getWifiIP() ?? '0.0.0.0';
      } catch (_) {}

      final response = await _dio.post(ApiEndpoints.punch, data: {
        'Method': 'WiFi',
        'Direction': 'Out',
        'WifiMAC': bssid,
        'IPAddress': ip,
        'remarks': 'Auto Punch-Out (pending delivery)',
      });

      if (response.statusCode == 200) {
        AppLogger.i('WIFI_AUTO: Pending OUT flushed successfully');
        await _clearPendingOut();
        await setLastPunchStatus('Out');
        await setCurrentOfficeName('');
        onPunch?.call();
      }
    } catch (e) {
      if (e.toString().contains('Duplicate punch detected')) {
        AppLogger.w('WIFI_AUTO: Pending OUT duplicate — clearing');
        await _clearPendingOut();
        await setLastPunchStatus('Out');
        await setCurrentOfficeName('');
        onPunch?.call();
      } else {
        AppLogger.e('WIFI_AUTO: Pending OUT flush failed — will retry', e);
      }
    }
  }

  Future<void> _clearPendingOut() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_pendingOutKey);
    await prefs.remove(_pendingOutTsKey);
    await prefs.remove(_pendingOutBssidKey);
  }

  // ── Lifecycle ──────────────────────────────────────────────

  Future<void> start() async {
    AppLogger.v('WIFI_AUTO: start() called. Already running: $_running');
    if (_running) return;
 
    // Sync enabled state to SharedPreferences for background worker
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_auto_punch_enabled_bg', true);

    AppLogger.i('WIFI_AUTO: Starting monitor');

    _subscription =
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);

    _running = true;

    // Immediate check
    await checkAndPunchIfEnabled();
  }

  void stop() async {
    _subscription?.cancel();
    _subscription = null;
    _running = false;

    // Sync disabled state to SharedPreferences for background worker
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_auto_punch_enabled_bg', false);

    AppLogger.i('WIFI_AUTO: Monitoring stopped');
  }

  // ── Connectivity Listener ──────────────────────────────────

  Future<void> _onConnectivityChanged(
      List<ConnectivityResult> results) async {
    if (results.contains(ConnectivityResult.wifi)) {
      AppLogger.d('WIFI_AUTO: WiFi connected');
      await checkAndPunchIfEnabled();
    } else if (results.contains(ConnectivityResult.mobile)) {
      AppLogger.d('WIFI_AUTO: Mobile data available');
      await _flushPendingOut();
      await checkAndPunchIfEnabled();
    } else {
      AppLogger.d('WIFI_AUTO: Connectivity lost — re-checking before declaring disconnect');
      await checkAndPunchIfEnabled();
    }
  }

  // ── Main Entry ─────────────────────────────────────────────

  Future<void> checkAndPunchIfEnabled() async {
    AppLogger.v('WIFI_AUTO: checkAndPunchIfEnabled() - isEnabled: $isEnabled');
    if (!isEnabled) return;

    // Rate limit: skip if any WiFi/geofence punch in last 30s
    // (coordinates with background worker via SharedPreferences).
    if (await _isRateLimited()) {
      AppLogger.d('WIFI_AUTO: Rate limited — skipping');
      return;
    }

    await _checkCurrentConnection();
  }

  /// Rate limiter: shares SP key `gf_last_punch_time` with background workers.
  Future<bool> _isRateLimited([Duration duration = const Duration(seconds: 30)]) async {
    final prefs = await SharedPreferences.getInstance();
    final lastTs = prefs.getString('gf_last_punch_time');
    if (lastTs == null) return false;
    final last = DateTime.tryParse(lastTs);
    if (last == null) return false;
    return DateTime.now().difference(last) < duration;
  }

  /// Mediator: ask the backend for the employee's current punch state.
  ///
  /// Returns `null` on error so callers fall back to local Hive state. This
  /// is what lets WiFi auto-punch see punches recorded by OTHER methods
  /// (Web / GPS / Biometric) that local state never learns about.
  Future<ServerPunchState?> _fetchServerState() =>
      PunchStateService(_dio).fetch();

  // ── Check Current WiFi ─────────────────────────────────────

  Future<void> _checkCurrentConnection() async {
    AppLogger.v('WIFI_AUTO: _checkCurrentConnection() starting check...');
    try {
      final info = await _wifiService.getCurrentWifi();
      AppLogger.d('WIFI_AUTO: Current WiFi SSID: ${info.ssid}, BSSID: ${info.bssid}');

      final cached = OfficeDataService.getCachedOffices();
      final offices = cached ?? [];
      AppLogger.d('WIFI_AUTO: Found ${offices.length} cached offices to check against');

      Office? matchedOffice;

      final normalizedInfoMac = info.bssid.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
      final normalizedInfoSsid = info.ssid.trim().toLowerCase();

      for (final office in offices) {
        // 1. Check wifiRouters list (primary — matches by macId)
        if (office.wifiRouters != null) {
          for (final router in office.wifiRouters!) {
            final normalizedRouterMac = router.macId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
            if (normalizedRouterMac.isNotEmpty && normalizedRouterMac == normalizedInfoMac) {
              AppLogger.i('WIFI_AUTO: Match via wifiRouters: ${router.macId} → ${office.name}');
              matchedOffice = office;
              break;
            }
          }
          if (matchedOffice != null) break;
        }

        // 2. Fallback: legacy wifiMAC field
        final normalizedLegacyMac = (office.wifiMAC ?? '').replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
        if (normalizedLegacyMac.isNotEmpty && normalizedLegacyMac == normalizedInfoMac) {
          AppLogger.i('WIFI_AUTO: Match via legacy wifiMAC: ${office.wifiMAC} → ${office.name}');
          matchedOffice = office;
          break;
        }

        // 3. Fallback: legacy wifiSSID (only if wifiMAC is empty)
        final normalizedLegacySsid = (office.wifiSSID ?? '').trim().toLowerCase();
        if (normalizedLegacySsid.isNotEmpty && normalizedLegacySsid == normalizedInfoSsid && (office.wifiMAC == null || office.wifiMAC!.isEmpty)) {
          AppLogger.i('WIFI_AUTO: Match via legacy wifiSSID: ${office.wifiSSID} → ${office.name}');
          matchedOffice = office;
          break;
        }

        // 4. Learned MAC fallback
        if (office.name == currentOfficeName && lastMac.isNotEmpty) {
          final normalizedLastMac = lastMac.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();
          if (normalizedLastMac == normalizedInfoMac) {
            AppLogger.i('WIFI_AUTO: Match via learned MAC for office "${office.name}"');
            matchedOffice = office;
            break;
          }
        }

        AppLogger.v('WIFI_AUTO: No match for office "${office.name}"');
      }

      // Pending OUT: if user returned to matched BSSID, cancel pending; else flush
      if (await hasPendingOut()) {
        if (matchedOffice != null) {
          AppLogger.i('WIFI_AUTO: Pending OUT cancelled — user returned to ${matchedOffice.name}');
          await _clearPendingOut();
        } else {
          await _flushPendingOut();
        }
      }

      if (matchedOffice != null) {
        AppLogger.i('WIFI_AUTO: Match found! Office: ${matchedOffice.name}');
        await _triggerPunch(info, matchedOffice);
      } else {
        AppLogger.d('WIFI_AUTO: No office match for this SSID/MAC');
        await _triggerPunch(info, null);
      }
    } catch (e) {
      AppLogger.v('WIFI_AUTO: No WiFi connection, verifying punch status');
      // Flush any pending OUT via mobile data if available
      await _flushPendingOut();
      await _handleWifiDisconnected();
    }
  }

  // ── Trigger Punch ──────────────────────────────────────────

  Future<void> _triggerPunch(WifiInfo info, Office? matchedOffice) async {
    final lastStatus = lastPunchStatus;
    final isMatch = matchedOffice != null;

    if (isMatch) {
      if (lastStatus == 'In') {
        // Phone on registered WiFi while already IN.  Mark last IN as WiFi
        // so a future disconnect triggers OUT correctly.
        if (lastInMethod != 'wifi') {
          await markLastInByWifi();
          AppLogger.i('WIFI_AUTO: Already IN on registered WiFi — marking lastIn=wifi');
        }
        return;
      }

      // ── Mediator: server is source of truth for "already punched in" ──
      // A Web/GPS/Biometric punch on another device is invisible to local
      // state. If the backend already shows the employee IN, skip the
      // duplicate IN entirely.
      final server = await _fetchServerState();
      if (server != null && server.isPunchedIn) {
        AppLogger.i(
          'WIFI_AUTO: Server already IN (method=${server.lastMethod}) — '
          'skipping duplicate WiFi IN',
        );
        await setLastPunchStatus('In');
        await setCurrentOfficeName(matchedOffice.name);
        if (server.lastMethod == 'WiFi') {
          await markLastInByWifi();
        } else {
          await clearManualIn();
          await clearLastInMethod();
        }
        return;
      }

      // Manual-IN guard: last punch was manual (GPS/NFC), not WiFi.
      // Prevent duplicate IN when user manually punched in then connects to
      // office WiFi.  `lastInMethod` persists in Hive so this survives
      // app restarts and async race with syncState().
      if (lastInMethod == 'manual') {
        AppLogger.i('WIFI_AUTO: Last IN was manual — skip auto WiFi IN (prevent duplicate)');
        return;
      }

      // Manual-out-on-wifi guard: if user manually punched OUT while still
      // connected to office WiFi, suppress auto re-IN until WiFi disconnects
      // (trigger edge — handled in _handleWifiDisconnected).
      if (manualOutOnWifi) {
        AppLogger.i('WIFI_AUTO: Manual-out-on-wifi active — skip auto IN (wait for WiFi disconnect)');
        return;
      }

      try {
        // Get IP Address
        String ip = '0.0.0.0';
        try {
          ip = await _wifiService.getWifiIP() ?? '0.0.0.0';
        } catch (_) {}

        final response = await _dio.post(ApiEndpoints.punch, data: {
          'Method': 'WiFi',
          'Direction': 'In',
          'WifiSSID': info.ssid,
          'WifiMAC': info.bssid,
          'IPAddress': ip,
        });

        if (response.statusCode == 200) {
          AppLogger.i('WIFI_AUTO: Successfully punched IN');
          await setLastPunchStatus('In');
          await setLastMac(_getRegisteredOfficeMac(matchedOffice.name));
          await setCurrentOfficeName(matchedOffice.name);
          await clearManualIn();
          await markLastInByWifi();
          await _showNotification(info.ssid, 'In');
          onPunch?.call();
        }
      } catch (e) {
        if (e.toString().contains('Duplicate punch detected')) {
          AppLogger.w('WIFI_AUTO: Duplicate punch detected. Syncing local state.');
          await setLastPunchStatus('In');
          await setCurrentOfficeName(matchedOffice.name);
          await clearManualIn();
          await markLastInByWifi();
          onPunch?.call();
          return;
        }
        AppLogger.e('WIFI_AUTO: Punch IN failed', e);
      }
    } else {
      if (lastStatus == 'In') {
        // Manual OUT guard: if user manually punched OUT while on office WiFi,
        // suppress auto OUT on BSSID mismatch. WiFi-disconnect OUT still fires.
        if (manualOutOnWifi) {
          AppLogger.i('WIFI_AUTO: Manual-out-on-wifi active — skip auto OUT (BSSID mismatch)');
          return;
        }
        // Last-IN-method guard: only punch OUT on BSSID mismatch if last IN
        // was via WiFi auto-punch. Manual IN (GPS/NFC) should not be undone.
        if (lastInMethod != 'wifi') {
          AppLogger.i('WIFI_AUTO: Last IN not via WiFi — skip auto OUT (BSSID mismatch)');
          return;
        }

        // ── Mediator: server is source of truth for "already punched out" ──
        // If the employee already punched OUT via Web/GPS/Biometric elsewhere,
        // don't send a redundant WiFi OUT.
        final serverOut = await _fetchServerState();
        if (serverOut != null && serverOut.isPunchedOut) {
          AppLogger.i('WIFI_AUTO: Server already OUT — skipping duplicate WiFi OUT');
          await setLastPunchStatus('Out');
          await setCurrentOfficeName('');
          return;
        }

        AppLogger.i('WIFI_AUTO: Left office WiFi → Punch OUT');
        final mac = _getRegisteredOfficeMac(currentOfficeName);
        try {
          String ip = '0.0.0.0';
          try {
            ip = await _wifiService.getWifiIP() ?? '0.0.0.0';
          } catch (_) {}

          final response = await _dio.post(ApiEndpoints.punch, data: {
            'Method': 'WiFi',
            'Direction': 'Out',
            'WifiSSID': info.ssid,
            'WifiMAC': mac,
            'IPAddress': ip,
            'remarks': 'Auto Punch-Out (WiFi SSID mismatch)',
          });

          if (response.statusCode == 200) {
            AppLogger.i('WIFI_AUTO: Successfully punched OUT (SSID mismatch)');
            await setLastPunchStatus('Out');
            await setCurrentOfficeName('');
            await _showNotification(info.ssid, 'Out');
            onPunch?.call();
          }
        } catch (e) {
          if (e.toString().contains('Duplicate punch detected')) {
            AppLogger.w('WIFI_AUTO: Duplicate punch detected (Out). Syncing local state.');
            await setLastPunchStatus('Out');
            await setCurrentOfficeName('');
            onPunch?.call();
            return;
          }
          AppLogger.e('WIFI_AUTO: Punch OUT failed — saving pending', e);
          await _savePendingOut();
        }
      }
    }
  }

  // ── Handle WiFi Disconnect ─────────────────────────────────

  /// Look up the office's registered MAC (from wifiRouters or wifiMAC).
  /// Server rejects OUT punches that send unregistered MACs ("Unregistered WiFi network.").
  String _getRegisteredOfficeMac(String officeName) {
    if (officeName.isEmpty) return lastMac;
    final cached = OfficeDataService.getCachedOffices();
    if (cached == null) return lastMac;
    final office = cached.cast<Office?>().firstWhere(
      (o) => o?.name == officeName,
      orElse: () => null,
    );
    if (office == null) return lastMac;
    if (office.wifiRouters != null && office.wifiRouters!.isNotEmpty) {
      return office.wifiRouters!.first.macId;
    }
    return office.wifiMAC ?? lastMac;
  }

  Future<void> _handleWifiDisconnected() async {
    if (!isEnabled) return;

    // WiFi disconnect clears the manual-out-on-wifi guard — the trigger edge
    // has now cycled, so auto IN is allowed again on next reconnect.
    if (manualOutOnWifi) {
      await clearManualOutOnWifi();
    }

    final lastStatus = lastPunchStatus;

    if (lastStatus == 'In') {
      // Last-IN-method guard: manual IN (GPS/NFC) should not be undone
      // by WiFi state changes.
      if (lastInMethod != 'wifi') {
        AppLogger.i('WIFI_AUTO: Last IN not via WiFi — skip auto OUT on disconnect');
        return;
      }

      // ── Mediator: server is source of truth for "already punched out" ──
      // If the employee already punched OUT via Web/GPS/Biometric elsewhere,
      // don't send a redundant WiFi OUT on disconnect.
      final serverOut = await _fetchServerState();
      if (serverOut != null && serverOut.isPunchedOut) {
        AppLogger.i('WIFI_AUTO: Server already OUT — skipping duplicate WiFi OUT on disconnect');
        await setLastPunchStatus('Out');
        await setCurrentOfficeName('');
        await clearManualIn();
        await clearLastInMethod();
        return;
      }

      AppLogger.i('WIFI_AUTO: WiFi lost → Punch OUT');

      final mac = _getRegisteredOfficeMac(currentOfficeName);
  
      try {
        String ip = '0.0.0.0';
        try {
          ip = await _wifiService.getWifiIP() ?? '0.0.0.0';
        } catch (_) {}

        final response = await _dio.post(ApiEndpoints.punch, data: {
          'Method': 'WiFi',
          'Direction': 'Out',
          'WifiMAC': mac,
          'IPAddress': ip,
          'remarks': 'Auto Punch-Out (WiFi disconnected)',
        });

        if (response.statusCode == 200) {
          AppLogger.i('WIFI_AUTO: Successfully punched OUT (Disconnected)');
          await setLastPunchStatus('Out');
          await setCurrentOfficeName('');
          await clearManualIn();
          await clearLastInMethod();
          onPunch?.call();
          await _showNotification('', 'Out');
        }
      } catch (e) {
        if (e.toString().contains('Duplicate punch detected')) {
          AppLogger.w('WIFI_AUTO: Duplicate punch detected (Disconnected). Syncing local state.');
          await setLastPunchStatus('Out');
          await setCurrentOfficeName('');
          await clearManualIn();
          await clearLastInMethod();
          onPunch?.call();
          return;
        }
        AppLogger.e('WIFI_AUTO: Punch OUT failed — saving pending', e);
        await _savePendingOut();
      }
    }
  }

  // ── Notification ──────────────────────────────────────────

  Future<void> _showNotification(String ssid, String direction) async {
    final isPresent = direction == 'In';
    final title = isPresent ? 'Auto-Punch In' : 'Auto-Punch Out';
    final now = DateTime.now();
    final time =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final body = isPresent ? '${ssid.isNotEmpty ? "$ssid · " : ""}$time' : time;

    const android = AndroidNotificationDetails(
      'wifi_auto_punch',
      'WiFi Auto-Punch',
      importance: Importance.high,
      priority: Priority.high,
    );

    await _notifications.show(
      isPresent ? 888 : 889,
      title,
      body,
      const NotificationDetails(android: android),
    );
  }
}