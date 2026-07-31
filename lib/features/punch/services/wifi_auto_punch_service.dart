import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/offline/offline_queue.dart';
import '../../../core/offline/offline_sync_manager.dart';
import '../../../core/services/office_data_service.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/app_logger.dart';
import '../../../models/offline_punch.dart';
import '../../../models/office.dart';
import './wifi_service.dart';

class WifiAutoPunchService {
  static const _enabledKey = 'wifiAutoPunchEnabled';
  static const _registeredSsidKey = 'wifiAutoRegisteredSsid';
  static const _lastMacKey = 'wifiAutoLastMac';
  static const _currentOfficeNameKey = 'wifiAutoCurrentOfficeName';

  // Track last punch state
  static const _lastPunchStatusKey = 'wifiLastPunchStatus';

  // Manual-out-on-wifi flag: when user manually punches OUT while connected
  // to office WiFi, suppress auto re-IN until WiFi disconnects (trigger edge).
  static const _manualOutOnWifiKey = 'wifiManualOutOnWifi';

  // Manual IN flag: when user manually punches IN (GPS, NFC, etc.), suppress
  // auto WiFi OUT — don't let WiFi undo a manual punch.
  static const _manualInKey = 'wifiManualIn';

  // Pending OUT keys (mirrors wifi_background_worker.dart)
  static const _pendingOutKey = 'wifi_pending_out';
  static const _pendingOutTsKey = 'wifi_pending_out_ts';
  static const _pendingOutBssidKey = 'wifi_pending_out_bssid';

  static const String defaultCompanySsid = 'Moksha_Office';

  // Cross-isolate disconnect guard — shared with WifiBackgroundWorker.
  // Only one isolate should punch OUT per disconnect event.
  // The first to process marks the timestamp; the other skips.
  static const String _disconnectProcessedKey = 'wifi_disconnect_processed_ts';
  static const int _disconnectGuardMs = 30000;

  static Future<bool> isDisconnectAlreadyProcessed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final ts = prefs.getInt(_disconnectProcessedKey) ?? 0;
    if (ts == 0) return false;
    return (DateTime.now().millisecondsSinceEpoch - ts) < _disconnectGuardMs;
  }

  static Future<void> markDisconnectProcessed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_disconnectProcessedKey, DateTime.now().millisecondsSinceEpoch);
    AppLogger.d('WIFI_AUTO: Disconnect marked as processed (guard: ${_disconnectGuardMs}ms)');
  }

  // Cooldown after a punch action — prevents rapid IN→OUT when two
  // WiFi scans within the same frame return different results on startup.
  static const int _cooldownMs = 10000;
  static int _lastPunchTimestamp = 0;

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
    return box.get(_enabledKey, defaultValue: true) as bool;
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

  static String get lastPunchStatus {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_lastPunchStatusKey, defaultValue: 'unknown') as String;
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
    // Mirror to SharedPreferences so background worker (which reads
    // gf_last_punch_type) sees the update without waiting for a punch
    // API response.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gf_last_punch_type', status);
    _lastPunchTimestamp = DateTime.now().millisecondsSinceEpoch;
  }

  static bool get manualOutOnWifi {
    final box = Hive.box(AppConstants.cacheBox);
    return box.get(_manualOutOnWifiKey, defaultValue: false) as bool;
  }

  static Future<void> setManualOutOnWifi() async {
    await Hive.box(AppConstants.cacheBox).put(_manualOutOnWifiKey, true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_manual_out_on_wifi', true);
    AppLogger.i('WIFI_AUTO: Manual-out-on-wifi flag SET');
  }

  static Future<void> clearManualOutOnWifi() async {
    await Hive.box(AppConstants.cacheBox).put(_manualOutOnWifiKey, false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_manual_out_on_wifi', false);
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

    // Also queue into the Hive offline queue so OfflineSyncManager delivers
    // it when connectivity returns — even if the app is killed (the SP flag
    // only survives while the isolate runs).
    try {
      final punch = OfflinePunch()
        ..method = 'WiFi'
        ..direction = 'Out'
        ..wifiMAC = lastMac.isNotEmpty ? lastMac : 'unknown'
        ..createdAt = DateTime.now();
      await OfflineQueueService().enqueue(punch);
      await OfflineSyncManager.scheduleNow();
      AppLogger.i('WIFI_AUTO: queued WiFi OUT to offline queue');
    } catch (e) {
      AppLogger.e('WIFI_AUTO: offline queue enqueue failed', e);
    }
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

    // No immediate check here — the connectivity stream fires asynchronously
    // right after subscription, which triggers _onConnectivityChanged →
    // checkAndPunchIfEnabled().  Adding another call here would run two
    // WiFi scans back-to-back, and the second scan can return a different
    // BSSID (radio still busy), causing the first scan to punch IN and the
    // second to punch OUT.
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
      // Don't call checkAndPunchIfEnabled on mobile data — there's no WiFi
      // connection to check, and getCurrentWifi() can return a stale cached
      // BSSID on Android, causing a false IN punch on phantom WiFi.
    } else {
      AppLogger.d('WIFI_AUTO: Connectivity lost — re-checking before declaring disconnect');
      await checkAndPunchIfEnabled();
    }
  }

  // ── Main Entry ─────────────────────────────────────────────

  Future<void> checkAndPunchIfEnabled() async {
    AppLogger.v('WIFI_AUTO: checkAndPunchIfEnabled() - isEnabled: $isEnabled');
    if (!isEnabled) return;
    await _checkCurrentConnection();
  }

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
          // Drop queued WiFi punches too — the disconnect never really happened.
          try {
            await OfflineQueueService().deleteQueuedByMethod('WiFi');
          } catch (e) {
            AppLogger.e('WIFI_AUTO: clear queued WiFi punches error', e);
          }
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

    // ── Unknown-state guard ──────────────────────────────────────
    // On fresh app start, lastPunchStatus defaults to 'unknown'.
    // Don't punch until the server syncs the real state via
    // _onAttendanceStatusChanged → syncState().
    if (lastStatus == '' || lastStatus == 'unknown') {
      AppLogger.i('WIFI_AUTO: Unknown punch state ($lastStatus) — deferring to server sync');
      return;
    }

    // ── Cooldown guard ───────────────────────────────────────────
    // Prevent rapid IN → OUT when two WiFi scans return different
    // results within a short window (common on fresh app open).
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastPunchTimestamp > 0 && (now - _lastPunchTimestamp) < _cooldownMs) {
      AppLogger.i('WIFI_AUTO: Cooldown active (${now - _lastPunchTimestamp}ms) — skipping punch');
      return;
    }

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

    // ── Cross-isolate guard: skip if background already processed ──
    if (await isDisconnectAlreadyProcessed()) {
      AppLogger.i('WIFI_AUTO: Disconnect already processed by other isolate — skipping');
      await setLastPunchStatus('Out');
      await setCurrentOfficeName('');
      return;
    }

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

      AppLogger.i('WIFI_AUTO: WiFi lost → Punch OUT');

      // Mark processed BEFORE HTTP so background isolate skips its attempt.
      await markDisconnectProcessed();

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