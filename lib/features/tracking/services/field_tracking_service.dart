import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:intl/intl.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/utils/constants.dart';
import '../../punch/services/geofence_background_worker.dart';
import '../../punch/services/wifi_background_worker.dart';
import '../models/location_result.dart';
import 'filters/location_filter.dart';
import 'filters/confidence_scorer.dart';

// ── Running state ─────────────────────────────────────────────────────────────

/// `true` while the background tracking service is active.
/// Updated in [MainShell] by listening to [FieldTrackingService.runningStream].
final fieldTrackingRunningProvider = StateProvider<bool>((ref) => false);

// ── SharedPreferences keys written by GeofenceAutoPunchService ────────────────

/// Key where the geofence service stores the nearest office latitude.
const _kDbgGeofenceLat    = 'dbg_geofence_lat';
/// Key where the geofence service stores the nearest office longitude.
const _kDbgGeofenceLng    = 'dbg_geofence_lng';
/// Key where the geofence service stores the nearest office geofence radius (m).
const _kDbgGeofenceRadius = 'dbg_geofence_radius';
/// Key where the geofence service stores the nearest office name (optional).
const _kDbgGeofenceName   = 'dbg_geofence_name';

// ── SharedPreferences keys for background-isolate token mirror ────────────────

/// Mirrors [TokenStorage.bgAccessTokenKey] — keep in sync.
const _kBgAccessToken  = 'bg_access_token';
/// Mirrors [TokenStorage.bgRefreshTokenKey] — keep in sync.
const _kBgRefreshToken = 'bg_refresh_token';
/// Mirrors [TokenStorage.bgTokenTimestampKey] — keep in sync.
const _kBgTokenTimestamp = 'bg_token_ts';
/// Mirrors [TokenStorage.bgRefreshLockKey] — keep in sync.
const _kBgRefreshLock = 'bg_refresh_lock';
/// Written by main shell before starting/stopping field tracking.
/// The combined entrypoint reads this to decide whether to send pings.
const _kFieldTrackingEnabled = 'field_tracking_enabled';

/// Persisted punch-state keys (mirrors GeofenceBackgroundWorker).
const _kPersistPunchType  = 'gf_last_punch_type';
const _kPersistPunchTime  = 'gf_last_punch_time';
const _kPersistPunchOffice = 'gf_last_punch_office';

// ── Service facade ────────────────────────────────────────────────────────────

class FieldTrackingService {
  FieldTrackingService._();

  static final _svc = FlutterBackgroundService();

  /// Call once in main() before runApp to register the background entrypoint.
  static Future<void> init() async {
    await _svc.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: geofenceAndTrackingEntrypoint,
        isForegroundMode: true,
        autoStart: false,
        notificationChannelId: 'mattendance_field_tracking',
        initialNotificationTitle: 'Geofence Active',
        initialNotificationContent: 'Monitoring',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: geofenceAndTrackingEntrypoint,
        onBackground: _iosBackground,
      ),
    );
  }

  /// Start the background tracking service.
  static Future<void> start() async {
    try {
      await _svc.startService();
    } catch (e) {
      debugPrint('[FT] start failed: $e');
    }
  }

  /// Stop the background tracking service.
  static void stop() => _svc.invoke('stop');

  /// Signal background service to refresh its foreground notification
  /// after geofence or tracking toggle from main isolate.
  static void notifyGeofenceToggle() => _svc.invoke('gf_toggle');

  /// Stream of running-state updates emitted by the background isolate.
  static Stream<bool> get runningStream =>
      _svc.on('running').map((d) => d?['value'] as bool? ?? false);

  /// Returns true if the background service is currently running.
  static Future<bool> get isRunning => _svc.isRunning();

  /// Stream of debug events emitted by the background isolate.
  ///
  /// Each event is a [Map] with the following keys:
  /// - `ts`        — ISO-8601 timestamp (String)
  /// - `event`     — one of: `'raw'`, `'filtered'`, `'rejected'`,
  ///                 `'ping_sent'`, `'ping_skipped'`, `'state_change'`
  /// - `state`     — current [TrackingState] name (String)
  /// - `lat`       — latitude (double, nullable)
  /// - `lng`       — longitude (double, nullable)
  /// - `accuracy`  — GPS accuracy in metres (double, nullable)
  /// - `speed`     — speed in m/s (double, nullable)
  /// - `reason`    — human-readable detail (String)
  /// - `distFromLastPingM`  — metres since last ping (double, nullable)
  /// - `secSinceLastPing`   — seconds since last ping (int, nullable)
  /// - `geofenceDistM`      — metres to nearest geofence centre (double, nullable)
  /// - `geofenceRadiusM`    — geofence radius in metres (double, nullable)
  /// - `geofenceName`       — office name (String, nullable)
  static Stream<Map<String, dynamic>> get debugStream =>
      _svc.on('trackingDebug').map((d) => d ?? {});

  /// Stream of geofence auto-punch events emitted by the background isolate.
  ///
  /// Each event is a [Map] with the following keys:
  /// - `direction`  — `'In'` or `'Out'` (String)
  /// - `time`       — ISO-8601 timestamp (String)
  /// - `officeName` — the office matched for the punch (String)
  static Stream<Map<String, dynamic>> get punchStream =>
      _svc.on('gf_punch').map((d) => d ?? {});

  /// Stream of WiFi auto-punch events emitted by the background isolate.
  static Stream<Map<String, dynamic>> get wifiPunchStream =>
      _svc.on('wifi_punch').map((d) => d ?? {});

  /// Stream of WiFi debug/BSSID status emitted by the background isolate.
  static Stream<Map<String, dynamic>> get wifiDebugStream =>
      _svc.on('wifi_debug').map((d) => d ?? {});
}

// ── iOS keep-alive ────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
Future<bool> _iosBackground(ServiceInstance service) async => true;

// ── Background service entrypoint ─────────────────────────────────────────────
//
// Runs in a separate Dart isolate owned by Android's foreground service.
// OxygenOS/MIUI/One UI cannot suspend it while the notification is visible.
// GPS stream and ping timer both live here — they keep firing even when the
// app is minimised or the screen is off.

@pragma('vm:entry-point')
void geofenceAndTrackingEntrypoint(ServiceInstance service) async {
  debugPrint('[GF_BG_ENTRY] Entrypoint started — isAndroid=${service is AndroidServiceInstance}');

  // Guard: if no auth token, do nothing — user not logged in.
  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString('bg_access_token');
  if (token == null || token.isEmpty) {
    debugPrint('[GF_BG_ENTRY] No auth token — stopping service');
    if (service is AndroidServiceInstance) {
      service.stopSelf();
    }
    return;
  }

  final locationFilter = LocationFilter();
  TrackingState trackingState = TrackingState.MOVING;

  LocationResult? currentFilteredPosition;
  LocationResult? lastPingPosition;
  DateTime? lastPingTime;
  StreamSubscription<Position>? positionSub;
  StreamSubscription<ServiceStatus>? gpsStatusSub;
  Timer? timer;

  // ── Geofence auto-punch worker ─────────────────────────────────────────────
  final geoWorker = GeofenceBackgroundWorker(service);
  debugPrint('[GF_BG_ENTRY] GeoWorker created');

  // ── WiFi auto-punch background worker ──────────────────────────────────────
  final wifiWorker = WifiBackgroundWorker(service);
  debugPrint('[GF_BG_ENTRY] WifiWorker created');

  // ── Foreground notification (required by Android for foreground service) ──
  if (service is AndroidServiceInstance) {
    final gfEnabled = prefs.getBool('geofence_auto_enabled') ?? false;
    final ftEnabled = prefs.getBool('field_tracking_enabled') ?? false;
    final wifiOnly = prefs.getBool('wifi_auto_punch_enabled_bg') ?? false;

    String title;
    String content;
    if (gfEnabled && ftEnabled) {
      title = 'Geofence + Tracking';
      content = 'Active';
    } else if (gfEnabled) {
      title = 'Geofence Active';
      content = 'Monitoring';
    } else if (wifiOnly) {
      title = 'WiFi Auto-Punch';
      content = 'Monitoring WiFi…';
    } else {
      title = 'Mattendance';
      content = 'Running';
    }
    service.setForegroundNotificationInfo(title: title, content: content);
  }

  // ── Device/app info (fetched once, reused on every ping) ──────────────────

  String appVersion = AppConstants.appVersion;
  String deviceId = 'unknown';
  try {
    final pkg = await PackageInfo.fromPlatform();
    appVersion = pkg.version;
    if (Platform.isAndroid) {
      deviceId = (await DeviceInfoPlugin().androidInfo).id;
    } else if (Platform.isIOS) {
      deviceId = (await DeviceInfoPlugin().iosInfo).identifierForVendor ?? 'unknown';
    }
  } catch (_) {}

  // ── Debug helper ──────────────────────────────────────────────────────────

  /// Reads geofence context written by [GeofenceAutoPunchService] and emits a
  /// `trackingDebug` event back to the main isolate (→ [FieldTrackingService.debugStream]).
  Future<void> emitDebug({
    required String event,
    LocationResult? loc,
    String reason = '',
    double? distFromLastPingM,
    int? secSinceLastPing,
  }) async {
    // Only emit debug events when devMode prefs key is not explicitly disabled.
    // The real gate is [DevFlags.kDevMode] on the UI side — we always emit here
    // so the stream is populated, and the UI decides whether to display it.
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final geofenceLat    = prefs.getDouble(_kDbgGeofenceLat);
      final geofenceLng    = prefs.getDouble(_kDbgGeofenceLng);
      final geofenceRadius = prefs.getDouble(_kDbgGeofenceRadius);
      final geofenceName   = prefs.getString(_kDbgGeofenceName);

      double? geofenceDistM;
      if (loc != null && geofenceLat != null && geofenceLng != null) {
        geofenceDistM = Geolocator.distanceBetween(
          loc.latitude, loc.longitude,
          geofenceLat, geofenceLng,
        );
      }

      service.invoke('trackingDebug', {
        'ts':                 DateTime.now().toIso8601String(),
        'event':              event,
        'state':              trackingState.name,
        'lat':                loc?.latitude,
        'lng':                loc?.longitude,
        'accuracy':           loc?.accuracy,
        'speed':              loc?.speed,
        'reason':             reason,
        'distFromLastPingM':  distFromLastPingM,
        'secSinceLastPing':   secSinceLastPing,
        'geofenceDistM':      geofenceDistM,
        'geofenceRadiusM':    geofenceRadius,
        'geofenceName':       geofenceName,
      });
    } catch (_) {}
  }

  // ── HTTP ping ──────────────────────────────────────────────────────────────

  /// Attempts to POST a location ping to the server.
  ///
  /// On a 401 response the isolate tries to refresh the token pair stored in
  /// SharedPreferences (the same mirror that [TokenStorage.saveTokens] writes).
  /// If refresh succeeds the ping is retried once with the new access token.
  /// If refresh fails the mirrored tokens are wiped so subsequent pings are
  /// skipped rather than spamming the server with invalid credentials.
  Future<void> sendPing(LocationResult position, {String reason = ''}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString(_kBgAccessToken);
      if (token == null) {
        await emitDebug(
          event: 'ping_skipped',
          loc: position,
          reason: 'No access token in SharedPreferences — user not logged in',
        );
        return;
      }

      Dio _buildDio(String accessToken) => Dio(BaseOptions(
            baseUrl: AppConstants.apiBaseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
            headers: {
              'Authorization': 'Bearer $accessToken',
              'X-Client-Type': 'mobile',
              'X-Platform': Platform.isAndroid ? 'android' : 'ios',
              'X-App-Version': appVersion,
              'X-Device-Id': deviceId,
            },
          ));

      final pingData = {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
        'speed': position.speed > 0 ? position.speed : null,
        'capturedAt': position.timestamp.toUtc().toIso8601String(),
      };

      try {
        await _buildDio(token).post(ApiEndpoints.trackingPing, data: pingData);
      } on DioException catch (e) {
        if (e.response?.statusCode != 401) rethrow;

        // ── 401: attempt token refresh ────────────────────────────────────
        debugPrint('[FieldTracking] 401 received — attempting token refresh');

        // Check cross-isolate lock
        await prefs.reload();
        final lockTs = prefs.getInt(_kBgRefreshLock) ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;

        if (lockTs > 0 && (now - lockTs) < 30000) {
          debugPrint('[FieldTracking] Another isolate is already refreshing tokens. Skipping this ping.');
          return;
        }

        // Acquire lock
        await prefs.setInt(_kBgRefreshLock, now);

        try {
          final refreshToken = prefs.getString(_kBgRefreshToken);
          if (refreshToken == null) {
            debugPrint('[FieldTracking] No refresh token — cannot refresh');
            // We DON'T wipe tokens here to avoid accidental logout. 
            // The main isolate will handle it when the app is opened.
            await prefs.remove(_kBgRefreshLock);
            return;
          }

          final refreshDio = Dio(BaseOptions(
            baseUrl: AppConstants.apiBaseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 30),
          ));
          final refreshResp = await refreshDio.post(
            '/api/v1/auth/refresh',
            data: {
              'accessToken': token,
              'refreshToken': refreshToken,
            },
          );

          final newAccess  = refreshResp.data['accessToken']  as String;
          final newRefresh = refreshResp.data['refreshToken'] as String;

          // Persist refreshed tokens with timestamp
          await Future.wait([
            prefs.setString(_kBgAccessToken, newAccess),
            prefs.setString(_kBgRefreshToken, newRefresh),
            prefs.setInt(_kBgTokenTimestamp, DateTime.now().millisecondsSinceEpoch),
            prefs.remove(_kBgRefreshLock),
          ]);

          debugPrint('[FieldTracking] Token refreshed — retrying ping');
          await _buildDio(newAccess).post(ApiEndpoints.trackingPing, data: pingData);
        } catch (refreshErr) {
          await prefs.remove(_kBgRefreshLock);
          
          final isNetworkError = refreshErr is DioException &&
              (refreshErr.type == DioExceptionType.connectionTimeout ||
                  refreshErr.type == DioExceptionType.sendTimeout ||
                  refreshErr.type == DioExceptionType.receiveTimeout ||
                  refreshErr.type == DioExceptionType.connectionError ||
                  refreshErr.response == null);

          final isServerError = refreshErr is DioException &&
              refreshErr.response != null &&
              refreshErr.response!.statusCode != null &&
              refreshErr.response!.statusCode! >= 500;

          if (isNetworkError || isServerError) {
            debugPrint('[FieldTracking] Token refresh failed due to network/server error. Retaining tokens.');
            await emitDebug(
              event: 'ping_error',
              loc: position,
              reason: 'Token refresh failed temporarily (network/server error). Will retry next time.',
            );
            return;
          }

          // Refresh itself failed (fatal).
          debugPrint('[FieldTracking] Token refresh FAILED (fatal): $refreshErr');
          // Do NOT wipe SharedPreferences tokens — doing so would cause the
          // main isolate's TokenStorage._syncFromBackgroundMirror (or the
          // SecureStorage read fallback) to see null tokens and trigger an
          // accidental forceLogout. Let the main isolate's DioClient interceptor
          // handle session expiry when the app is opened.
          await emitDebug(
            event: 'ping_error',
            loc: position,
            reason: 'Token refresh failed — session may be expired. Please re-open the app.',
          );
          return;
        }
      }

      final distFromLast = lastPingPosition != null
          ? Geolocator.distanceBetween(
              position.latitude, position.longitude,
              lastPingPosition!.latitude, lastPingPosition!.longitude,
            )
          : null;

      lastPingPosition = position;
      lastPingTime = DateTime.now();

      debugPrint('[FieldTracking] Filtered ping sent — reason: $reason');
      await emitDebug(
        event: 'ping_sent',
        loc: position,
        reason: reason,
        distFromLastPingM: distFromLast,
        secSinceLastPing: 0,
      );
    } catch (e) {
      await emitDebug(
        event: 'ping_error',
        loc: position,
        reason: 'HTTP error: $e',
      );
    }
  }

  // ── Notification helper ──────────────────────────────────────────────────────

  /// Read the persisted punch state and update the foreground notification.
  Future<void> updateNotification({LocationResult? loc}) async {
    if (service is AndroidServiceInstance) {
      final prefs = await SharedPreferences.getInstance();
      final punchType = prefs.getString(_kPersistPunchType);
      final punchTimeStr = prefs.getString(_kPersistPunchTime);
      final punchOffice = prefs.getString(_kPersistPunchOffice);
      final ftEnabled = prefs.getBool(_kFieldTrackingEnabled) ?? false;
      final gfEnabled = prefs.getBool('geofence_auto_enabled') ?? false;

      String title;
      String content;
      if (!gfEnabled && !ftEnabled) {
        final wifiEnabled = prefs.getBool('wifi_auto_punch_enabled_bg') ?? false;
        if (wifiEnabled) {
          title = 'WiFi Auto-Punch';
          final wifiMatch = prefs.getString('wifi_bg_matched_name') ?? '';
          if (punchType == 'In') {
            final ts = punchTimeStr != null ? DateTime.tryParse(punchTimeStr) : null;
            final since = ts != null ? DateFormat('h:mm a').format(ts.toLocal()) : '';
            content = 'IN · $punchOffice$since';
          } else if (wifiMatch.isNotEmpty) {
            content = 'OUT · $wifiMatch in range';
          } else {
            content = 'OUT · waiting for WiFi';
          }
        } else {
          title = 'Mattendance';
          content = '';
        }
      } else if (punchType == 'In' && gfEnabled) {
        title = 'Punched In ✓';
        final ts = punchTimeStr != null ? DateTime.tryParse(punchTimeStr) : null;
        final since = ts != null ? DateFormat('h:mm a').format(ts.toLocal()) : '';
        final acc = loc != null ? ' · ±${loc.accuracy.toStringAsFixed(0)}m' : '';
        content = '$punchOffice · since $since$acc';
      } else if (punchType == 'Out' && gfEnabled) {
        title = 'Punched Out';
        content = loc != null ? '±${loc.accuracy.toStringAsFixed(0)}m' : '';
      } else {
        title = ftEnabled ? 'Tracking Active' : 'Mattendance';
        content = loc != null ? 'Monitoring · ±${loc.accuracy.toStringAsFixed(0)}m' : '';
      }

      service.setForegroundNotificationInfo(title: title, content: content);
    }
  }

  // ── GPS stream ─────────────────────────────────────────────────────────────

  final locationSettings = Platform.isAndroid
      ? AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
        )
      : AppleSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          allowBackgroundLocationUpdates: true,
        );

  debugPrint('[GF_BG_ENTRY] Setting up GPS stream...');
  positionSub = Geolocator.getPositionStream(locationSettings: locationSettings)
      .listen(
    (pos) async {
      debugPrint('[GF_BG_ENTRY] RAW GPS fix: lat=${pos.latitude.toStringAsFixed(5)}, lng=${pos.longitude.toStringAsFixed(5)}, acc=${pos.accuracy.toStringAsFixed(1)}m');
      final raw = LocationResult(
        latitude: pos.latitude,
        longitude: pos.longitude,
        accuracy: pos.accuracy,
        speed: pos.speed,
        altitude: pos.altitude,
        heading: pos.heading,
        timestamp: pos.timestamp,
      );

      // ── Accuracy gate ────────────────────────────────────────────────────
      if (raw.accuracy > LocationFilter.MIN_ACCURACY) {
        await emitDebug(
          event: 'rejected',
          loc: raw,
          reason: 'Accuracy ${raw.accuracy.toStringAsFixed(1)}m > ${LocationFilter.MIN_ACCURACY}m gate',
        );
        return;
      }

      final filtered = locationFilter.process(raw, trackingState);

      if (filtered == null) {
        // Accuracy gate failed
        await emitDebug(
          event: 'rejected',
          loc: raw,
          reason: 'Accuracy ${raw.accuracy.toStringAsFixed(1)}m > ${LocationFilter.MIN_ACCURACY}m gate',
        );
        return;
      }

      // Log soft jumps for debugging
      if (filtered.jumpScore > 0.5) {
        await emitDebug(
          event: 'jump_soft',
          loc: filtered,
          reason: 'Soft Jump detected (score=${filtered.jumpScore.toStringAsFixed(2)}). Point kept but smoothed.',
        );
      }

      final prevState = trackingState;
      currentFilteredPosition = filtered;
      trackingState = locationFilter.evaluateState(filtered, trackingState);

      final secSincePing = lastPingTime != null
          ? DateTime.now().difference(lastPingTime!).inSeconds
          : null;

      // Emit state-change event when TrackingState transitions
      if (trackingState != prevState) {
        await emitDebug(
          event: 'state_change',
          loc: filtered,
          reason: '${prevState.name} → ${trackingState.name}',
          secSinceLastPing: secSincePing,
        );
      } else {
        await emitDebug(
          event: 'filtered',
          loc: filtered,
          reason: 'Kalman smoothed  acc=${filtered.accuracy.toStringAsFixed(1)}m',
          secSinceLastPing: secSincePing,
        );
      }

      // ── Geofence auto-punch check ──────────────────────────────────────────
      final gfConfidence = ConfidenceScorer.score(filtered, trackingState, jumpScore: filtered.jumpScore);
      geoWorker.onLocationFix(filtered, trackingState, gfConfidence);

      await updateNotification(loc: filtered);
    },
    onError: (_) {},
  );

  // ── GPS service status monitor ─────────────────────────────────────────────
  // When user turns off GPS while geofence auto-punch is enabled, alert them
  // that geofence will stop working.
  late final FlutterLocalNotificationsPlugin gpsNotif =
      FlutterLocalNotificationsPlugin();
  gpsStatusSub = Geolocator.getServiceStatusStream().listen((status) async {
    final prefs = await SharedPreferences.getInstance();
    final gfEnabled = prefs.getBool('geofence_auto_enabled') ?? false;
    if (status == ServiceStatus.disabled && gfEnabled) {
      debugPrint('[GF_BG_ENTRY] GPS turned off while geofence active — sending alert');
      try {
        await gpsNotif.show(
          996,
          'GPS Turned Off',
          'Geofence auto-punch paused — turn on GPS to resume monitoring',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'gps_disabled',
              'GPS Disabled',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      } catch (e) {
        debugPrint('[GF_BG_ENTRY] GPS disabled notification failed: $e');
      }
    } else if (status == ServiceStatus.enabled && gfEnabled) {
      debugPrint('[GF_BG_ENTRY] GPS re-enabled — dismissing alert');
      await gpsNotif.cancel(996);
    }
  });

  // ── Ping timer ─────────────────────────────────────────────────────────────

  timer = Timer.periodic(const Duration(minutes: 5), (_) async {
    service.invoke('running', {'value': true});

    final prefs = await SharedPreferences.getInstance();
    final ftEnabled = prefs.getBool(_kFieldTrackingEnabled) ?? false;
    if (!ftEnabled) return;

    // Only ping during active shift — user must be punched in
    final punchType = prefs.getString(_kPersistPunchType);
    if (punchType != 'In') {
      await emitDebug(event: 'ping_skipped', reason: 'Not punched in — tracking paused');
      return;
    }

    final current = currentFilteredPosition;
    if (current == null) {
      await emitDebug(event: 'ping_skipped', reason: 'No filtered position yet');
      return;
    }

    final secSincePing = lastPingTime != null
        ? DateTime.now().difference(lastPingTime!).inSeconds
        : null;

    // Movement ping: moved > 100 m since last ping.
    final lastPos = lastPingPosition;
    if (lastPos != null) {
      final dist = Geolocator.distanceBetween(
        current.latitude, current.longitude,
        lastPos.latitude, lastPos.longitude,
      );
      if (dist > 100) {
        await sendPing(current, reason: 'Moved ${dist.toStringAsFixed(0)}m since last ping');
        return;
      }
      // Not enough movement — check heartbeat
      if (lastPingTime != null &&
          DateTime.now().difference(lastPingTime!).inMinutes < 30) {
        await emitDebug(
          event: 'ping_skipped',
          loc: current,
          reason: 'Moved only ${dist.toStringAsFixed(0)}m, heartbeat not due yet',
          distFromLastPingM: dist,
          secSinceLastPing: secSincePing,
        );
        return;
      }
    }

    // Heartbeat ping: no ping in the last 30 minutes.
    if (lastPingTime == null ||
        DateTime.now().difference(lastPingTime!).inMinutes >= 30) {
      await sendPing(current, reason: 'Heartbeat (30-min interval)');
    }
  });

  service.invoke('running', {'value': true});
  final startPrefs = await SharedPreferences.getInstance();
  await startPrefs.setBool('was_field_tracking', true);

  await emitDebug(event: 'service_start', reason: 'Background service started');

  // ── Geofence worker data load ────────────────────────────────────────────────
  debugPrint('[GF_BG_ENTRY] Calling geoWorker.loadData()...');
  await geoWorker.loadData();
  debugPrint('[GF_BG_ENTRY] geoWorker.loadData() complete');

  // ── Start WiFi background worker ─────────────────────────────────────────
  wifiWorker.start();
  debugPrint('[GF_BG_ENTRY] WiFi background worker started');

  // ── Proactive initial location check ──────────────────────────────────────
  // On first start (fresh install, new login, app restart), the GPS stream may
  // take 10-60s for a cold fix.  If the user is already inside an office zone,
  // we want to punch IN immediately rather than waiting for the first stream
  // fix.  A single `getCurrentPosition` call resolves faster than the stream.
  try {
    debugPrint('[GF_BG_ENTRY] Proactive location check...');
    final initPos = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );
    {
      final initRaw = LocationResult(
        latitude: initPos.latitude,
        longitude: initPos.longitude,
        accuracy: initPos.accuracy,
        speed: initPos.speed,
        altitude: initPos.altitude,
        heading: initPos.heading,
        timestamp: initPos.timestamp,
      );
      if (initRaw.accuracy <= LocationFilter.MIN_ACCURACY) {
        final initFiltered = locationFilter.process(initRaw, trackingState);
        if (initFiltered != null) {
          trackingState = locationFilter.evaluateState(initFiltered, trackingState);
          final initConfidence = ConfidenceScorer.score(
            initFiltered, trackingState,
            jumpScore: initFiltered.jumpScore,
          );
          debugPrint('[GF_BG_ENTRY] Initial fix — lat=${initFiltered.latitude.toStringAsFixed(5)} acc=${initFiltered.accuracy.toStringAsFixed(1)}m conf=${initConfidence.toStringAsFixed(2)}');
          geoWorker.onLocationFix(initFiltered, trackingState, initConfidence);
        }
      }
    }
  } catch (e) {
    debugPrint('[GF_BG_ENTRY] Proactive location check failed: $e');
  }

  await updateNotification();
  debugPrint('[GF_BG_ENTRY] Initial setup complete — monitoring active');

  // ── Geofence toggle command (refresh notification when toggled) ──────

  service.on('gf_toggle').listen((_) async {
    debugPrint('[GF_BG_ENTRY] Geofence toggle signal received — updating notification');
    await updateNotification();
  });

  // ── WiFi debug event → refresh notification ───────────────────────

  service.on('wifi_debug').listen((_) async {
    await updateNotification();
  });

  // ── Stop command ───────────────────────────────────────────────────────

  service.on('stop').listen((_) async {
    await emitDebug(event: 'service_stop', reason: 'Stop command received');
    timer?.cancel();
    await positionSub?.cancel();
    await gpsStatusSub?.cancel();
    wifiWorker.stop();
    service.invoke('running', {'value': false});
    final stopPrefs = await SharedPreferences.getInstance();
    await stopPrefs.setBool('was_field_tracking', false);
    service.stopSelf();
  });
}
