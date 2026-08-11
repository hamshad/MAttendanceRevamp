import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/offline/offline_sync_manager.dart';
import '../../../models/shift.dart';
import '../../tracking/services/field_tracking_service.dart';

const _kTaskName = 'geofence_shift_start';
const _kRestartTaskName = 'geofence_restart';
const _kPrefNextShiftStart = 'gf_next_shift_start';
const _kPrefShiftName = 'gf_cached_shift_name';
const _kPrefShiftEnd = 'gf_shift_end_time';

/// MethodChannel for native AlarmManager (Android only).
/// Works from both main and background isolates.
const _kAlarmChannel = MethodChannel('com.mattendance.mattendance_mobile/geofence_alarm');

// ── Workmanager callback (MUST be top-level function, not a class method) ───
//
// Workmanager runs this in its own isolate after app kill. It configures and
// starts FlutterBackgroundService with the geofence entrypoint so that GPS
// monitoring and auto-punching begin without the user opening the app.

@pragma('vm:entry-point')
void geofenceWorkmanagerCallback() {
  Workmanager().executeTask((taskName, inputData) async {
    // ── Offline queue sync tasks ────────────────────────────────────────
    // Route to the offline sync manager BEFORE geofence logic.  These tasks
    // sync queued punches when connectivity returns, then close.
    if (OfflineSyncManager.handles(taskName)) {
      return OfflineSyncManager.executeSyncTask();
    }

    if (taskName == _kTaskName) {
      debugPrint('[GF_SCHED] Shift-start task fired');

      // Guard: no auth token → skip service start (user logged out).
      final sp = await SharedPreferences.getInstance();
      final token = sp.getString('bg_access_token');
      if (token == null || token.isEmpty) {
        debugPrint('[GF_SCHED] No auth token — skip service start');
        return true;
      }

      // Guard: no auto feature that needs a live isolate → the native
      // geofence path handles geofence-only users headlessly; don't start
      // an empty foreground service.
      if (!await GeofenceScheduler.serviceRequired()) {
        debugPrint('[GF_SCHED] No auto feature enabled — skip service start');
        return true;
      }

      final svc = FlutterBackgroundService();
      final isRunning = await svc.isRunning();

      if (!isRunning) {
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
            onBackground: _iosBackground,
          ),
        );

        await svc.startService();
        debugPrint('[GF_SCHED] Geofence background service started');
      } else {
        debugPrint('[GF_SCHED] Background service already running');
      }
    } else if (taskName == _kRestartTaskName) {
      debugPrint('[GF_SCHED] Restart safety-net task fired');

      // Guard: no auth token → skip service start (user logged out).
      final sp2 = await SharedPreferences.getInstance();
      final token2 = sp2.getString('bg_access_token');
      if (token2 == null || token2.isEmpty) {
        debugPrint('[GF_SCHED] No auth token — skip restart');
        return true;
      }

      // Guard: no auto feature that needs a live isolate → geofence-only
      // users run headless via the native path; nothing to restart.
      if (!await GeofenceScheduler.serviceRequired()) {
        debugPrint('[GF_SCHED] No auto feature enabled — skip restart');
        return true;
      }

      final svc = FlutterBackgroundService();
      final isRunning = await svc.isRunning();

      if (!isRunning) {
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
            onBackground: _iosBackground,
          ),
        );

        await svc.startService();
        debugPrint('[GF_SCHED] Geofence service restarted');

        // The newly started service will schedule its own restart alarm via loadData()
      } else {
        debugPrint('[GF_SCHED] Background service already running — re-scheduling restart');
        await GeofenceScheduler.scheduleRestartAlarm();
      }
    }

    return true;
  });
}

@pragma('vm:entry-point')
Future<bool> _iosBackground(ServiceInstance service) async => true;

/// Schedules and manages workmanager tasks for shift-start alarms.
///
/// On Android: uses WorkManager (survives app kill and reboot).
/// On iOS: uses BGTaskScheduler (best-effort, ~15 min window).
///
/// When the task fires, it re-configures [FlutterBackgroundService] with
/// the geofence entrypoint and starts it. The geofence monitoring runs
/// until shift end + punch-out.
/// Key written by [GeofenceAlarmReceiver] (native) when the alarm fires.
/// Allows the Dart side to detect missed alarms.
const _kPrefAlarmFired = 'gf_alarm_fired';
const _kPrefAlarmFiredAt = 'gf_alarm_fired_at';

class GeofenceScheduler {
  GeofenceScheduler._();

  /// Ensures the background service is only force-restarted once per session.
  /// Prevents redundant stop/start cycles on app resume via [didChangeAppLifecycleState].
  static bool _hasForceRestartedThisSession = false;

  /// Must be called once in `main()` before `runApp()`.
  static Future<void> init() async {
    debugPrint('[GF_SCHED] init() — resetting session flag');
    _hasForceRestartedThisSession = false;
    await Workmanager().initialize(geofenceWorkmanagerCallback, isInDebugMode: kDebugMode);
  }

  /// Persist today's shift-end so the background service can kill itself
  /// once the shift is over and the user has punched out (nothing left to
  /// monitor until the next shift-start alarm).
  static Future<void> _persistShiftEnd(DateTime end) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefShiftEnd, end.toIso8601String());
  }

  /// True when the current time is past the persisted shift end.
  /// Fail-safe: unknown shift end → false (never stop).
  static Future<bool> isPastShiftEnd() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefShiftEnd);
    if (raw == null) return false;
    final end = DateTime.tryParse(raw);
    if (end == null) return false;
    return DateTime.now().isAfter(end);
  }

  /// True when any auto feature needs the background service process:
  /// geofence auto-punch, WiFi auto-punch (bg or fg flag), or field
  /// tracking.  When all are off the service must not start at all —
  /// it would otherwise sit as an empty "Mattendance" foreground
  /// notification doing nothing.
  static Future<bool> anyAutoFeatureEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool('geofence_auto_enabled') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled') ?? false) ||
        (prefs.getBool('field_tracking_enabled') ?? false);
  }

  /// True when an auto feature NEEDS a live isolate: WiFi auto-punch
  /// (bg or fg — BSSID checks need a process with streams/timers) or field
  /// tracking (periodic GPS pings).  Geofence auto-punch alone does NOT:
  /// OS-registered geofences + the plugin's always-alive BroadcastReceiver
  /// + WorkManager headless engine punch with the app AND service dead
  /// (verified end-to-end).  Geofence-only users therefore get no service
  /// process and no alarms at all — zero service battery cost, and the
  /// native geofence does the work.
  static Future<bool> serviceRequired() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled') ?? false) ||
        (prefs.getBool('field_tracking_enabled') ?? false);
  }

  /// Cancel the 15-minute restart safety-net so a shift-end stop STAYS
  /// stopped until the next shift-start alarm.
  static Future<void> cancelRestartAlarm() async {
    await Workmanager().cancelByUniqueName(_kRestartTaskName);
  }

  /// Check if a native AlarmManager alarm fired while the Dart isolate was
  /// not running (app killed). If so, clear the flag and return true so the
  /// caller can trigger shift-start logic.
  static Future<bool> consumeMissedAlarmFlag() async {
    final prefs = await SharedPreferences.getInstance();
    final fired = prefs.getBool(_kPrefAlarmFired) ?? false;
    if (fired) {
      await prefs.remove(_kPrefAlarmFired);
      await prefs.remove(_kPrefAlarmFiredAt);
      debugPrint('[GF_SCHED] Missed alarm detected — flag consumed');
      return true;
    }
    return false;
  }

  /// Schedule the next shift-start alarm.
  ///
  /// Calculates the time until [shift]'s next start and registers
  /// both a WorkManager task and a native Android AlarmManager alarm.
  /// The AlarmManager alarm is more reliable on OEM ROMs that kill
  /// WorkManager tasks on force-stop.
  static Future<void> scheduleNextShift(Shift shift) async {
    final now = DateTime.now();
    final start = shift.todayStart;

    Duration delay;
    if (now.isBefore(start)) {
      delay = start.difference(now);
    } else {
      final tomorrow = now.add(const Duration(days: 1));
      final parts = shift.startTime.split(':');
      final nextStart = DateTime(
        tomorrow.year, tomorrow.month, tomorrow.day,
        int.parse(parts[0]), int.parse(parts[1]),
      );
      delay = nextStart.difference(now);
      if (delay.isNegative) delay = const Duration(seconds: 10);
    }

    final nextAlarm = DateTime.now().add(delay);

    // Persist shift info for diagnostics
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefShiftName, shift.name);
    await prefs.setString(_kPrefNextShiftStart, nextAlarm.toIso8601String());
    await _persistShiftEnd(shift.todayEnd);
    // Persist the raw start time ("HH:mm") so the native GeofenceAlarmReceiver
    // can self re-arm the next alarm without the Dart isolate.  The Dart
    // background isolate cannot reach the app's MethodChannel (it is only
    // registered on the main UI engine), so without this the next-day alarm
    // would be armed only by the inexact Workmanager task.
    await prefs.setString('gf_cached_shift_start_time', shift.startTime);

    // Schedule Workmanager alarm (no network constraint — must fire even offline)
    await Workmanager().registerOneOffTask(
      _kTaskName,
      _kTaskName,
      initialDelay: delay,
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );

    // Schedule native Android AlarmManager alarm
    if (Platform.isAndroid) {
      try {
        await _kAlarmChannel.invokeMethod('scheduleShiftAlarm', {
          'triggerAtMillis': nextAlarm.millisecondsSinceEpoch,
          'shiftName': shift.name,
        });
        debugPrint('[GF_SCHED] Native alarm scheduled for ${nextAlarm.toIso8601String()}');
      } catch (e) {
        // MethodChannel may not be available from background isolates or
        // before the Flutter engine is fully attached (pre-runApp).
        debugPrint('[GF_SCHED] Native alarm skipped (MethodChannel unavailable): $e');
      }
    }

    debugPrint('[GF_SCHED] Next shift alarm in ${delay.inMinutes}m (${shift.name} @ ${shift.startTime})');
  }

  /// Schedule a short-term restart alarm (15 min) as safety net during active shift.
  /// If the service/app is killed, Workmanager restarts it so geofence monitoring
  /// resumes without waiting for the next shift start.
  static Future<void> scheduleRestartAlarm() async {
    await Workmanager().registerOneOffTask(
      _kRestartTaskName,
      _kRestartTaskName,
      initialDelay: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
    debugPrint('[GF_SCHED] Restart safety-net alarm scheduled (+15m)');
  }

  /// Start the combined background service immediately if we are within
  /// an active shift window, and always schedule the next shift-start alarm.
  /// Call this after shifts are loaded/cached (e.g. after login).
  static Future<void> startIfWithinShiftWindow(List<Shift> shifts) async {
    if (shifts.isEmpty) {
      debugPrint('[GF_SCHED] startIfWithinShiftWindow — shifts empty, returning');
      return;
    }

    Shift? shift;
    for (final s in shifts) {
      if (s.isActive) { shift = s; break; }
    }
    shift ??= shifts.first;

    final now = DateTime.now();
    final start = shift.todayStart;
    final end = shift.todayEnd;

    debugPrint('[GF_SCHED] startIfWithinShiftWindow — shift=${shift.name}, now=$now, start=$start, end=$end, isOvernight=${shift.isOvernight}');
    await _persistShiftEnd(end);

    if (!now.isBefore(start) && now.isBefore(end)) {
      // Nothing to monitor that needs a live isolate — geofence-only users
      // punch via the native headless path (no service, no alarms).  If the
      // user enables wifi/tracking later, the next app open re-arms.
      if (!await serviceRequired()) {
        debugPrint('[GF_SCHED] Within window but no service-requiring feature enabled — skipping service start');
        return;
      }

      final svc = FlutterBackgroundService();
      final alreadyRunning = await svc.isRunning();
      debugPrint('[GF_SCHED] Within shift window — service running=$alreadyRunning');

      if (alreadyRunning) {
        if (_hasForceRestartedThisSession) {
          debugPrint('[GF_SCHED] Service already running — session restart already done, skipping');
        } else {
          // Service's native component survived app restart but the Dart engine
          // inside it may have stale data or a dead isolate. Stop and restart to
          // ensure fresh initialization in the current app session.
          _hasForceRestartedThisSession = true;
          debugPrint('[GF_SCHED] Force-restarting service for fresh init');
          try {
            await _kAlarmChannel.invokeMethod('stopBackgroundService');
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (e) {
            debugPrint('[GF_SCHED] stopBackgroundService failed: $e');
          }
        }
      }

      await svc.startService();
      debugPrint('[GF_SCHED] Service started/restarted');
      await scheduleRestartAlarm();
    } else {
      debugPrint('[GF_SCHED] NOT within shift window — start=${start}, end=$end');
    }

    // Geofence-only: nothing to arm — native geofences + headless punch need
    // no alarms.  Re-armed on the next app open if a service-requiring
    // feature gets enabled.
    if (await serviceRequired()) {
      await scheduleNextShift(shift);
    }
  }

  /// Cancel any pending shift-start and restart alarms.
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(_kTaskName);
    await Workmanager().cancelByUniqueName(_kRestartTaskName);
    if (Platform.isAndroid) {
      try {
        await _kAlarmChannel.invokeMethod('cancelShiftAlarm');
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPrefNextShiftStart);
    debugPrint('[GF_SCHED] Shift alarm cancelled');
  }

  /// Stop the geofence background service and restore field tracking config.
  static Future<void> stopGeofenceService() async {
    final svc = FlutterBackgroundService();
    final running = await svc.isRunning();
    debugPrint('[GF_SCHED] stopGeofenceService() called — isRunning=$running');
    if (running) {
      debugPrint('[GF_SCHED] Sending stop command to service');
      svc.invoke('stop');
      await Future.delayed(const Duration(milliseconds: 500));
      final stillRunning = await svc.isRunning();
      debugPrint('[GF_SCHED] After stop — isRunning=$stillRunning');
    }
    await FieldTrackingService.init();
    debugPrint('[GF_SCHED] Geofence service stopped, tracking config restored');
  }

  /// Returns the next scheduled alarm time, or null.
  static Future<DateTime?> getNextAlarmTime() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefNextShiftStart);
    return raw != null ? DateTime.tryParse(raw) : null;
  }

  /// Returns the cached shift name, or null.
  static Future<String?> getCachedShiftName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPrefShiftName);
  }
}
