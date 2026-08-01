---
status: resolved
trigger: "alarm wake works but starts haphazardly — not at the right time"
created: 2026-08-01T15:20:00Z
updated: 2026-08-01T16:20:00Z
---

## Current Focus
hypothesis: three root causes fixed — (1) setExact deferred in Doze, (2) native alarm never re-armed from background isolate (MethodChannel absent there), (3) BootReceiver parsed local-time ISO as UTC
test: emulator — install, verify alarm registered with *walarm* + device_idle=-- (Doze-exempt), fire receiver via run-as broadcast, verify self re-arm
expecting: alarm fires in Doze; receiver re-arms next shift natively; BootReceiver parses local time
next_action: report to user; do NOT commit until user says so (per session rule)

## Symptoms
expected: background geofence/wifi worker starts exactly at shift start
actual: alarm wakes the service, but at the wrong time — sometimes on time, often late (haphazard)
errors: none
reproduction: leave phone idle overnight (Doze) → alarm fires at shift start → service starts late; or after reboot → alarm fires at wrong absolute time
started: long-standing

## Eliminated
- hypothesis: Dart Timer in _scheduleShiftWindow is the cause
  evidence: the shift-start alarm itself is what starts the service; the Dart Timer only activates monitoring when the service is already running early (e.g. opened app). Foreground service keeps process alive, timer generally fires.
  timestamp: 2026-08-01

## Evidence
- timestamp: 2026-08-01T15:20:00Z
  checked: GeofenceAlarmReceiver.kt:42
  found: alarmManager.setExact(AlarmManager.RTC_WAKEUP, ...) — setExact alarms are DEFERRED during Doze mode; only setExactAndAllowWhileIdle / setAlarmClock fire in Doze. Phone idle overnight = deep Doze = alarm delayed to next maintenance window (10-30+ min).
  implication: PRIMARY cause of "fires late". Fixed → setExactAndAllowWhileIdle.
- timestamp: 2026-08-01T15:21:00Z
  checked: geofence_scheduler.dart:208-218 + loadData → _proactivelyScheduleAlarm
  found: scheduleNextShift tries MethodChannel _kAlarmChannel.invokeMethod('scheduleShiftAlarm') — handler only registered in MainActivity.configureFlutterEngine (main UI engine). Background isolate has only plugin's own channels (verified in flutter_background_service_android-6.3.1 BackgroundService.java:212 — channel "id.flutter/background_service_android_bg"). Call from worker throws MissingPluginException → caught → "Native alarm skipped". Only inexact Workmanager armed next shift.
  implication: next-day native alarm never armed after first fire → "haphazard". Fixed → native self-rearm in receiver.
- timestamp: 2026-08-01T15:22:00Z
  checked: BootReceiver.kt dateStringToMillis
  found: Dart writes _kPrefNextShiftStart = local DateTime.now().add(delay).toIso8601String() — LOCAL time, no Z. BootReceiver parsed as UTC → alarm epoch shifted by device offset (IST +5:30 → 5.5h late after reboot).
  implication: reboot path wrong absolute time. Fixed → parse with TimeZone.getDefault().
- timestamp: 2026-08-01T16:12:00Z
  checked: emulator after fixes — install, run-as broadcast to receiver
  found: ALARM_FIRED → startForegroundService → flag written → "Self re-armed next shift alarm for Sun Aug 02 10:00:00 GMT+05:30 2026"; dumpsys alarm shows RTC_WAKEUP *walarm* tag, exactAllowReason=policy_permission, device_idle=-- (not deferred in Doze), origWhen=2026-08-02 10:00:00
  implication: all three fixes verified on device.
- timestamp: 2026-08-01T16:15:00Z
  checked: flutter analyze (124 issues baseline, 0 errors) + flutter test (+90 -13 baseline)
  found: no regressions
  implication: safe to ship after real-device soak test

## Resolution
root_cause: (1) setExact deferred during Doze → late fires; (2) native AlarmManager alarm was never re-armed from the background isolate because the app's MethodChannel only exists on the main engine — after the first alarm fired, subsequent days relied on inexact Workmanager; (3) BootReceiver parsed Dart's local-time ISO string as UTC, shifting the reboot-rescheduled alarm by the device's UTC offset.
fix: (uncommitted)
  - GeofenceAlarmReceiver.kt: setExact → setExactAndAllowWhileIdle (fires in Doze); added scheduleNextShiftAlarmFromPrefs() — receiver self re-arms next shift from persisted start time on every fire, no Dart needed
  - BootReceiver.kt: dateStringToMillis parses in TimeZone.getDefault() instead of UTC
  - geofence_scheduler.dart: persist 'gf_cached_shift_start_time' = shift.startTime for native re-arm
verification: emulator logcat confirms self re-arm + Doze-exempt alarm; analyze/test baselines unchanged. NOT COMMITTED.
files_changed: [android/.../GeofenceAlarmReceiver.kt, android/.../BootReceiver.kt, lib/features/punch/services/geofence_scheduler.dart]
