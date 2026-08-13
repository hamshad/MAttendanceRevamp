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
/// TIME-GATED (user spec: no "Geofence Active" banner outside work):
/// the FGS runs only while monitoring is actually needed — punched in,
/// or within the shift window.  Android legally forces a persistent
/// notification on any FGS, so the gate keeps the banner out of
/// nights/weekends; the native containment alarm re-evaluates every
/// 15 min and revives the FGS the moment it is needed.
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
  /// ALL Android devices (uniform behavior — the OS is equally willing
  /// to kill any dormant process, aggressive OEM or not), and only while
  /// monitoring is actually needed: punched in, or within the shift
  /// window.  The service holds the process so geofence/alarm/
  /// WorkManager run without exemptions — but Android legally requires a
  /// persistent notification for any foreground service, so keeping it
  /// running at night / outside the shift (nothing left to monitor)
  /// would show a pointless "Geofence Active" banner (user spec: no
  /// banner outside work).  The native containment alarm revives it
  /// within 15 min whenever it is needed again.
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

    // Banner gate: only while there is something to monitor.
    if (prefs.getString('gf_last_punch_type') != 'In' &&
        !_withinShiftWindow(prefs)) {
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

  /// True when the current time is inside today's [shift start, shift end]
  /// window — mirrors [ContainmentAlarmReceiver.withinShiftWindow] (Kotlin).
  /// Overnight shifts (end < start today) roll the end to tomorrow.
  /// Fail-safe: unknown/missing shift times → false (no FGS without a
  /// known work window; the native containment alarm re-evaluates on
  /// every fire and revives the service when needed).
  static bool _withinShiftWindow(SharedPreferences prefs) {
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
    final cleaned = endRaw.endsWith('Z') ? endRaw.substring(0, endRaw.length - 1) : endRaw;
    final end = DateTime.tryParse(cleaned);
    if (end == null) return false;

    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day, hour, minute);
    final endToday = DateTime(now.year, now.month, now.day, end.hour, end.minute);
    if (endToday.isBefore(start)) {
      // Overnight shift: end belongs to tomorrow.
      return !now.isBefore(start) &&
          !now.isAfter(endToday.add(const Duration(days: 1)));
    }
    return !now.isBefore(start) && !now.isAfter(endToday);
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
