---
status: resolved
trigger: "background service still auto-starts when shift starts on a new day, supposedly stopped; only geofence + client sites + GPS enabled"
created: 2026-08-13
updated: 2026-08-13
---

## Current Focus
hypothesis: CONFIRMED — native GeofenceAlarmReceiver.onReceive starts BackgroundService UNCONDITIONALLY at shift start, bypassing the Dart serviceRequired() gate every other start path honors.
test: (done) read GeofenceAlarmReceiver.kt (starts FGS always), scheduler gates (clean), BootReceiver (clean), ContainmentAlarmReceiver (gated), wifi_auto_punch_service.start() flag write (called only when Hive isEnabled true)
expecting: native gate fix + Dart entrypoint defense-in-depth
next_action: implement fix

## Symptoms
expected: no background service (combined or keep-alive) on shift start when only geofence + client sites + GPS enabled
actual: some background service starts when shift starts on a new day
errors: (none reported)
reproduction: enable only geofence auto + client sites; let a new shift day start; watch for service/FGS notification
started: persists after the wifi-default-false fix (0ddb03a)

## Eliminated
- hypothesis: serviceRequired() in scheduler/workmanager gate leaks (stale ?? true or wrong flag)
  evidence: geofence_scheduler.dart lines 260/274-276 + workmanager callback lines 83/129 all read wifi bg/fg + field_tracking with ?? false; wifi_auto_punch_enabled (fg) is never written anywhere
  timestamp: 2026-08-13
- hypothesis: wifi_auto_punch_service.start() force-sets wifi_auto_punch_enabled_bg=true at app open
  evidence: _initWifiAuto (main_shell 371) syncs bg flag from Hive wifiAutoPunchEnabled; service.start() only called when Hive isEnabled true
  timestamp: 2026-08-13
- hypothesis: keep-alive FGS (aggressive OEM) wrongly fires for geofence-only
  evidence: OemKeepAliveService.startIfNeeded gated on AggressiveOem.isAggressive + token + anyAuto + !serviceRequired; ContainmentAlarmReceiver revives keep-alive ONLY when isAggressiveOem && !serviceRequired — by design
  timestamp: 2026-08-13

## Evidence
- timestamp: 2026-08-13
  checked: GeofenceAlarmReceiver.kt onReceive
  found: starts BackgroundService via startForegroundService unconditional — NO serviceRequired check. Writes gf_alarm_fired + re-arms next shift.
  implication: THE root cause — this native exact alarm fires every shift day for ALL users and cold-starts the combined FGS regardless of feature flags
- timestamp: 2026-08-13
  checked: geofenceAndTrackingEntrypoint empty-feature guard (field_tracking_service.dart ~200)
  found: stops only when NO auto feature at all (geofence_auto_enabled counts as non-empty) → geofence-only users pass the guard and the FGS keeps running combined-mode: full GPS stream (distanceFilter 0, high accuracy) + ping timer all day
  implication: secondary defect — entrypoint must also reject geofence-only config (defense in depth)
- timestamp: 2026-08-13
  checked: scheduleNextShift (geofence_scheduler 306-362)
  found: registers BOTH WorkManager shift task (gated, headless self-heal for geofence-only) AND native alarm (ungated)
  implication: gating the native receiver is safe — WorkManager task still covers service-required users + geofence-only self-heal
- timestamp: 2026-08-13
  checked: BootReceiver.kt + MainActivity.kt
  found: shift-alarm re-arm on boot leads into the ungated receiver; wasTracking→full service (fine); aggressive+!serviceRequired+armed→keep-alive (correct); MainActivity only stops via channel
  implication: no other unconditional start path

## Resolution
root_cause: GeofenceAlarmReceiver.onReceive started BackgroundService unconditionally at shift start (native exact alarm bypasses Dart serviceRequired() gate), and the Dart entrypoint's empty-guard treated geofence_auto_enabled as needing the combined service → geofence-only users got full FGS + continuous GPS stream all day
fix: (1) GeofenceAlarmReceiver.onReceive now checks serviceRequired() (wifi bg/fg + field_tracking prefs) before starting BackgroundService; geofence-only still writes gf_alarm_fired + re-arms next shift (headless self-heal). (2) Dart entrypoint defense-in-depth: after keep-alive branch, if !GeofenceScheduler.serviceRequired() → registerZones + reconcile once + stopSelf (never run combined-mode for geofence-only). WorkManager shift task already gated + covers service-required users.
verification: flutter analyze clean (pre-existing warnings only), 159/159 tests, debug APK builds
files_changed: [android/.../GeofenceAlarmReceiver.kt, lib/features/tracking/services/field_tracking_service.dart]