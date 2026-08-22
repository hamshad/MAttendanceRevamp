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
/// PUNCH-STATE GATED (user spec: no "Geofence Active" banner outside
/// actual work): the FGS runs ONLY while punched IN.  It exists for
/// exactly one job — catching the walk-out with a movement-gated stream
/// so OUT punches at the boundary (accurate, two-fix confirmed) — and
/// Android legally requires a persistent notification on any FGS, so the
/// punch-state gate keeps the banner off nights, weekends and leave
/// days.  IN itself needs NO service: OS geofence ENTER is
/// motion-assisted, fires even with a dead process (field-proven 12h+
/// without app open).  Punched OUT = headless again: OS geofence ENTER
/// for IN + the 15-min AlarmManager containment alarm as the always-on
/// checker that re-heals the headless IN pipeline (re-registers OS
/// geofences, re-queues the WorkManager task) and revives this FGS
/// within 15 min whenever it is needed.
///
/// This service does almost NOTHING on purpose: no timers, no polling —
/// only the movement-gated GPS stream (distanceFilter 30m) while punched
/// in, zero fixes when stationary.  Battery cost ≈ idle process + visible
/// notification (the trade every user implicitly accepts, limited to
/// work hours).
///
/// Lifecycle (no app-open dependency once started):
///   - started on the IN punch from ANY isolate (headless IN punches
///     included) — `_persistPunchState` calls [startIfNeeded]
///   - stopped on the OUT punch ([stop]) — back to headless IN
///   - NEVER auto-revived (user design): if the user closes the FGS it
///     stays closed — the banner must not come back behind their back.
///     Headless OUT keeps working: OS geofence EXIT is the primary
///     headless OUT path; the 15-min containment checker (headless
///     WorkManager reconcile, fixed 45m OUT band, two-fix confirm)
///     guarantees the OUT within one interval at most.
///   - stopped on disable, or on logout
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
  /// to kill any dormant process, aggressive OEM or not), **gated to the
  /// punched-IN state only** (user design): the FGS exists for exactly
  /// one job — catching the walk-out with a movement-gated stream so the
  /// OUT punches at the boundary (accurate, two-fix) — and Android
  /// legally requires a persistent notification on any FGS, so the
  /// punch-state gate means the banner shows ONLY while actually at
  /// work.  Punched OUT = no service, no banner — everything runs
  /// headless: OS geofence ENTER punches IN with a dead process
  /// (field-proven, 12h+ without app open), the native 15-min
  /// containment alarm is the 24/7 watchdog that re-heals the headless
  /// IN pipeline (re-registers OS geofences, re-queues WorkManager).
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

    // Banner gate: punched IN only — the FGS exists to watch the walk-out.
    if (prefs.getString('gf_last_punch_type') != 'In') {
      debugPrint('[KEEP_ALIVE] Not punched in — skipping FGS '
          '(no banner outside work; headless IN + watchdog cover the rest)');
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
      debugPrint('[KEEP_ALIVE] Foreground service started (work-hours keep-alive)');
    } catch (e) {
      debugPrint('[KEEP_ALIVE] start failed: $e');
    }
  }

  /// Keep the keep-alive FGS lifecycle in sync with the punch state written
  /// by ANY source.
  ///
  /// The geofence punch path (`_persistPunchState`) is not the only writer
  /// of `gf_last_punch_type`: manual UI punches, the server-state mirror
  /// (`PunchStateInterceptor`, attendance poll) and the offline queue
  /// flushes all persist the punch type directly.  Before this helper,
  /// an OUT written by any of those left the FGS running — banner stuck
  /// "Geofence Active" after the user punched out (2026-08-17 user
  /// report).  And a MANUAL IN never started the walk-out monitor.
  ///
  /// Cheap no-op when nothing changed: [startIfNeeded] and [stop] both
  /// re-read prefs + `isRunning()` and act only on transitions.
  static Future<void> syncToPunchState() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString('gf_last_punch_type') == 'In') {
      await startIfNeeded();
    } else {
      await stop();
    }
  }

  /// Stop the keep-alive foreground service.
  ///
  /// Unconditional: once punched OUT we go back to the headless IN path
  /// (OS geofence ENTER + the 15-min AlarmManager checker) — no process,
  /// no banner.  Also used by the combined-service takeover
  /// (wifi/tracking), disable and logout: the keep-alive MODE flag must
  /// be cleared or the full service would start in keep-alive mode.
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keepAliveModeKey, false);
    final svc = FlutterBackgroundService();
    try {
      // isRunning() is unreliable (false negatives) on several ROMs — always
      // send the stop signal; invoke is a harmless no-op when not running.
      svc.invoke('stopKeepAlive');
      svc.invoke('stop');
      debugPrint('[KEEP_ALIVE] stop requested');
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
