import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/utils/geo_bands.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:intl/intl.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/location_precision.dart';
import '../../../core/utils/mock_location.dart';
import '../../../models/offline_punch.dart';
import '../../punch/services/geofence_monitor.dart';
import '../../punch/services/geofence_scheduler.dart';
import '../../punch/services/oem_keep_alive_service.dart';
import '../../punch/services/wifi_background_worker.dart';
import '../models/location_result.dart';
import 'filters/location_filter.dart';

// ── Running state ─────────────────────────────────────────────────────────────

/// `true` while the background tracking service is active.
/// Updated in [MainShell] by listening to [FieldTrackingService.runningStream].
final fieldTrackingRunningProvider = StateProvider<bool>((ref) => false);

// ── SharedPreferences keys written by GeofenceMonitor ─────────────────────────

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

/// Persisted punch-state keys (mirrors GeofencePunchHandler).
const _kPersistPunchType  = 'gf_last_punch_type';
const _kPersistPunchTime  = 'gf_last_punch_time';
const _kPersistPunchOffice = 'gf_last_punch_office';

// ── Keep-alive punch monitor ────────────────────────────────────────────────

/// Movement gate for the keep-alive GPS stream (metres).
///
/// High-accuracy fixes are only delivered when the phone moves >= this
/// distance from the last fix.  A user sitting at the office desk receives
/// no fixes at all (negligible battery); walking out of the office produces
/// a fix every ~30m — dense enough to catch the boundary crossing without
/// continuous GPS polling.
const keepAliveDistanceFilterM = 30;

/// Office (non client-site) zones persisted by [GeofenceMonitor] under
/// `gf_zone_ids` / `gf_zone_$id`.
List<GeofenceZone> keepAliveOfficeZones(SharedPreferences prefs) {
  final ids = prefs.getStringList('gf_zone_ids') ?? const [];
  final zones = <GeofenceZone>[];
  for (final id in ids) {
    final raw = prefs.getString('gf_zone_$id');
    if (raw == null) continue;
    try {
      final zone =
          GeofenceZone.fromJson(id, jsonDecode(raw) as Map<String, dynamic>);
      if (zone != null && !zone.isClientSite) zones.add(zone);
    } catch (_) {/* corrupt metadata — skip */}
  }
  return zones;
}

/// True when [fix] is outside EVERY office radius by the OUT band
/// (radius + fixed 25m — mirrors GeofencePunchHandler's OUT slack, user
/// spec "out of radius + 25-30m → punch OUT") **with the accuracy trust
/// floor** ([isOutsideOfficeBand]).
///
/// Strengthened 2026-08-17: a fix also counts as "still inside" when its
/// claimed accuracy exceeds the band — fused wifi-blend fixes can claim
/// 100-500m and jump 300-500m, and two such fixes previously fabricated
/// a false OUT at 68m beyond the radius while the user was inside.
/// Accuracy still NEVER widens the band (the 2x-accuracy margin delayed
/// the Nothing's 149m OUT); untrusted fixes simply defer the punch to
/// the next check (OS EXIT crossing path / 15-min net).
///
/// Pure function — unit-testable.
bool isOutsideAllOffices(Position fix, List<GeofenceZone> zones) {
  if (zones.isEmpty) return false;
  for (final z in zones) {
    if (!isOutsideOfficeBand(
      fix,
      zoneLatitude: z.latitude,
      zoneLongitude: z.longitude,
      zoneRadius: z.radius,
    )) {
      return false; // still inside (or untrusted) this office
    }
  }
  return true;
}

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
    // Keep-alive holds the process — stop it first (mode flag cleared),
    // or the combined service would start with the keep-alive mode flag
    // still set (and run light instead of full).
    await OemKeepAliveService.stop();
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

  // Initialize Hive in this isolate so background workers can write to the
  // offline punch queue (auto punches that fail due to no internet get
  // queued and synced later by OfflineSyncManager).
  try {
    await Hive.initFlutter();
    Hive.registerAdapter(OfflinePunchAdapter());
    await Hive.openBox<OfflinePunch>(AppConstants.offlinePunchBox);
    await Hive.openBox(AppConstants.cacheBox);
  } catch (e) {
    debugPrint('[GF_BG_ENTRY] Hive init failed: $e');
  }

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

  // Guard: never run an EMPTY service.  The service exists only to serve
  // auto features — geofence auto-punch, WiFi auto-punch, field tracking.
  // If none is enabled there is nothing to monitor; starting anyway would
  // just show a pointless "Mattendance" foreground notification forever.
  final gfEnabled = prefs.getBool('geofence_auto_enabled') ?? false;
  final wifiBg = prefs.getBool('wifi_auto_punch_enabled_bg') ?? false;
  final wifiFg = prefs.getBool('wifi_auto_punch_enabled') ?? false;
  final ftEnabled = prefs.getBool('field_tracking_enabled') ?? false;
  if (!gfEnabled && !wifiBg && !wifiFg && !ftEnabled) {
    debugPrint('[GF_BG_ENTRY] No auto feature enabled — stopping empty service');
    if (service is AndroidServiceInstance) {
      service.stopSelf();
    }
    return;
  }

  // ── Keep-alive mode (all Android devices, uniform) ──────────────────
  // The service exists here ONLY to keep the process alive so OS geofence
  // transitions, the containment alarm and WorkManager run in a live
  // process (Android kills dormant processes on any ROM — the FGS
  // holding the process removes exemptions everywhere).
  // Heal geofences, re-check containment once, then run a movement-gated
  // GPS stream while punched in (catches the EXIT aggressive OEMs drop).
  if (prefs.getBool(OemKeepAliveService.keepAliveModeKey) ?? false) {
    debugPrint('[GF_BG_ENTRY] Keep-alive mode — holding process');
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: 'Geofence Active',
        content: 'Monitoring',
      );
    }
    // Heal OS geofences (a fresh process may find them dropped) and run one
    // containment check immediately (missed exit/enter).  Everything else
    // comes from the native alarm / plugin receiver / WorkManager.
    try {
      await GeofenceMonitor.registerZones();
      await GeofencePunchHandler.instance.reconcileContainment(confirmOut: true);
    } catch (e) {
      debugPrint('[GF_BG_ENTRY] Keep-alive init check failed: $e');
    }
    // ── Shift-end self-kill (wires the dead isPastShiftEnd check) ─────────
    // Once the shift is over AND the user is outside every office, there is
    // nothing left to monitor — stop the FGS and its "Geofence Active"
    // notification.  Inlined (not via GeofenceScheduler) to avoid an import
    // cycle.  The 15-min headless alarm still re-heals IN if needed.
    try {
      final endRaw = prefs.getString('gf_shift_end_time');
      if (endRaw != null) {
        final end = DateTime.tryParse(endRaw);
        if (end != null && DateTime.now().isAfter(end)) {
          final zones = keepAliveOfficeZones(prefs);
          if (zones.isNotEmpty) {
            final fix = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.low,
                timeLimit: Duration(seconds: 5),
              ),
            );
            if (isOutsideAllOffices(fix, zones)) {
              debugPrint('[GF_BG_ENTRY] Shift over + outside — stopping FGS');
              if (service is AndroidServiceInstance) service.stopSelf();
              return;
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[GF_BG_ENTRY] shift-end self-kill check failed: $e');
    }
    // ── Movement-gated punch monitor ────────────────────────────────────
    // Only while punched in.  distanceFilter 30m → a stationary user at
    // the desk gets ZERO fixes (no GPS radio churn); fixes arrive only as
    // the user actually moves, so the inside→outside transition is the
    // honest walk out of the office, not a late OS event.  On the first
    // outside fix a containment reconcile runs immediately (confirming fix
    // taken back-to-back, punch OUT records the REAL confirm location).
    StreamSubscription<Position>? keepAliveSub;
    var keepAliveWasOutside = false;
    DateTime? keepAliveLastReconcile;
    try {
      final zones = keepAliveOfficeZones(prefs);
      if (prefs.getString(_kPersistPunchType) == 'In' && zones.isNotEmpty) {
        final settings = Platform.isAndroid
            ? AndroidSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: keepAliveDistanceFilterM,
              )
            : AppleSettings(
                accuracy: LocationAccuracy.high,
                distanceFilter: keepAliveDistanceFilterM,
                pauseLocationUpdatesAutomatically: false,
                allowBackgroundLocationUpdates: true,
              );
        keepAliveSub = Geolocator.getPositionStream(locationSettings: settings)
            .listen((fix) async {
          // Mock location detection — warn user and skip this fix
          if (MockLocationDetector.isMocked(fix)) {
            debugPrint('[GF_BG_ENTRY] keep-alive: Mock location detected — warning user');
            await MockLocationDetector.showMockLocationWarning();
            return;
          }
          final p = await SharedPreferences.getInstance();
          // Punched OUT → nothing to monitor; OS EXIT / containment alarm /
          // next ENTER take over.  Stop the GPS churn.
          if (p.getString(_kPersistPunchType) != 'In') {
            await keepAliveSub?.cancel();
            keepAliveSub = null;
            return;
          }
          final outside = isOutsideAllOffices(fix, zones);
          final now = DateTime.now();
          final cooledDown = keepAliveLastReconcile == null ||
              now.difference(keepAliveLastReconcile!) >
                  const Duration(seconds: 60);
          if (outside && !keepAliveWasOutside && cooledDown) {
            keepAliveWasOutside = true;
            keepAliveLastReconcile = now;
            debugPrint('[GF_BG_ENTRY] keep-alive stream: outside all offices'
                ' — reconciling OUT');
            try {
              await GeofencePunchHandler.instance
                  .reconcileContainment(confirmOut: true);
            } catch (e) {
              debugPrint('[GF_BG_ENTRY] keep-alive reconcile failed: $e');
            }
            // Shift over + outside: nothing left to monitor — stop the FGS
            // and its notification now (don't wait for the OUT to land).
            try {
              final endRaw = p.getString('gf_shift_end_time');
              if (endRaw != null) {
                final end = DateTime.tryParse(endRaw);
                if (end != null && DateTime.now().isAfter(end)) {
                  debugPrint('[GF_BG_ENTRY] Shift over + outside — stopping FGS');
                  if (service is AndroidServiceInstance) service.stopSelf();
                }
              }
            } catch (_) {}
          } else if (!outside) {
            keepAliveWasOutside = false;
          }
        }, onError: (_) {});
      }
    } catch (e) {
      debugPrint('[GF_BG_ENTRY] keep-alive stream setup failed: $e');
    }
    // ── Alignment warning streams (event-driven — zero timers) ─────────
    // Phase-5 warnings (GPS off 996 / airplane mode 998 / wifi-hidden 997)
    // previously existed only in the combined service, the foreground
    // monitor and the ~30-min headless WorkManager.  The keep-alive FGS
    // (geofence-only users) was deaf to them: GPS off or airplane mode
    // produced TOTAL silence until the next WorkManager fire — up to 30
    // minutes, and system-scheduled periodics are deferrable on aggressive
    // OEMs.  These listeners are pure event streams: they wake only on an
    // actual state change, never poll, never request a GPS fix — the
    // battery contract stays intact (stationary = zero radio churn).
    //
    // Notification IDs / channel / prefs keys SHARED with the foreground
    // monitor + headless worker + wifi worker (single source of truth —
    // all sides REPLACE, never duplicate, each other's popups).
    final alignNotif = FlutterLocalNotificationsPlugin();
    const alignChannel = AndroidNotificationDetails(
      'user_alignment',
      'Attendance Alerts',
      importance: Importance.high,
      priority: Priority.high,
    );
    const alignDetails = NotificationDetails(android: alignChannel);
    StreamSubscription<ServiceStatus>? alignGpsSub;
    StreamSubscription<List<ConnectivityResult>>? alignConnSub;
    try {
      // GPS off → 996 (geofences can't fire).  Same gate as the headless
      // worker: punched IN + any auto feature.
      alignGpsSub = Geolocator.getServiceStatusStream().listen((status) async {
        final p = await SharedPreferences.getInstance();
        final anyAuto = (p.getBool('geofence_auto_enabled') ?? false) ||
            (p.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
            (p.getBool('wifi_auto_punch_enabled') ?? false) ||
            (p.getBool('field_tracking_enabled') ?? false);
        if (p.getString(_kPersistPunchType) != 'In' || !anyAuto) {
          try {
            await alignNotif.cancel(996);
          } catch (_) {}
          return;
        }
        try {
          if (status == ServiceStatus.disabled) {
            await alignNotif.show(
              996,
              'GPS is off',
              'Auto punch won\u2019t work and you could be marked absent even '
                  'at the office. Turn Location back on.',
              alignDetails,
            );
          } else {
            await alignNotif.cancel(996);
          }
        } catch (e) {
          debugPrint('[KEEP_ALIVE] GPS alert failed: $e');
        }
      });
      // Airplane mode / no network → 998 (warn once per offline stretch),
      // wifi-hidden → 997 on wifi (re)connect events, rate-limited 10 min.
      alignConnSub =
          Connectivity().onConnectivityChanged.listen((results) async {
        final p = await SharedPreferences.getInstance();
        final anyAuto = (p.getBool('geofence_auto_enabled') ?? false) ||
            (p.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
            (p.getBool('wifi_auto_punch_enabled') ?? false) ||
            (p.getBool('field_tracking_enabled') ?? false);
        if (p.getString(_kPersistPunchType) != 'In' || !anyAuto) {
          try {
            await alignNotif.cancel(998);
            await alignNotif.cancel(997);
          } catch (_) {}
          return;
        }
        try {
          final none =
              results.isEmpty || results.every((r) => r == ConnectivityResult.none);
          if (none) {
            if (p.getBool('wifi_bg_no_connectivity_warned') ?? false) return;
            await p.setBool('wifi_bg_no_connectivity_warned', true);
            await alignNotif.show(
              998,
              'No network (airplane mode?)',
              'Attendance can\u2019t send or receive right now. WiFi punches '
                  'will be saved and sent when you\u2019re back online. Swipe '
                  'down from the top of your screen and turn off airplane mode.',
              alignDetails,
            );
          } else {
            if (p.getBool('wifi_bg_no_connectivity_warned') ?? false) {
              await p.setBool('wifi_bg_no_connectivity_warned', false);
            }
            await alignNotif.cancel(998);
            if (results.contains(ConnectivityResult.wifi)) {
              // Wifi (re)connect — check Android isn't hiding the BSSID
              // (location off) so wifi auto punch can still confirm.
              String? bssid;
              try {
                bssid = await NetworkInfo().getWifiBSSID();
              } catch (_) {
                bssid = null;
              }
              final hidden = bssid == null ||
                  bssid.isEmpty ||
                  bssid == '02:00:00:00:00:00';
              if (!hidden) {
                await alignNotif.cancel(997);
                return;
              }
              final now = DateTime.now().millisecondsSinceEpoch;
              final last = p.getInt('wifi_bg_bssid_warned_ts') ?? 0;
              if (now - last < const Duration(minutes: 10).inMilliseconds) {
                return;
              }
              await p.setInt('wifi_bg_bssid_warned_ts', now);
              await alignNotif.show(
                997,
                'Connected to WiFi, but the app can\u2019t read it',
                'This happens when Location is off. Turn it on so auto punch '
                    'can confirm you\u2019re on the office network. Phone '
                    'Settings \u2192 Location.',
                alignDetails,
              );
            } else {
              await alignNotif.cancel(997);
            }
          }
        } catch (e) {
          debugPrint('[KEEP_ALIVE] connectivity alert failed: $e');
        }
      });
    } catch (e) {
      debugPrint('[KEEP_ALIVE] alignment stream setup failed: $e');
    }
    // Idle: no timers — just the stream above + stop signals.
    service.on('stopKeepAlive').listen((_) async {
      debugPrint('[GF_BG_ENTRY] Keep-alive stop requested');
      await keepAliveSub?.cancel();
      await alignGpsSub?.cancel();
      await alignConnSub?.cancel();
      await MockLocationDetector.cancelMockLocationWarning();
      if (service is AndroidServiceInstance) service.stopSelf();
    });
    service.on('stop').listen((_) async {
      await keepAliveSub?.cancel();
      await alignGpsSub?.cancel();
      await alignConnSub?.cancel();
      await MockLocationDetector.cancelMockLocationWarning();
      if (service is AndroidServiceInstance) service.stopSelf();
    });
    return;
  }

  // ── Geofence-only gate (defense in depth) ─────────────────────────────
  // The combined service exists ONLY for wifi auto-punch and field
  // tracking.  A geofence-only config is served headlessly by the OS
  // geofence + WorkManager + containment alarm — no live isolate needed.
  // A stray cold start (e.g. native shift-start alarm racing the prefs
  // flags) must self-heal and stop, never run the full GPS stream all day.
  if (!await GeofenceScheduler.serviceRequired()) {
    debugPrint('[GF_BG_ENTRY] Geofence-only config — self-heal then stop, '
        'no combined service');
    try {
      await GeofenceMonitor.registerZones();
      await GeofencePunchHandler.instance.reconcileContainment(confirmOut: true);
    } catch (e) {
      debugPrint('[GF_BG_ENTRY] Pre-stop self-heal failed: $e');
    }
    if (service is AndroidServiceInstance) service.stopSelf();
    return;
  }

  // Mandatory PRECISE location. Approximate (coarse) fixes are 500m–2km off —
  // silently breaking geofence auto-punch and field tracking. If the user
  // downgraded to approximate while the service was running, stop immediately
  // instead of pinging wrong positions.
  try {
    if (!await LocationPrecision.isPreciseGranted()) {
      debugPrint('[GF_BG_ENTRY] Approximate location — precise required, stopping service');
      try {
        await FlutterLocalNotificationsPlugin().show(
          997,
          'Precise location required',
          'Approximate location breaks GPS punch and geofence. Open Settings '
              '\u2192 Apps \u2192 mAttendance \u2192 Location \u2192 Precise.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'user_alignment',
              'Attendance Alerts',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      } catch (_) {}
      if (service is AndroidServiceInstance) {
        service.stopSelf();
      }
      return;
    }
  } catch (_) {
    // Fail-open: if precision can't be determined, keep current behavior.
  }

  final locationFilter = LocationFilter();
  TrackingState trackingState = TrackingState.MOVING;

  LocationResult? currentFilteredPosition;
  LocationResult? lastPingPosition;
  DateTime? lastPingTime;
  StreamSubscription<Position>? positionSub;
  StreamSubscription<ServiceStatus>? gpsStatusSub;
  Timer? timer;

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

  /// Reads geofence context written by [GeofenceMonitor] and emits a
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

        // Atomic lock claim: write unique owner token, re-read, verify
        // ownership.  If another isolate wrote after us, we lost the race.
        final owner = '$now-${DateTime.now().microsecondsSinceEpoch}';
        await prefs.setInt(_kBgRefreshLock, now);
        await prefs.setString('bg_refresh_lock_owner', owner);
        await prefs.reload();
        final persistedOwner = prefs.getString('bg_refresh_lock_owner');
        final persistedTs = prefs.getInt(_kBgRefreshLock) ?? 0;
        if (persistedOwner != owner || persistedTs != now) {
          debugPrint('[FieldTracking] Lost refresh-lock race — skipping ping');
          return;
        }

        try {
          final refreshToken = prefs.getString(_kBgRefreshToken);
          if (refreshToken == null) {
            debugPrint('[FieldTracking] No refresh token — cannot refresh');
            // We DON'T wipe tokens here to avoid accidental logout. 
            // The main isolate will handle it when the app is opened.
            await prefs.remove(_kBgRefreshLock);
            await prefs.remove('bg_refresh_lock_owner');
            return;
          }

          // Session guard: capture session generation BEFORE the network
          // call.  If it changed (logout/relogin elsewhere) while we were
          // refreshing, discard results — prevents token resurrection.
          final sessionId = prefs.getString('auth_session_id');

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

          // Verify session marker is unchanged before persisting.
          await prefs.reload();
          if (prefs.getString('auth_session_id') != sessionId) {
            debugPrint('[FieldTracking] Session changed during refresh — discarding tokens');
            await prefs.remove(_kBgRefreshLock);
            await prefs.remove('bg_refresh_lock_owner');
            return;
          }

          // Persist refreshed tokens with timestamp
          await Future.wait([
            prefs.setString(_kBgAccessToken, newAccess),
            prefs.setString(_kBgRefreshToken, newRefresh),
            prefs.setInt(_kBgTokenTimestamp, DateTime.now().millisecondsSinceEpoch),
            prefs.remove(_kBgRefreshLock),
            prefs.remove('bg_refresh_lock_owner'),
          ]);

          debugPrint('[FieldTracking] Token refreshed — retrying ping');
          await _buildDio(newAccess).post(ApiEndpoints.trackingPing, data: pingData);
        } catch (refreshErr) {
          await prefs.remove(_kBgRefreshLock);
          await prefs.remove('bg_refresh_lock_owner');
          
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
  Position? lastStreamPosition;
  positionSub = Geolocator.getPositionStream(locationSettings: locationSettings)
      .where((pos) {
        // Mock location detection — filter out spoofed fixes
        if (MockLocationDetector.isMockedStream(pos, lastStreamPosition)) {
          debugPrint('[GF_BG_ENTRY] Mock location in stream — filtering out');
          return false;
        }
        lastStreamPosition = pos;
        return true;
      })
      .listen(
    (pos) async {
      // Mock location detection — warn user and skip this fix
      if (MockLocationDetector.isMockedStream(pos, lastStreamPosition)) {
        debugPrint('[GF_BG_ENTRY] Mock location in stream — warning user');
        await MockLocationDetector.showMockLocationWarning();
        return;
      }
      lastStreamPosition = pos;
      
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

      // ── Update foreground notification (punch state / accuracy) ──────────
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
    // No shift → no nagging: GPS-off alerts only matter while the user is
    // punched in (auto punch must work).  At home, punched out, GPS being
    // off is normal and must stay quiet.
    final punchType = prefs.getString(_kPersistPunchType);
    if (punchType != 'In') return;
    final gfEnabled = prefs.getBool('geofence_auto_enabled') ?? false;
    final ftEnabled = prefs.getBool('field_tracking_enabled') ?? false;
    final wifiEnabled = prefs.getBool('wifi_auto_punch_enabled_bg') ?? false;
    final anyAuto = gfEnabled || ftEnabled || wifiEnabled;
    if (status == ServiceStatus.disabled && anyAuto) {
      debugPrint('[GF_BG_ENTRY] GPS turned off while auto punch active — sending alert');
      try {
        await gpsNotif.show(
          996,
          'GPS is off',
          'Auto punch and tracking won\u2019t work until you turn Location back '
          'on. Open phone Settings \u2192 Location \u2192 turn it on.',
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
        debugPrint('[GF_BG_ENTRY] GPS disabled notification failed: $e');
      }
    } else if (status == ServiceStatus.enabled && anyAuto) {
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
  // Geofence auto-punch no longer runs here — it is OS-native via
  // native_geofence (geofenceTriggered in geofence_monitor.dart), registered
  // from the main isolate by MainShell.  This service only does field-tracking
  // pings + WiFi auto-punch.
  debugPrint('[GF_BG_ENTRY] Geofence handled natively (native_geofence)');

  // ── Start WiFi background worker ─────────────────────────────────────────
  wifiWorker.start();
  debugPrint('[GF_BG_ENTRY] WiFi background worker started');

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
    // Kill the 15-min restart safety-net: a shift-end stop (or a settings
    // disable) must stay stopped until the next shift-start alarm re-arms.
    try {
      await GeofenceScheduler.cancelRestartAlarm();
    } catch (e) {
      debugPrint('[GF_BG_ENTRY] Cancel restart alarm failed: $e');
    }
    service.stopSelf();
  });
}
