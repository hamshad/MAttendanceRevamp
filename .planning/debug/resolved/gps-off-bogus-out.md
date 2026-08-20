---
status: resolved
trigger: "GPS off → punched OUT inside India office, attributed to UAE office; GPS back on → no IN"
created: 2026-08-10T00:00:00Z
updated: 2026-08-10T00:00:00Z
---

## Current Focus
hypothesis: ROOT CAUSE FOUND — GPS-off provider drop fires batch EXIT for ALL fences; OUT path trusted far trigger point + far fresh fix → punched "OUT of UAE" (first fence in loop) though user in India. Fixed: location gate + zone gate + resume reconcile
test: +6 monitor tests, full suite 105/105
expecting: GPS-off never punches; wrong-fence exits rejected
next_action: done — commit pending

## Symptoms
expected: GPS toggle off must never punch; re-enable restores IN when inside office
actual: GPS off inside India → punched OUT "of UAE office" (wrong of 3); GPS back on → no IN
errors: none
reproduction: punch IN India (geofence) → toggle GPS off → batch exit → OUT attributed UAE; GPS on → stays OUT
started: after a72a853 OUT-crossing + 925cf6e poll

## Eliminated
- hypothesis: deferred ENTER (same as geo-in-bg-not-firing) — rejected: different mechanism — spurious EXIT batch; ENTER covered by 925cf6e
  timestamp: 2026-08-10

## Evidence
- 2026-08-10 user report: GPS off inside India → OUT "UAE"; GPS on → no IN
- 2026-08-10 _verifyTransition: OUT short-circuit accepted trigDist > radius at ANY magnitude; fresh-fix fallback required fix strictly outside radius (India user far from UAE center → also "verified"); no zone-identity check → wrong-office punch mechanical
  found: plugin Location has NO timestamp → proximity/identity guards, not staleness
- 2026-08-10 fix: (1) _verifyTransition + reconcileContainment gate on Geolocator.isLocationServiceEnabled (fail-open); (2) OUT crossing short-circuit requires trigDist ≤ radius+250m; (3) OUT zone-identity gate — only fence user is punched into (`gf_last_punch_zone_id`, persisted on IN) may punch OUT; (4) app-resume reconcileContainment in main_shell
  implication: GPS-off → no punches; wrong-fence exits rejected; GPS-back-on recovers IN via 15s poll or resume

## Resolution
root_cause: GPS off → Android/OEM fires batch GEOFENCE_EXIT for every registered fence (India, UAE, NZ). OUT processing (a72a853 short-circuit) trusts any trigger point beyond radius; UAE fired first → trigDist India→UAE thousands km "verified" as exit → punched OUT attributed UAE. Fresh-fix fallback same flaw (India fix far from UAE center = "outside"). GPS re-enable → no boundary crossing → no ENTER → no IN.
fix: location-service gate (fail-open) in _verifyTransition + reconcileContainment; OUT crossing tolerance 250m beyond radius; OUT zone-identity gate via persisted gf_last_punch_zone_id; resume reconcile in main_shell
verification: +6 tests (GPS-off enter/exit/reconcile no-punch; wrong-fence exit rejected; punched-in-zone exit still punches; far trigger falls to fix check); monitor 38/38, full suite 105/105, analyze 0 errors
files_changed: [lib/features/punch/services/geofence_monitor.dart, lib/features/shell/main_shell.dart, test/features/punch/services/geofence_monitor_test.dart]