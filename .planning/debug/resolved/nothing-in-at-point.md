---
status: resolved
trigger: "User: 15-min IN unacceptable — IN must punch at point on return. IN worked flawlessly in background on Nothing before (21m, 3-4 min). Why would 15 min be OK?"
created: 2026-08-14T00:00:00Z
updated: 2026-08-14T00:00:00Z
---

## Current Focus
hypothesis: (FALSIFIED by user) at-point IN was lost with 8787c56 (FGS punched-IN-only → stream dies on OUT).
user's correction: the FGS never carried IN — IN was ALWAYS the headless OS ENTER path (straightforward, accurate, dead-process safe); only OUT was ever slow (late OS EXIT + fix acquisition). The 61m IN was one-off fused-fix artifact, acceptable. The stream-return-IN idea was MY misattribution of the Aug-8 21m IN to the FGS.
outcome: 18f3e45 (stream return-IN + FGS-through-window) REVERTED — 835c2a7. IN stays headless; FGS = walk-out monitor only. Kept f5a53dd (catch-up ENTER net + Nothing exact alarm — zero battery). Tests 183→173, analyze 0 errors.
next_action: field test on Nothing — IN headless at crossing, OUT ~1 min at 45-70m; if the missed-IN repeats, logcat the geofence broadcast → worker → gate chain (do NOT add machinery without evidence)

## Symptoms
expected: IN at point on return (as it was on the Nothing before)
actual: no IN until app open; my f5a53dd capped recovery at ≤15 min (user: not OK)
errors: none
reproduction: Nothing 3a — punch IN → leave → OUT → return inside radius → expect IN within a minute or two
started: 8787c56 (Aug 14) — FGS punched-IN-only killed the after-OUT stream (MY hypothesis — falsified)

## Eliminated
- hypothesis: OS ENTER can be made reliable at point on the Nothing from app code
  evidence: geofence delivery is Play Services/OEM territory; no app-side force exists
  timestamp: 2026-08-14
- hypothesis: at-point IN was delivered by the FGS movement stream (Aug-8 21m IN = stream-era)
  evidence: USER CORRECTION — IN was always headless OS ENTER; the FGS only ever accelerated OUT. Falsified 2026-08-14; 18f3e45 reverted (835c2a7).
  timestamp: 2026-08-14
- hypothesis: the anti-fake OUT/IN layers can be stripped when the user is on mobile data (wifi-jump premise)
  evidence: Android fused locations blend wifi/cell into fixes regardless of transport; geolocator exposes no provider; layers are the only defense and cost honest users nothing. Rejected as a spec direction.
  timestamp: 2026-08-14

## Evidence
- timestamp: 2026-08-14
  checked: 8787c56 doc entry
  found: FGS gate = punched-IN only; OUT stops the FGS
  implication: (mine) the after-OUT stream was removed — WRONG as root cause for slow IN (user: IN never used the stream)
- timestamp: 2026-08-14
  checked: keep-alive entrypoint stream
  found: stream is In-only, OUT-only purpose (isOutsideAllOffices → reconcile OUT)
  implication: confirms stream never had an IN side — consistent with "IN was always headless"
- timestamp: 2026-08-14
  checked: user memory of field behavior (authoritative)
  found: IN always punched headless at crossing, accurate (21m, even 61m acceptable); OUT always late (149m-class); FGS = OUT-accelerator idea
  implication: design target = keep IN headless untouched; FGS In-only as walk-out monitor (ef0ce33-era architecture was correct)
- timestamp: 2026-08-14
  checked: fix source in punch path
  found: _freshFix() = Geolocator high-accuracy = fused (GPS+wifi+cell); Position exposes no provider on Android; getLastKnownPosition can be network-derived (≤10 min reuse)
  implication: cannot filter to pure GPS; anti-fake layers (bands, two-fix, zone identity, accuracy floors) are the only defense — keep all
- timestamp: 2026-08-14
  checked: 18f3e45 reverted (835c2a7)
  found: stop() unconditional, startIfNeeded In-only, stream In-only self-cancelling, plain stop() on takeover; isInsideAnyOffice/shouldKeepAliveAfterOut removed + their tests
  implication: battery back to minimum (FGS only while punched in); IN untouched headless + f5a53dd net; OUT as fast as honesty allows

## Resolution
root_cause: NONE in code for the IN slowness — user correction: IN was always headless-OK; my stream-return-IN was built on a falsified premise (misattributed Aug-8 21m IN to the FGS stream). The one missed-IN day remains an unexplained single data point — logcat test required if it recurs; do not stack machinery without evidence.
fix: revert 18f3e45 → 835c2a7 (IN stays headless; FGS = walk-out monitor only; f5a53dd catch-up ENTER net + Nothing exact alarm kept; layers kept — Android fused fixes expose no provider, wifi/cell jumps are in-band by design).
verification: flutter analyze 0 errors; 173/173 unit tests (pre-18f3e45 baseline restored). FIELD TEST still recommended on Nothing 3a (IN at crossing headless, OUT ≤ ~1 min at 45-70m, banner In-only).
files_changed: lib/features/punch/services/oem_keep_alive_service.dart, lib/features/tracking/services/field_tracking_service.dart, lib/features/punch/services/geofence_monitor.dart, lib/features/punch/services/geofence_scheduler.dart, lib/features/shell/main_shell.dart, test/features/tracking/services/keep_alive_monitor_test.dart, AGENTS.md, .planning/docs/native-first-geofence-architecture.md
