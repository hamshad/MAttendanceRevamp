import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/aggressive_oem.dart';
import '../../tracking/services/field_tracking_service.dart';

/// Lightweight foreground service for aggressive OEMs (MIUI & friends).
///
/// WHY: on MIUI/HyperOS, ColorOS/OxygenOS, Funtouch/OriginOS and MagicOS,
/// background work without user exemptions is unreliable — WorkManager
/// tasks don't spawn the app process, alarm receivers get deferred, and
/// geofence transitions land in a process that can't start.  A foreground
/// service is the ONE thing these ROMs reliably keep alive (battery-saver
/// tier; it survives backgrounding, screen-off, Doze).
///
/// This service does almost NOTHING on purpose: no GPS streams, no timers,
/// no polling.  It only holds the process alive so the OS geofence
/// receiver, the containment alarm and WorkManager tasks all run in an
/// already-alive process.  Battery cost ≈ idle process + visible
/// notification (the trade every MIUI user implicitly accepts).
///
/// Lifecycle (no app-open dependency once started):
///   - started from the main isolate (init / resume / within shift window)
///   - restarted by the native ContainmentAlarmReceiver on its 15-min
///     alarm when the process died (exact alarm → exempt from background
///     start restrictions) — the alarm fires and revives the service
///   - restarted by the plugin's own WatchdogReceiver after swipe-away
///     (best-effort on MIUI, which blocks the watchdog without autostart)
///   - stopped when punched out outside the shift window (receiver stops
///     the service natively), on disable, or on logout
class OemKeepAliveService {
  OemKeepAliveService._();

  /// Mode flag written BEFORE the service starts.  The combined entrypoint
  /// ([geofenceAndTrackingEntrypoint]) branches on it: true → keep-alive
  /// mode (heal + reconcile + idle), false → full combined service.
  static const String keepAliveModeKey = 'gf_keep_alive_mode';

  /// True when a live isolate is genuinely needed (wifi auto / tracking) —
  /// then the full combined service replaces the keep-alive.
  static Future<bool> _serviceRequired() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled') ?? false) ||
        (prefs.getBool('field_tracking_enabled') ?? false);
  }

  /// Start the keep-alive foreground service when warranted: an auto
  /// feature enabled + no feature needing the full service.
  ///
  /// Aggressive OEMs ONLY.  The service holds the process so geofence/
  /// alarm/WorkManager run without exemptions — start regardless of punch
  /// state.  Other OEMs NEVER get the keep-alive: Android requires a
  /// persistent notification for any foreground service, and the user
  /// spec is no "Geofence Active" banner on top of auto-punch.  Stock
  /// Android runs the OS geofence + the headless 15-min containment
  /// alarm (WorkManager) with no process holding — OUT punches at the
  /// alarm fire, ~45m out with the fixed band, worst-case delay one
  /// alarm interval.
  /// Main isolate only (needs the plugin channel).
  static Future<void> startIfNeeded() async {
    if (!Platform.isAndroid) return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('bg_access_token') == null ||
        prefs.getString('bg_access_token')!.isEmpty) {
      return;
    }
    final anyAuto = (prefs.getBool('geofence_auto_enabled') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled') ?? false) ||
        (prefs.getBool('field_tracking_enabled') ?? false);
    if (!anyAuto) return;
    if (await _serviceRequired()) return; // full service owns the process

    if (!await AggressiveOem.isAggressive()) return; // headless for others

    final svc = FlutterBackgroundService();
    if (await svc.isRunning()) return;

    await prefs.setBool(keepAliveModeKey, true);
    try {
      await svc.configure(
        androidConfiguration: AndroidConfiguration(
          onStart: geofenceAndTrackingEntrypoint,
          isForegroundMode: true,
          autoStart: false,
          notificationChannelId: 'geofence_monitor',
          initialNotificationTitle: 'Geofence Active',
          initialNotificationContent: 'Monitoring',
          foregroundServiceNotificationId: 889,
          foregroundServiceTypes: [AndroidForegroundType.location],
        ),
        iosConfiguration: IosConfiguration(
          autoStart: false,
          onForeground: geofenceAndTrackingEntrypoint,
          onBackground: _iosBackgroundKeepAlive,
        ),
      );
      await svc.startService();
      debugPrint('[KEEP_ALIVE] Foreground service started (aggressive OEM)');
    } catch (e) {
      debugPrint('[KEEP_ALIVE] start failed: $e');
    }
  }

  /// Stop the keep-alive (full service takes over / disable / logout).
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keepAliveModeKey, false);
    final svc = FlutterBackgroundService();
    try {
      if (await svc.isRunning()) {
        svc.invoke('stopKeepAlive');
        debugPrint('[KEEP_ALIVE] stop requested');
      }
    } catch (e) {
      debugPrint('[KEEP_ALIVE] stop failed: $e');
    }
  }

  static Future<bool> isRunning() async {
    try {
      return await FlutterBackgroundService().isRunning();
    } catch (_) {
      return false;
    }
  }
}

@pragma('vm:entry-point')
Future<bool> _iosBackgroundKeepAlive(ServiceInstance service) async => true;
