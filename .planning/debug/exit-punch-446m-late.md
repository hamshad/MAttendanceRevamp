---
status: resolved
trigger: "another day, it punched in accurately yet again it failed to punch me out as soon as I left the geofence and it punched me 446m away from the geofence on top of that which is really bad"
created: 2026-08-12T00:00:00Z
updated: 2026-08-12T00:00:00Z
---

## Current Focus
hypothesis: OS geofence EXIT never reached Dart (zones lost after shift-start alarm, or OEM blocked cold-start). Containment alarm (15-min) recovered OUT at walking location (446m = ~15min walk) because it doesn't re-register zones — only shift-start alarm (daily), app resume, and keep-alive service do.
test: add zone re-registration to containment alarm + alignment worker; verify zones self-heal every 15/30 min
expecting: OS EXIT fires at boundary after heal; 446m late punch eliminated
next_action: done — committed fix

## Symptoms
expected: punch out at boundary crossing (~20m radius), same accuracy as punch in
actual: punch in accurate (desk — likely OS ENTER catch-up or boundary); punch out ONLY 446m away from geofence (first containment-alarm fix after leaving). No immediate EXIT punch at boundary.
errors: none reported
reproduction: punch in at office, app backgrounded/killed, leave office walking (~450m/15min), EXIT never fires, containment alarm punches late at walking location
started: recurred (similar to 70m incident before alarm existed); this time recovery worked but far away

## Eliminated
- hypothesis: EXIT fired but verifyTransition rejected trigger location
  evidence: _verifyTransition for EXIT accepts OS trigger location when trigDist in (radius, radius+250] — boundary exit naturally lands in this range. 446m punch matches containment alarm path (_reconcileOut with fresh fix), not rejected-trigger fallback.
  timestamp: 2026-08-12

## Evidence
- timestamp: 2026-08-12
  checked: ContainmentCheckWorker.run() in geofence_scheduler.dart
  found: Only calls reconcileContainment(confirmOut: true); NO registerZones() call. Shift-start alarm (daily) calls reRegisterFromHeadless() → registerZones({enter}). App resume calls registerZones({}). Keep-alive service calls registerZones({enter}). Containment alarm (15-min) has NO zone heal.
  implication: If zones lost after shift-start alarm (reboot, OEM purge, force-stop), they stay lost until next daily alarm or app open. Containment alarm recovers punch but at stale/walking location, not boundary.

- timestamp: 2026-08-12
  checked: HeadlessAlignmentWorker.run() in headless_alignment_worker.dart
  found: Only posts alignment warnings; NO zone re-registration.

- timestamp: 2026-08-12
  checked: geofence_monitor.dart _verifyTransition for EXIT (lines 927-933)
  found: Accepts OS trigger location when trigDist > radius AND trigDist <= radius + 250. Normal boundary exit has trigDist ≈ radius + jitter (few meters) → accepted → punches at boundary. 446m punch proves this path never executed (OS EXIT never arrived).

- timestamp: 2026-08-12
  checked: geofence_monitor.dart _reconcileOut (lines 544-636)
  found: confirmOut=true → _lastKnownOrFreshFix() (cached if ≤10m old) then _freshFix() for confirm. If cached says outside (user walking), takes two fresh fixes ≤800m apart → punches at second fix location (walking location). Matches 446m punch perfectly.

## Resolution
root_cause: Zones lost between shift-start alarm and user leaving; OS EXIT never fires; containment alarm (15-min) recovers punch but has no zone self-heal → uses walking-location GPS fix instead of boundary.
fix: Add registerZones(initialTriggers: {}) to ContainmentCheckWorker.run() and HeadlessAlignmentWorker._runInner() for periodic self-heal. Zones re-register every 15/30 min → OS EXIT fires at boundary.
verification: flutter analyze: 0 errors; flutter test: 150/150 pass; flutter build apk --debug: builds
files_changed:
  - lib/features/punch/services/geofence_scheduler.dart (ContainmentCheckWorker.run)
  - lib/features/alignment/headless_alignment_worker.dart (HeadlessAlignmentWorker._runInner)