---
status: investigating
trigger: "Real-device field test — Nothing OUT@121m/Samsung no-IN/Xiaomi1 no-OUT@60-80m/Xiaomi2 nothing. Office radius 20m."
created: 2026-08-08
updated: 2026-08-08
---

## Current Focus

hypothesis: Root cause = margin `2×acc` (cap 250m) inflates exit zone to 60-120m for typical indoor GPS (20-60m) on a 20m radius; confidence gate (0.6 @ 80m max) still blocks entry when acc > 64m. Xiaomi 2 likely background-kill / fixes dropped — needs device logs.
test: Math reproduced all four device behaviors against current code (see Evidence).
expecting: Confirmed mechanism; plan for tunable margins + confidence alignment + punch-time telemetry.
next_action: Present plan; get user decision on approach.

## Symptoms

expected: Auto punch IN soon after entering 20m office radius; auto punch OUT promptly after leaving.
actual:
- Nothing (good GPS): OUT at 121m (previous ~30-40m); IN after 3-4 min at 21m.
- Samsung: OUT at 38m ✓ good; never punched IN while inside radius.
- Xiaomi 1: IN ✓; no OUT when 60-80m away.
- Xiaomi 2: no auto punch at all (IN or OUT).
errors: none.
reproduction: Office radius 20m; devices with indoor GPS 20-100m.
started: Since current margin/confidence config (f72ef01 initial commit onwards).

## Eliminated

- hypothesis: Legacy GeofenceAutoPunchService runs in production and conflicts with worker
  evidence: `_startGeofenceService()` (main_shell.dart:230) defined but NEVER called; `_initGeofence()` stops it (line 216) and starts FieldTrackingService → GeofenceBackgroundWorker. Legacy service is dead code.
  timestamp: 2026-08-08

## Evidence

- timestamp: 2026-08-08
  checked: `_gpsMargin` worker (line 1080-1082) + history
  found: `(acc * 2.0).clamp(10.0, 250.0)`. Historical: 9809650 had `(acc*1.5).clamp(10,50)` (cap 50m!), a1c4a41 cap 50m. Cap raised 50→250m at some point.
  implication: For 20m radius: acc 10m→zone 40m, acc 25m→zone 70m, acc 50m→zone 120m. Exit tracking only STARTS past radius+margin.

- timestamp: 2026-08-08
  checked: Exit flow (lines 583-595)
  found: `nearestDist <= radius + margin` → "no exit". Exit starts only past zone. Trend analyzer force-confirms at 2×radius=40m but never reached when margin is huge.
  implication: Nothing OUT@121m = radius 20 + margin 100 (acc ~50m, Kalman-inflated or real indoor). Xiaomi1 no-OUT@60-80m = radius 20 + margin 40-60 (acc 20-30m) → still "within margin zone".

- timestamp: 2026-08-08
  checked: Confidence scorer (threshold 0.6, maxAllowed 80) + entry gate (worker line 320)
  found: conf = 1-(acc/80)*0.5. acc 64m→0.6 exactly; acc 80m→0.5; acc>80m→0.2. Entry requires conf ≥ 0.6.
  implication: Samsung indoor (acc 60-100m) → conf 0.2-0.625 → entry blocked despite being inside radius. Also LocationFilter.MIN_ACCURACY=120m drops fixes >120m before worker.

- timestamp: 2026-08-08
  checked: Punch payload (worker line 760-768, attendance_service line 35-40)
  found: Sends Lat/Lng/Address/Direction but NO accuracy, NO distance, NO confidence.
  implication: User right — we cannot retro-check accuracy at punch time. Need telemetry.

- timestamp: 2026-08-08
  checked: Kalman filter (line 46-53) — accuracy = sqrt(variance), variance grows +Q=50 each fix when measurements sparse
  found: Kalman accuracy can inflate above raw GPS accuracy when background fixes are sparse.
  implication: Margin uses Kalman-filtered accuracy → zone can be larger than raw GPS would justify.

- timestamp: 2026-08-08
  checked: Xiaomi 2 — no data path found in code; Xiaomi is notorious for killing background services
  found: No code-level explanation without device logs. Debug log screen exists (LogBuffer via debug_log_screen.dart).
  implication: Needs device-side diagnosis (worker running? fixes passing 120m gate? permissions? battery optimization?).

## Resolution

root_cause: (pending user plan approval)
fix: (pending)
verification: (pending)
files_changed: []
