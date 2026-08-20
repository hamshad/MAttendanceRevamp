---
status: resolved
trigger: "field tracking is active but there is no pinging going on, on the connected emulator run the app and see if the consistent ping is occurring while field tracking is active"
created: 2026-08-19T00:00:00
updated: 2026-08-19T17:10:00
---

## Current Focus
hypothesis: CONFIRMED — _initFieldTracking early-return leaves field_tracking_enabled unset when service already running → ping timer never fires
test: instrumented timer ticks + server pingCount tracking
expecting: verified — NUMERIC
next_action: DONE — committed c4461c8

## Symptoms
expected: consistent location pings (POST /api/v1/tracking/ping) while field tracking active
actual: no pings occurring — UI showed "Tracking Active" (service running) but zero pings on server
errors: MapController "FlutterMap widget rendered at least once" crashes on My Field Tracking screen (secondary UI bug at my_field_tracking_screen.dart:246/255 — unrelated to pings, NOT fixed here)
reproduction: launch app while background service already running (geofence/wifi started it first) + user already punched in → flag never set → no pings
started: any session where service was up before _initFieldTracking ran (reopen mid-shift, stale process)

## Eliminated
- hypothesis: GPS fixes not arriving on emulator — evidence: RAW GPS fixes flowed continuously (5s cadence, acc ~5m) once service ran combined mode
- hypothesis: ping timer dead — evidence: instrumented ticks fired every 5 min with all gates passing
- hypothesis: movement-ping teleport bug — evidence: LocationFilter jumpScore>0.8 discards emulator teleports BY DESIGN (anti-fake); gradual movement >100m between ticks still pings
- hypothesis: heartbeat cadence broken — evidence: 16:52:57 tick was 29m59.9s after last ping → inMinutes=29 <30 → legitimate silent skip (timer phase); next tick ≥30 min pings

## Evidence
- stale emulator prefs had NO field_tracking_enabled while service was running + UI showed "Tracking Active" — the exact broken state
- setting the flag (fresh install + SHELL punch-IN transition) made heartbeat pings land on server: pingCount 1→2→3, lastPingAt updated (10:14:32Z, 10:52:52Z)
- _initFieldTracking (main_shell.dart:442 old): `if (alreadyRunning) return;` → only code path setting the flag (_startFieldTracking at line 477) unreachable when service up
- initState order: _initGeofence/_initWifiAuto run BEFORE _initFieldTracking (postFrameCallback) — they can start the service first
- ping gate (field_tracking_service.dart:1040): `if (!ftEnabled) return;` — confirmed flag is master switch

## Resolution
root_cause: _initFieldTracking early-returned when background service already running → field_tracking_enabled never set → 5-min ping timer silently gated off forever, while UI "Tracking Active" (derived from service running, not the flag) misled the user. Triggered by app launch/reopen with service up (geofence/wifi paths start it before field-tracking init runs) and no fresh punch-IN transition.
fix: main_shell.dart _initFieldTracking already-running branch now sets field_tracking_enabled=true when punched in + tracking permitted; if running isolate is keep-alive mode (no ping timer), OemKeepAliveService.stop() + FieldTrackingService.start() upgrades to full combined service.
verification: pinned heartbeats land on server (pingCount 1→2→3); 30-min skip at 16:52:57 proven legitimate phase timing; flutter analyze 0 errors; flutter test 180/180 pass
files_changed: [main_shell.dart]