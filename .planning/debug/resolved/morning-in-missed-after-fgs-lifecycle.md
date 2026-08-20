---
status: resolved
trigger: "morning auto-geofence IN missed after FGS punch-state lifecycle change (8787c56 installed end of yesterday's shift)"
created: 2026-08-14
updated: 2026-08-14
---

## Current Focus

hypothesis: dead containment chain (armed flag cleared on OUT punch by 8787c56's _persistPunchState) left the missed-ENTER net off while OUT + shift window; ENTER delivery gap thus unhit on 2026-08-14 morning
test: code audit (diff + arming model); fixed in 82f2d0a — armed = master enable, chain self-perpetuates while (In OR window), shift-start re-arm, FGS work-hours gate restored
expecting: field-verify next morning (IN punches as before; banner only during work hours)
next_action: user field test next workday; if still missed, instrument geofence_debug_bus + logcat

## Symptoms

expected: auto punch IN on arrival (works for weeks, incl. 12h+ dead-process ENTER)
actual: no auto IN punch 2026-08-14 morning — first occurrence after installing 8787c56 (FGS punched-IN-only lifecycle) at end of previous shift
errors: unknown (notification evidence not confirmed)
reproduction: arrive at office with app closed, process dead
started: 2026-08-14 morning

## Eliminated

- hypothesis: punch path code regression (gates/band/server-truth order) — DIFF REVIEW: 8787c56 touched only `_persistPunchState` FGS start/stop calls AFTER POST; punch gates `_verifyTransition`/`PunchCoordinator`/zone-identity unchanged
- hypothesis: plugin dead-process ENTER delivery broken — PLUGIN SOURCE: receiver → WorkManager expedited worker → engine → `geofenceTriggered`; unchanged
- hypothesis: server-side rejection — no notification evidence; server record unconfirmed (user said "idk anymore", abandoned evidence gathering)

## Evidence

- timestamp: 2026-08-14
  checked: 8787c56 diff — geofence_monitor +14 lines (FGS lifecycle only)
  found: `_persistPunchState` sets `gf_containment_alarm_armed = (type == 'In')` — OUT punch CLEARS the flag while `stillNeeded` (Kotlin) requires it AND (In OR window)
  implication: the 15-min containment chain dies on OUT punch even though the missed-ENTER net (punched OUT but within shift window) is the documented use-case — chain dead = ENTER delivery gap has NO net; an OS-delayed ENTER (2-6 min per Android docs, or never while background-limited) goes unhit → morning IN miss. CONFIRMED root cause candidate
- timestamp: 2026-08-14
  checked: Android docs + production apps research (geofencing + FGS + WorkManager patterns)
  found: geofence events 2-6 min latency when backgrounded/Doze; Play policy bans FGS solely-for-geofencing (2026-10) — our FGS runs a real location stream (walk-out), compliant-ish
  implication: layered design (native geofence primary, FGS stream, 15-min net, shift-start bootstrap) is the industry pattern — keep, fix the gate contradiction
- timestamp: 2026-08-14
  checked: IN gate `_verifyTransition` cold-GPS behavior
  found: fresh fix confirms → else OS crossing location within radius+50m falls back → punch; location-service-off defers to reconcile
  implication: IN not gated by GPS freshness — NOT the failure cause

## Resolution

root_cause: `_persistPunchState` cleared `gf_containment_alarm_armed` on OUT punch (8787c56) while the native receiver's `stillNeeded` = armed && (In OR withinShiftWindow) — chain dead precisely when punched OUT + in-shift (missed-ENTER net unreachable). Compounded by FGS gate narrowed to punched-IN only (no window wake).
fix: 82f2d0a — armed = MASTER ENABLE (geofence auto on; written from _persistPunchState, lifted every shift start by GeofenceAlarmReceiver while geofence_auto_enabled, cleared on disable/logout); stillNeeded self-perpetuates while (In OR window); keepAliveActive = armed && (In OR window); Dart FGS gate restored to (In OR withinShiftWindow) with _withinShiftWindow helper; OUT punch keeps idle FGS through work hours, receiver closes at first post-window fire; leave days: no shift alarm → no chain, no banner
verification: 173/173 tests (updated armed-flag test to master-enable semantics), flutter analyze 0 errors, debug APK builds. Field test pending next workday.
files_changed: lib/features/punch/services/oem_keep_alive_service.dart, lib/features/punch/services/geofence_monitor.dart, test/features/punch/services/geofence_monitor_test.dart, android/.../ContainmentAlarmReceiver.kt, android/.../GeofenceAlarmReceiver.kt, AGENTS.md, .planning/docs/native-first-geofence-architecture.md
