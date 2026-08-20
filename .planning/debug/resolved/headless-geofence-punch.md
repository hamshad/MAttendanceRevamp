---
status: resolved
trigger: "user: fresh install, geofence enabled, NO bg service, app killed → punched IN accurately at office radius + notification. How? Make consistent across OEMs (Android only)."
created: 2026-08-10T00:00:00Z
updated: 2026-08-10T00:00:00Z
---

## Current Focus
hypothesis: CONFIRMED — OS-native layer is self-sufficient: GeofencingClient geofences persist after app kill; transition → manifest BroadcastReceiver (always alive) → expedited WorkManager → headless Dart engine → geofenceTriggered → punch + notification. Our flutter_background_service is a resilience layer, not a requirement.
test: mechanism verified in plugin source; hardened resume re-register
expecting: no-service punch works on any OEM that doesn't force-stop / ban WorkManager
next_action: done — commit pending

## Symptoms
expected: auto punch with app killed + no service = desired consistent behavior
actual: worked on user's device (phenomenal); needs consistency across OEMs
errors: none

## Eliminated
- "service needed" hypothesis — plugin BroadcastReceiver + WorkManager headless proven independent of our fg service
  evidence: NativeGeofenceBroadcastReceiver.kt → OneTimeWorkRequest (expedited, RUN_AS_NON_EXPEDITED fallback) → NativeGeofenceBackgroundWorker → Dart callback handle → geofenceTriggered
  timestamp: 2026-08-10

## Evidence
- 2026-08-10 plugin receiver: transition intent → GeofencingEvent parse (error/transition/triggeringGeofences/triggeringLocation) → expedited WorkManager enqueue (APPEND unique work = sequential)
- 2026-08-10 reboot receiver: reCreateAfterReboot() re-registers persisted geofences (manifest-registered ✓)
- 2026-08-10 callback handle: stored at createGeofence time; refreshed by every registerZones (app start / toggle). Stale-handle risk if app updated without ever opening → resume re-register covers
- 2026-08-10 gap: main_shell resume never re-registered geofences (initState-only) → OEM memory cleanups / dropped registrations stayed dropped until next cold start
  implication: resume re-register = self-healing + handle refresh + enter catch-up (initialTriggers) for zones user already inside

## Resolution
root_cause: no bug — headless path inherently works; consistency gap: no resume-time re-registration self-healing
fix: main_shell didChangeAppLifecycleState(resumed) → if GeofenceMonitor.isEnabled → registerZones (idempotent, self-gating; refreshes callback handle + re-arms enter catch-up)
verification: analyze clean (pre-existing infos), full suite 110/110
files_changed: [lib/features/shell/main_shell.dart]