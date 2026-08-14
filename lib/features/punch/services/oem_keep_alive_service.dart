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
/// PUNCH+SHIFT GATED (user spec: no banner outside actual work): the FGS
/// runs while punched IN (the walk-out monitor) and stays up after an OUT
/// punch while the workday is still open — the stream then catches the
/// RETURN-IN at point (aggressive OEMs like Nothing drop the headless OS
/// ENTER; the movement-gated stream reconciles IN at ~radius+5m, the
/// Aug-8-proven 21m IN).  The banner therefore shows during work hours
/// only: OUT after shift end, or the first fix/check past the end, stops
/// the service — no banner at home, nights, weekends or leave days.
/// IN itself needs NO service when the OS ENTER delivers (Samsung-class);
/// the FGS + stream is the at-point guarantee where it doesn't.
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
///   - stopped on the OUT punch ONLY when the shift window is closed
///     ([stop] smart gate) — during the workday the FGS stays up and its
///     stream punches the return-IN at point
///   - closed at the first post-shift-end signal (stream fix /
///     containment check) — back to headless (OS ENTER + 15-min net)
///   - NEVER auto-revived (user design): if the user closes the FGS it
///     stays closed — the banner must not come back behind their back.
///     Headless OUT keeps working: OS geofence EXIT is the primary
///     headless OUT path; the 15-min containment checker (headless
///     WorkManager reconcile, fixed 45m OUT band, two-fix confirm)
///     guarantees the OUT within one interval at most.
///   - stopped on disable, or on logout ([stop(force: true)])
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
  /// workday** (user design): the FGS exists for exactly two jobs —
  /// catching the walk-out (movement-gated stream, OUT at the boundary)
  /// and catching the RETURN-IN at point when punched OUT within the open
  /// shift window (aggressive OEMs like Nothing drop the headless OS
  /// ENTER — the stream reconciles IN on the first honest inside fix).
  /// Android legally requires a persistent notification on any FGS, so
  /// the workday gate means the banner shows ONLY while actually at
  /// work: punched OUT after the shift end (or first check past it)
  /// stops the service — no banner at home, nights, weekends or leave
  /// days.  Headless IN + the native 15-min containment watchdog remain
  /// the dead-process backup.
  /// Called from ANY isolate (headless punches include the main
  /// isolate): `_persistPunchState` starts it on IN and on OUT-within-
  /// window; [stop] closes it past the shift end / on disable/logout.
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

    // Banner gate: punched IN (walk-out monitor) XOR punched OUT within
    // the open shift window (at-point return-IN monitor).  Outside work
    // hours → no FGS, no banner (immutable user design): headless IN +
    // the 15-min watchdog cover the dead-process case.
    final punchType = prefs.getString('gf_last_punch_type') ?? 'Out';
    final withinWindow = !isPastShiftEnd(prefs);
    if (punchType != 'In' && !withinWindow) {
      debugPrint('[KEEP_ALIVE] Punched out and shift window closed — '
          'skipping FGS (no banner outside work; headless IN + watchdog '
          'cover the rest)');
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

  /// Decides whether the keep-alive FGS must SURVIVE an OUT punch.
  ///
  /// At-point IN (user spec: "IN should work at point"): the FGS's
  /// movement-gated stream is the only IN mechanism that works on
  /// aggressive OEMs like Nothing — the OS geofence ENTER gets dropped or
  /// deferred from a dead process there (field-proven missed-IN), while
  /// the stream catches the walk back in fix-by-fix and reconciles IN at
  /// ~radius+5m (the Aug-8 flawless IN: 21m, 3-4 min — the same stream).
  ///
  /// Keep running while punched OUT but the workday is still open (user
  /// goes to lunch / a client site / a meeting and comes back); the
  /// banner stays visible during work hours only.  Once the shift window
  /// is over there is nothing to come back TO — stop (no banner at home
  /// — the immutable outside-work rule).
  ///
  /// Pure function — unit-testable.
  static bool shouldKeepAliveAfterOut({
    required bool geofenceAutoOn,
    required bool pastShiftEnd,
    required String? punchType,
  }) {
    if (!geofenceAutoOn) return false;
    if (punchType != 'Out') return false;
    return !pastShiftEnd;
  }

  /// Stop the keep-alive foreground service.
  ///
  /// [force] bypasses the smart gate — used by takeover (wifi/tracking
  /// combined service), disable and logout where the service must go down
  /// regardless of the shift window.  Default (OUT punch): keep the FGS
  /// through the shift window so the stream can punch the return-IN at
  /// point (Nothing-class OEMs drop the headless OS ENTER); stop once the
  /// workday is over (banner must not linger outside work).
  /// The keep-alive MODE flag must be cleared in every case or the full
  /// service would start in keep-alive mode.
  static Future<void> stop({bool force = false}) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (!force) {
      final geofenceAutoOn = prefs.getBool('geofence_auto_enabled') ?? false;
      final pastShiftEnd = isPastShiftEnd(prefs);
      if (shouldKeepAliveAfterOut(
        geofenceAutoOn: geofenceAutoOn,
        pastShiftEnd: pastShiftEnd,
        punchType: prefs.getString('gf_last_punch_type'),
      )) {
        debugPrint('[KEEP_ALIVE] OUT within shift window — keeping FGS '
            'for at-point IN on return');
        // ALSO covers the headless-OUT case (OS EXIT punch, process
        // already dead): the FGS may not be running — make sure it is,
        // so the return-IN stream is alive when the user walks back.
        await startIfNeeded();
        return;
      }
    }
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

  /// True once the persisted shift end has passed (also for absent/stale
  /// ends — the workday is over, no banner).  Mirrors
  /// [GeofenceScheduler.isPastShiftEnd] without importing it (keeps the
  /// keep-alive service free of a scheduler dependency cycle).
  static bool isPastShiftEnd(SharedPreferences prefs) {
    final raw = prefs.getString('gf_shift_end_time');
    if (raw == null) return true;
    final end = DateTime.tryParse(raw);
    if (end == null) return true;
    return DateTime.now().isAfter(end);
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
