---
status: verifying
trigger: "User: 15-min IN unacceptable — IN must punch at point on return. IN worked flawlessly in background on Nothing before (21m, 3-4 min). Why would 15 min be OK?"
created: 2026-08-14T00:00:00Z
updated: 2026-08-14T00:00:00Z
---

## Current Focus
hypothesis: at-point IN was lost with 8787c56 (FGS punched-IN-only → stream dies on OUT). Aug-8 flawless IN came from the 82f2d0a-era FGS that stayed alive after OUT within the shift window — its movement-gated stream caught the walk-in and reconciled IN at ~21m. Nothing's OS ENTER is unreliable (premise falsified) → headless-only IN = the 15-min net → unacceptable primary.
test: implemented — FGS kept/started through shift window after OUT (smart stop gate), stream dual-mode (walk-out + return-IN), post-shift-end close. analyze 0 errors, 183/183 tests.
expecting: IN at point on return (first fix inside radius+5, ~21-25m), banner still off outside work hours
next_action: field test on Nothing 3a (IN punch manual or headless → OUT → walk back in → expect IN within ~1-3 min; verify banner gone after shift end)

## Symptoms
expected: IN at point on return (as it was on the Nothing before)
actual: no IN until app open; my f5a53dd capped recovery at ≤15 min (user: not OK)
errors: none
reproduction: Nothing 3a — punch IN → leave → OUT → return inside radius → expect IN within a minute or two
started: 8787c56 (Aug 14) — FGS punched-IN-only killed the after-OUT stream

## Eliminated
- hypothesis: OS ENTER can be made reliable at point on the Nothing from app code
  evidence: geofence delivery is Play Services/OEM territory; no app-side force exists; the Aug-8 at-point IN predates punch-only gating (FGS stream era)
  timestamp: 2026-08-14

## Evidence
- timestamp: 2026-08-14
  checked: 8787c56 doc entry
  found: FGS gate changed from "In OR shift window" (82f2d0a) to punched-IN only; OUT punch stops the FGS → back to headless IN (OS ENTER + 15-min net)
  implication: the after-OUT stream that gave Aug-8 at-point IN was removed this morning
- timestamp: 2026-08-14
  checked: keep-alive entrypoint stream (field_tracking_service.dart 292-342)
  found: stream setup gated on punched-'In' at service start; punched-OUT → stream cancelled permanently (line 314-317); no IN monitoring exists in keep-alive mode
  implication: even a live FGS cannot catch the return — the IN-side of the stream was never implemented (OUT-only design)
- timestamp: 2026-08-14
  checked: stop() semantics (e624167)
  found: made unconditional (removed the work-hours smart-stop from 82f2d0a/10197aa)
  implication: OUT → FGS stops unconditionally today; smart gate must return (shift-window aware) for at-point IN
- timestamp: 2026-08-14
  checked: shift-end availability headless
  found: `gf_shift_end_time` pref persisted by scheduleNextShift (main isolate); isPastShiftEnd() pattern exists in GeofenceScheduler — readable from any isolate; stale/absent end = past (fail-safe for banner-off)
  implication: smart stop gate + post-shift FGS close are implementable headless without the (removed) leave-day marker
- timestamp: 2026-08-14
  checked: reconcile IN path from the stream
  found: reconcileContainment punched-OUT branch: dist <= radius+5 (25m @ 20m office), no accuracy gate, fresh stream fix is honest — punches at real walking location (matches Aug-8 21m IN)
  implication: stream-driven IN = at point; headless ENTER duplicate → silent own-source echo
- timestamp: 2026-08-14
  checked: banner invariant
  found: user design — no banner outside work. After-OUT-within-window = workday hours (user accepted this in the 82f2d0a era — no complaint about lunch-hour banner). Post-window close needed: stream fix check + containment worker check
  implication: restore "In OR within shift window" gating; stop at first fix/check past shift end
- timestamp: 2026-08-14
  checked: fix implemented (commit pending)
  found: `startIfNeeded` banner gate = (In OR within window); `_persistPunchState` OUT → smart `stop()` keeps AND (re)starts the FGS within window (headless-OUT case included), closes past window; keep-alive stream dual-mode: walk-out monitor (In) + return-IN monitor (Out — `isInsideAnyOffice` radius+5m band → `reconcileContainment()`), 60s cooldown, edge-gated; past `gf_shift_end_time` (stale/absent = past) → cancel stream + clear mode flag + stopSelf. Takeover/disable/logout → `stop(force:true)`. OS ENTER + 15-min catch-up net (f5a53dd) stay as dead-process backup
  implication: at-point IN restored; banner invariant preserved (work-hours gate)
- timestamp: 2026-08-14
  checked: tests + analyze
  found: 10 new unit tests (`isInsideAnyOffice` IN-band/accuracy, `shouldKeepAliveAfterOut` gates) — 183/183 pass; flutter analyze 0 errors
  implication: unit-level behavior locked; field verification remains (Nothing 3a)

## Resolution
root_cause: 8787c56 restricted the keep-alive FGS to punched-IN only; the after-OUT movement stream that delivered the Aug-8 at-point IN (21m, 3-4 min, background) was removed. On the Nothing (OEM-dropped headless OS ENTER), headless-only IN degraded to the 15-min containment net — user rejected as primary.
fix: work-hours gate restored (In OR within shift window): OUT keeps/starts the FGS; stream gains the return-IN monitor (isInsideAnyOffice radius+5m → reconcileContainment) → IN at point; first fix/check past gf_shift_end_time closes the FGS (no banner outside work). Commit: 18f3e45.
verification: flutter analyze 0 errors; 183/183 unit tests (10 new). FIELD TEST PENDING on Nothing 3a: IN → OUT → walk back in → expect IN ≤ ~3 min; banner off after shift end.
files_changed: lib/features/punch/services/oem_keep_alive_service.dart, lib/features/tracking/services/field_tracking_service.dart, lib/features/punch/services/geofence_monitor.dart (comment), test/features/tracking/services/keep_alive_monitor_test.dart, AGENTS.md, .planning/docs/native-first-geofence-architecture.md
