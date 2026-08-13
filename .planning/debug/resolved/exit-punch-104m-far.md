---
status: resolved
trigger: "ok, it still punched me out after 104m away? thats still too far when the office radius is 20m radius only"
created: 2026-08-12T00:00:00Z
updated: 2026-08-12T00:00:00Z
---

## Current Focus
next_action: done — snap fix committed e6ce478

## Symptoms
expected: punch-out location ~boundary (20m radius office)
actual: punch-out recorded 104m from office center, even after zone self-heal fix (68ce662). OS EXIT now fires (zones healed) but detection point itself is far.
errors: none
reproduction: leave office walking; OS geofence EXIT detected late (background sampling throttled by Doze/battery saver); trigger location = detection point (~104m), accepted within radius+250 tolerance, punched there
started: every backgrounded exit; distance = detection lag × walking speed

## Eliminated
- hypothesis: punch came from containment-alarm fresh-fix path (like the 446m case)
  evidence: 104m ≈ 1-2 min walk — too fast for the 15-min alarm cadence unless coincidental. OS EXIT path accepts any trigger within radius+250m, so a late-detected crossing at 104m punches there directly. Either path funnels through _executePunch, so the snap fix covers both regardless.
  timestamp: 2026-08-12

## Evidence
- timestamp: 2026-08-12
  checked: _verifyTransition OUT acceptance band (geofence_monitor.dart)
  found: trigger location accepted when trigDist in (radius, radius+250]; punched at that raw point. For 20m radius, a 104m detection point is accepted and recorded — no boundary check on the recorded location.
  implication: recorded punch-out distance = OS detection lag, not real crossing.

- timestamp: 2026-08-12
  checked: existing test 'exit with OS crossing location → punch AT crossing' (133m for 100m radius)
  found: design explicitly punches at the crossing point, which is the detection point — that IS the 104m behavior at smaller radii.
  implication: snap to boundary circle needed at the punch-location step.

- timestamp: 2026-08-12
  checked: geolocator 13.0.2 API
  found: no destinationOffset/LatLng helpers — computed snapped point manually via haversine.
  implication: pure function, unit-testable.

## Resolution
root_cause: OS geofence EXIT detection runs late in background (throttled sampling); recorded punch-out location = raw detection point, which can be far past the boundary (104m on 20m radius).
fix: GeofencePunchHandler.snapOutToBoundary(zone, fix) — snaps OUT punch location to the boundary circle (radius distance along office→fix bearing). Applied in shared _executePunch (OS-exit path + containment-alarm path + offline queue). IN never snaps.
verification: analyze 0 errors; 154/154 tests (+4 snap unit tests, crossing test updated to expect boundary snap); debug APK builds. Commit e6ce478.
files_changed:
  - lib/features/punch/services/geofence_monitor.dart (snapOutToBoundary + _executePunch)
  - test/features/punch/services/geofence_monitor_test.dart
