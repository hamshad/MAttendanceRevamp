---
status: verifying
trigger: "Self-arm exit fix — track so no regression on working devices (Nothing) while fixing Samsung no-exit"
created: 2026-08-07
updated: 2026-08-07
---

## Current Focus

hypothesis: Self-arm in `_checkExit` arms exit monitoring from punched-IN state when entry scan was skipped — strictly additive, no-op on healthy-GPS devices.
test: New regression test "punches OUT via self-arm when punched IN but entry scan was skipped (poor GPS)" + full worker suite.
expecting: Test passes; worker suite back to baseline +43 -3 (3 pre-existing failures only).
next_action: Confirm full suite green, decide commit (with other 4 Samsung fix files).

## Symptoms

expected: Samsung (blurry GPS 20–60m) punches OUT when leaving office, even if entry scan was skipped by confidence gate.
actual: Exit tracking only armed inside `_checkEntry` (line 481), which is confidence-gated (line 320, threshold 0.6). Blurry-GPS fix can skip entry → `_isInsideGeofence` stays false → `_checkExit` line 526-529 skip → no punch OUT ever.
errors: none (silent no-op).
reproduction: Punched IN, low-confidence fixes near zone, walk away → no OUT.
started: Always broken for low-confidence devices; confidence-gate fix (0.6/80m) reduced but did not eliminate (manual punch-in + skipped entry still disarmed).

## Eliminated

- hypothesis: Self-arm could double-arm or punch OUT while user still inside zone
  evidence: Self-arm only sets `_isInsideGeofence=true`; the existing zone-scan after it (line 583: `nearestDist <= nearest.radius` → no exit; line 587 margin → no exit) still guards OUT. Test asserts `didPunchOut == false` after 4 inside fixes.
  timestamp: 2026-08-07

## Evidence

- timestamp: 2026-08-07
  checked: `geofence_background_worker.dart` `_checkExit` (lines 496-530)
  found: Original guard returned early whenever `!_isInsideGeofence && _pendingZone == null` — exit permanently disarmed if entry never ran.
  implication: Blurry-GPS devices with manual punch-in had no exit path.

- timestamp: 2026-08-07
  checked: `_checkEntry` (lines 426-494)
  found: Arms `_isInsideGeofence=true` at line 481 whenever fix inside zone (confidence-gated at line 320). Punched-IN users near zone already handled at line 489.
  implication: On Nothing (healthy GPS) entry always runs and arms first → self-arm guard skipped → **no-op, behavior unchanged**. Self-arm only reachable when entry skipped = exactly the Samsung case.

- timestamp: 2026-08-07
  checked: `onLocationFix` gate flow (lines 317-339)
  found: Only entry check is confidence-gated (line 320). Exit path (`_checkExit`) runs on every fix regardless of confidence.
  implication: Self-arm in `_checkExit` works even when all fixes are low-confidence (Samsung scenario).

- timestamp: 2026-08-07
  checked: Full worker test suite
  found: +43 passed / 3 failed. 3 failures are pre-existing baseline (Duplicate/recorded, shift-hours blocks IN, no-shifts) — confirmed unchanged. New self-arm regression test passes.
  implication: No new failures. Working-device behavior preserved.

## Resolution

root_cause: Exit tracking only armed via confidence-gated `_checkEntry`; low-confidence (blurry GPS) devices never armed → no punch OUT even when punched IN and leaving.
fix: In `_checkExit`, when `!_isInsideGeofence && _pendingZone == null` and `_lastPunchType == 'In'`, scan zones; if any zone within `radius + gpsMargin`, self-arm: `_isInsideGeofence = true`, `_consecutiveInsideFixes = 0`, `_pendingOutConfirm = false`, `_exitAnalyzer.reset()`.
verification: New regression test passes (self-arm → exit tracking → OUT; no premature OUT while inside). Worker suite at baseline +43 -3. On Nothing entry arms first → self-arm is no-op.
files_changed:
- lib/features/punch/services/geofence_background_worker.dart (self-arm block, ~34 lines)
- test/features/punch/services/geofence_background_worker_test.dart (new regression test)
