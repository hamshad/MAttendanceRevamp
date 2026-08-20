import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../../core/offline/offline_sync_manager.dart';
import '../../../core/utils/constants.dart';
import '../../../models/offline_punch.dart';
import '../../../models/shift.dart';
import '../../alignment/headless_alignment_worker.dart';
import '../../tracking/services/field_tracking_service.dart';
import 'geofence_monitor.dart';
import 'oem_keep_alive_service.dart';

const _kTaskName = 'geofence_shift_start';
const _kRestartTaskName = 'geofence_restart';
const _kContainmentTaskName = 'geofence_containment';
const _kPrefNextShiftStart = 'gf_next_shift_start';
const _kPrefShiftName = 'gf_cached_shift_name';
const _kPrefShiftEnd = 'gf_shift_end_time';

/// Dart-visible mirror of the native arm flag.  Written from ANY isolate
/// (prefs work headless); read by the native [ContainmentAlarmReceiver]
/// every fire to decide whether to keep self-arming.
const _kPrefContainmentArmed = 'gf_containment_alarm_armed';

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
    // Hive init for the offline punch queue AND the geofence settings box —
    // headless isolates (containment / alignment / sync tasks) need them
    // BEFORE any code path touches Hive:
    //   - offlinePunchBox: a headless punch POST-fail falls back to the queue
    //     (missing box = silent punch loss),
    //   - geofenceSettingsBox: GeofenceMonitor.isEnabled (the re-register /
    //     reconcile gate) reads it — missing box made the ENTIRE 15-min
    //     containment net throw HiveError on every fire (no catch-up ENTER,
    //     no reconcile, no recovery for a rate-limited / deferred IN),
    //   - cacheBox / shiftsBox / tokenBackupBox: mirrored from main.dart for
    //     the sync / shift paths.  Cheap when run repeatedly.
    try {
      await Hive.initFlutter();
      Hive.registerAdapter(OfflinePunchAdapter());
      await Hive.openBox<OfflinePunch>(AppConstants.offlinePunchBox);
      await Hive.openBox(AppConstants.cacheBox);
      await Hive.openBox(AppConstants.geofenceSettingsBox);
      await Hive.openBox(AppConstants.shiftsBox);
      await Hive.openBox(AppConstants.tokenBackupBox);
    } catch (e) {
      debugPrint('[GF_SCHED] Hive init failed: $e');
    }
    // ── Offline queue sync tasks ────────────────────────────────────────
    // Route to the offline sync manager BEFORE geofence logic.  These tasks
    // sync queued punches when connectivity returns, then close.
    if (OfflineSyncManager.handles(taskName)) {
      return OfflineSyncManager.executeSyncTask();
    }

    // ── Headless alignment warnings ─────────────────────────────────────
    // Periodic task (see registerAlignmentWorker) — re-posts the GPS-off /
    // wifi-hidden / no-connectivity nags for users whose background service
    // no longer runs (geofence-only).  Pure prefs + plugin channels, no
    // service needed.
    if (taskName == HeadlessAlignmentWorker.taskName) {
      return HeadlessAlignmentWorker.run();
    }

    // ── Containment check (missed-EXIT/missed-ENTER guarantee) ──────────
    // Fired by the native ContainmentAlarmReceiver every ~15 min (the OS
    // misses geofence EXIT transitions while backgrounded — this task is
    // the net that punches the user out anyway).  Re-checks containment
    // from the headless isolate and punches when the user is on the wrong
    // side of the boundary.  No service, no app needed.
    if (taskName == _kContainmentTaskName) {
      return ContainmentCheckWorker.run();
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
      // an empty foreground service.  Still re-register OS geofences here:
      // this alarm is the reboot-safe heartbeat (re-armed by the native
      // BootReceiver after reboot) that self-heals the native path without
      // the app being opened.
      if (!await GeofenceScheduler.serviceRequired()) {
        debugPrint('[GF_SCHED] No service-requiring feature — headless geofence self-heal');
        await GeofenceMonitor.reRegisterFromHeadless();
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
      // users run headless via the native path; still self-heal geofences.
      if (!await GeofenceScheduler.serviceRequired()) {
        debugPrint('[GF_SCHED] No service-requiring feature — headless geofence self-heal');
        await GeofenceMonitor.reRegisterFromHeadless();
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

/// Headless body of the periodic containment check — run by the
/// [ContainmentAlarmReceiver]-fired WorkManager task (see
/// [GeofenceScheduler.armContainmentAlarmIfNeeded]).
///
/// Re-checks containment and punches OUT/IN when the user is on the wrong
/// side of an office boundary, without any app/service process.  All gates
/// (token, enable flags, punch state, location service) live inside
/// [GeofencePunchHandler.reconcileContainment], so this worker is safe to
/// fire unconditionally.
class ContainmentCheckWorker {
  ContainmentCheckWorker._();

  static const taskName = _kContainmentTaskName;

  static Future<bool> run() async {
    try {
      debugPrint('[GF_SCHED] Containment check fired (headless)');
      // Self-heal OS geofences: the system drops registrations on force-stop,
      // OEM memory cleanups, and reboots.  Re-registering every 15 min from
      // PERSISTED metadata (no network — a fetch here would hit the API 96×
      // a day; fresh zones come from app-open paths) keeps the headless
      // ENTER/EXIT path alive no matter what killed the registration.
      //
      // initialTriggers: {enter} ALSO re-arms the catch-up ENTER: when the
      // phone is already inside a zone, re-registration re-fires ENTER —
      // the fix-independent headless IN recovery for a punched-OUT user
      // whose OS ENTER was dropped/deferred (aggressive OEMs; the Nothing
      // 3a missed-IN class).  Safe for a punched-IN user sitting inside:
      // the punch path persists own-source duplicates SILENTLY (no
      // notification), and catch-up ENTER only fires when genuinely inside
      // the geofence radius — it cannot fabricate a far-away IN.
      await GeofenceMonitor.reRegisterZonesFromCache(
        initialTriggers: const {GeofenceEvent.enter},
      );
      await GeofencePunchHandler.instance.reconcileContainment(confirmOut: true);
    } catch (e) {
      debugPrint('[GF_SCHED] Containment check failed: $e');
    }
    return true;
  }
}

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

  /// Periodically re-check alignment conditions from the headless isolate
  /// (GPS off / wifi hidden / no connectivity).  Replaces the service-isolate
  /// nags for geofence-only users who no longer run a service.  The worker
  /// self-gates on prefs (token, punch state, feature toggles) — scheduling
  /// it unconditionally is harmless.  WorkManager persists + reschedules it
  /// across app kills and reboots; min frequency is 15 min.
  static Future<void> registerAlignmentWorker() async {
    await Workmanager().registerPeriodicTask(
      HeadlessAlignmentWorker.taskName,
      HeadlessAlignmentWorker.taskName,
      frequency: const Duration(minutes: 30),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
    debugPrint('[GF_SCHED] Alignment warning worker scheduled (+30m)');
  }

  /// Stop the periodic alignment worker (all auto features off / logout).
  static Future<void> cancelAlignmentWorker() async {
    await Workmanager()
        .cancelByUniqueName(HeadlessAlignmentWorker.taskName);
    debugPrint('[GF_SCHED] Alignment warning worker cancelled');
  }

  /// Arm the 15-minute containment-check alarm (native AlarmManager,
  /// Doze-tolerant — see ContainmentAlarmReceiver).  Called from the main
  /// isolate (init / resume / after login) to schedule the FIRST fire;
  /// afterwards the receiver self-perpetuates on every fire as long as the
  /// prefs flag ([_kPrefContainmentArmed]) is set — the flag is flipped by
  /// punch-in / punch-out from ANY isolate, so the loop survives app kills
  /// without the app ever being opened again.
  ///
  /// On aggressive OEMs (MIUI & friends) also starts the lightweight
  /// keep-alive foreground service — these ROMs won't spawn the app from
  /// background at all, so the alarm+WorkManager path alone is not enough;
  /// the foreground service holds the process so everything runs in a
  /// live process.
  ///
  /// Battery note: while punched in at the office the Dart side reuses the
  /// OS last-known position (no GPS radio) — each fire is a brief CPU
  /// wakeup + prefs read.  GPS (≤2 short fixes) only when the cache shows
  /// the user has left the office radius.  The keep-alive service itself
  /// is idle (no timers, no GPS) — cost is the process + notification.
  static Future<void> armContainmentAlarmIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('bg_access_token');
    if (token == null || token.isEmpty) {
      await cancelContainmentAlarm();
      return;
    }
    if (!await anyAutoFeatureEnabled()) {
      await cancelContainmentAlarm();
      return;
    }
    await prefs.setBool(_kPrefContainmentArmed, true);
    if (Platform.isAndroid) {
      try {
        await _kAlarmChannel.invokeMethod('scheduleContainmentAlarm');
        debugPrint('[GF_SCHED] Containment alarm armed (+15m periodic)');
      } catch (e) {
        debugPrint('[GF_SCHED] Containment alarm skipped (channel): $e');
      }
    }
    // Aggressive OEM: keep the process alive (see doc comment above).
    await OemKeepAliveService.startIfNeeded();
  }

  /// Stop the containment alarm entirely (logout / geofence disabled).
  static Future<void> cancelContainmentAlarm() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPrefContainmentArmed, false);
    if (Platform.isAndroid) {
      try {
        await _kAlarmChannel.invokeMethod('cancelContainmentAlarm');
        debugPrint('[GF_SCHED] Containment alarm cancelled');
      } catch (_) {}
    }
    await OemKeepAliveService.stop();
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
    await registerAlignmentWorker();

    if (!now.isBefore(start) && now.isBefore(end)) {
      // Nothing to monitor that needs a live isolate — geofence-only users
      // punch via the native headless path (no service process).  The
      // shift-start alarm stays armed as the reboot-safe heartbeat: after a
      // reboot the native BootReceiver re-arms it, and on fire the headless
      // callback re-registers the OS geofences (self-heal without opening
      // the app).  Cost: one alarm wakeup per day — negligible vs the
      // service it replaces.
      if (!await serviceRequired()) {
        debugPrint('[GF_SCHED] Within window — geofence-only: alarm = self-heal heartbeat, no service');
        await scheduleNextShift(shift);
        return;
      }

      final svc = FlutterBackgroundService();
      final alreadyRunning = await svc.isRunning();
      debugPrint('[GF_SCHED] Within shift window — service running=$alreadyRunning');

      // Keep-alive mode would hold the process WITHOUT the full service —
      // never start the combined service on top of it.  Stop first, then
      // the configure+start below replaces it (mode flag cleared).
      await OemKeepAliveService.stop();

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

    // Always arm the next shift-start alarm.  For service users it starts
    // the service; for geofence-only users it is the reboot-safe self-heal
    // heartbeat that re-registers OS geofences headlessly (see the
    // workmanager callback).  The restart safety-net is NOT armed for
    // geofence-only (no service to revive).
    await scheduleNextShift(shift);
  }

  /// Cancel any pending shift-start and restart alarms.
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(_kTaskName);
    await Workmanager().cancelByUniqueName(_kRestartTaskName);
    await cancelAlignmentWorker();
    await cancelContainmentAlarm();
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
