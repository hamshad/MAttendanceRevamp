---
status: resolved
trigger: "punch IN at 61m (radius 20m), punch OUT at 149m 10-15min after leaving; OUT still bad after option-A stream"
created: 2026-08-13
updated: 2026-08-13
---

## Current Focus
hypothesis: (1) movement-gated stream scoped to aggressive OEMs only → Nothing 3a never runs it → OUT falls back to containment alarm (15-min, 149m). (2) IN acceptance band margin = 2x accuracy (clamp 10-250) too loose for 20m radius → 61m IN accepted. CONFIRMED via user answers (Nothing 3a, no Geofence Active notification, build d30af62).
test: (done) code read: _verifyTransition IN (radius+margin), reconcile IN (_lastKnownOrFreshFix reuse <10min + same margin), OemKeepAliveService.startIfNeeded aggressive gate, ContainmentAlarmReceiver aggressive-only revival
expecting: universal monitor + IN margin cap fix
next_action: implement fixes

## Symptoms
expected: IN records inside/near boundary (<20m-ish), OUT punches near boundary shortly after leaving
actual: IN punched at 61m (radius 20m); OUT at 149m, 10-15 min late
errors: (none)
reproduction: Nothing 3a, geofence auto enabled, punch in at office, leave
started: OUT issue = since option-A stream (8b6329e) scoped to aggressive only; IN issue = pre-existing margin model

## Eliminated
- (none yet)

## Evidence
- timestamp: 2026-08-13
  checked: user device answers
  found: Nothing 3a (NOT in aggressive list), no "Geofence Active" notification, build d30af62
  implication: keep-alive FGS + movement stream never started → OUT via containment alarm 15-min cadence at 149m; confirms hypothesis 1
- timestamp: 2026-08-13
  checked: _verifyTransition IN + reconcile IN + _gpsMargin
  found: margin = (accuracy*2).clamp(10,250); radius 20 + acc 30 → accepts <=80m; 61m passes; reconcile reuses OS last-known <10min old
  implication: 61m IN accepted by over-generous band; confirms hypothesis 2

## Resolution
root_cause: (1) movement-gated stream scoped to aggressive OEMs only — Nothing 3a never ran it, so OUT came from the 15-min containment alarm at 149m. (2) IN acceptance margin = 2x accuracy (clamp 10-250) too loose for 20m radius — 61m IN accepted (radius 20 + acc ~30 → band 80m)
fix: (1) keep-alive FGS + stream now universal while punched in: Dart startIfNeeded punch-in gate for non-aggressive (aggressive unchanged, always-start); native ContainmentAlarmReceiver + BootReceiver revive keep-alive when !serviceRequired && (aggressive || punched-in). (2) IN margin capped at min(2xaccuracy, radius) in BOTH _verifyTransition IN + reconcile IN; OS-crossing trigger-loc rescue (<= radius+50) preserved.
verification: 3 new tests (61m rejected, 35m accepted, crossing rescue) + full suite 162/162; analyze clean; debug APK builds; doc + AGENTS invariants updated
files_changed: [lib/features/punch/services/oem_keep_alive_service.dart, lib/features/punch/services/geofence_monitor.dart, android/.../ContainmentAlarmReceiver.kt, android/.../BootReceiver.kt, test/features/punch/services/geofence_monitor_test.dart]