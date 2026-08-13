import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../tracking/services/field_tracking_service.dart';

/// Lightweight foreground service for ALL Android devices (uniform
/// behavior — user decision: no headless-only OEM split).
///
/// WHY: Android kills dormant processes on any ROM, and a killed process
/// can't deliver WorkManager results, alarm receivers or geofence
/// transitions from background.  A foreground service is the one thing
/// Android reliably keeps alive (battery-saver tier; survives
/// backgrounding, screen-off, Doze) — on aggressive ROMs (MIUI &
/// friends) it is effectively required, on stock Android it removes the
/// same exemptions.
///
/// TIME-GATED BY PUNCH STATE (user spec: no "Geofence Active" banner
/// outside work): the FGS runs **only while punched IN** — the OUT
/// punch closes it immediately, next IN opens it again.  IN itself needs
/// no service (OS geofence ENTER is motion-assisted, fires even dead —
/// field-proven 12h+ without app open).
///
/// This service does almost NOTHING on purpose: no GPS streams, no timers,
/// no polling.  It only holds the process alive so the OS geofence
/// receiver, the containment alarm and WorkManager tasks all run in an
/// already-alive process.  Battery cost ≈ idle process + visible
/// notification (the trade every user implicitly accepts, limited to
/// work hours).
///
/// Lifecycle (no app-open dependency once started):
///   - started from the main isolate (init / resume / within shift window)
///   - restarted by the native ContainmentAlarmReceiver on its 15-min
///     alarm when the process died (exact alarm → exempt from background
///     start restrictions) — the alarm fires and revives the service
///   - restarted by the plugin's own WatchdogReceiver after swipe-away
///     (best-effort on MIUI, which blocks the watchdog without autostart)
///   - stopped the moment the OUT punch persists (receiver + Dart both
///     stop the service natively), on disable, or on logout
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
  /// ALL Android devices (uniform behavior — the OS is equally willing
  /// to kill any dormant process, aggressive OEM or not), **and ONLY
  /// while punched IN**.  The FGS exists for exactly one job: catching
  /// the walk-out.  The movement-gated stream inside it sees the
  /// office→outside transition in real fixes (~30m), the OUT punch then
  /// closes the service immediately (banner gone until the next IN).
  /// Android legally requires a persistent notification for any
  /// foreground service, so IN-only gating means the banner exists
  /// exactly while the user is actually at work — never at night,
  /// never at weekend, never before the first IN.
  ///
  /// ENTER (the IN punch) needs NO service: OS geofence ENTER is
  /// motion-assisted and fires instantly even with a dead process
  /// (confirmed in the field, 12h+ without app open).
  ///
  /// Called from ANY isolate (headless punches include the main
  /// isolate): `_persistPunchState` starts it on IN and stops on OUT.
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

    // Banner gate: ONLY while punched IN.
    if (prefs.getString('gf_last_punch_type') != 'In') {
      debugPrint('[KEEP_ALIVE] Not punched in — skipping FGS (no banner)');
      return;
    }

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
