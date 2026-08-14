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
/// GATED TO WORK HOURS (user spec: no "Geofence Active" banner on
/// non-working hours or leave days): the FGS runs only while punched IN
/// or within the shift window — leave days have no shift window, so the
/// banner never shows outside real work.  IN itself needs no service
/// (OS geofence ENTER is motion-assisted, fires even dead — field-
/// proven 12h+ without app open); the FGS exists for the walk-out.
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
///   - stopped when punched out AND outside the shift window (OUT punch
///     keeps the idle service through work hours; the receiver stops it
///     natively at the first post-window fire), on disable, or on logout
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
  /// to kill any dormant process, aggressive OEM or not), **gated to work
  /// hours only**: runs while (punched IN OR within the shift window).
  /// The FGS exists for exactly one job — catching the walk-out — and
  /// Android legally requires a persistent notification on any FGS, so
  /// the gate means the banner shows ONLY during work hours / while
  /// punched in, never at night, never on weekends, never on leave days
  /// (a leave day has no shift window).  The movement-gated stream
  /// inside it sees the office→outside transition in real fixes (~30m),
  /// and the OUT punch closes the service once the window also passed.
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

    // Banner gate: work hours only — punched IN, or within the shift
    // window (leave days have no window → no banner).
    if (prefs.getString('gf_last_punch_type') != 'In' &&
        !withinShiftWindow(prefs)) {
      debugPrint('[KEEP_ALIVE] Not punched in + outside shift window — '
          'skipping FGS (no banner outside work hours)');
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

  /// Stop the keep-alive (full service takes over / disable / logout).
  ///
  /// Smart by default: an OUT punch inside work hours keeps the idle FGS
  /// so the next IN / walk-out lands in a live process (the native
  /// receiver closes it at the first post-window fire).  [force] bypasses
  /// the work-hours gate — MUST be used when the combined service takes
  /// over (wifi/tracking) or on disable/logout: the keep-alive mode flag
  /// must be cleared or the full service would start in keep-alive mode.
  static Future<void> stop({bool force = false}) async {
    if (!Platform.isAndroid) return;
    final prefs = await SharedPreferences.getInstance();
    if (!force &&
        (prefs.getString('gf_last_punch_type') == 'In' ||
            withinShiftWindow(prefs))) {
      return;
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

  /// True when [now] (defaults to wall clock) is inside today's
  /// [shift start, shift end] window — mirrors
  /// [ContainmentAlarmReceiver.withinShiftWindow] (Kotlin).
  /// Overnight shifts (end < start today) roll the end to tomorrow.
  /// Leave days have no shift window → false → no FGS, no containment.
  /// Fail-safe: unknown/missing shift times → false (nothing to gate on;
  /// the chain re-evaluates on every native fire).
  static bool withinShiftWindow(SharedPreferences prefs, [DateTime? now]) {
    // Leave-day gate: explicit FALSE wins only for the day it was
    // written (app learned today is a leave day — empty shift list).
    // STALE marker / never written → TRUE (workday assumption) so the
    // headless self-heal keeps working after days without app opens.
    final markerDate = prefs.getString('gf_shift_today_date');
    final nowTime = now ?? DateTime.now();
    final todayKey = '${nowTime.year.toString().padLeft(4, '0')}-${nowTime.month.toString().padLeft(2, '0')}-${nowTime.day.toString().padLeft(2, '0')}';
    if (markerDate == todayKey &&
        prefs.getBool('gf_shift_today') == false) {
      return false;
    }
    final startRaw = prefs.getString('gf_cached_shift_start_time');
    final endRaw = prefs.getString('gf_shift_end_time');
    if (startRaw == null || endRaw == null) return false;
    final startParts = startRaw.split(':');
    if (startParts.length < 2) return false;
    final hour = int.tryParse(startParts[0]);
    final minute = int.tryParse(startParts[1]);
    if (hour == null || minute == null) return false;
    // gf_shift_end_time is a Dart toIso8601String() in LOCAL time; a
    // trailing Z (shouldn't happen) must be stripped like the native
    // parser does, never treated as UTC.
    final cleaned =
        endRaw.endsWith('Z') ? endRaw.substring(0, endRaw.length - 1) : endRaw;
    final end = DateTime.tryParse(cleaned);
    if (end == null) return false;

    final start = DateTime(nowTime.year, nowTime.month, nowTime.day, hour, minute);
    final endToday =
        DateTime(nowTime.year, nowTime.month, nowTime.day, end.hour, end.minute);
    if (endToday.isBefore(start)) {
      // Overnight shift: end belongs to tomorrow.
      return !nowTime.isBefore(start) &&
          !nowTime.isAfter(endToday.add(const Duration(days: 1)));
    }
    return !nowTime.isBefore(start) && !nowTime.isAfter(endToday);
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
