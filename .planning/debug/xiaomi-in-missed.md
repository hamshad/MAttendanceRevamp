---
status: investigating
trigger: "User: Xiaomi IN didn't work (Samsung/Nothing fine) + auto geofence OUT didn't work on ANY phone mid-shift (punched In, IN landed same day, nothing at 18 min). Build c253932."
created: 2026-08-17T00:00:00Z
updated: 2026-08-17T12:00:00Z
---

## Current Focus
hypothesis: OUT common-path blocker is the server-truth gate — PunchCoordinator._decide returns blocked (no punches today) or the OUT POST is 4xx-rejected; both device-independent, driven by the todayStatus payload (timeline empty / firstIn-lastOut null) or server-side date drift. Local OUT gates verified sound (stream confirmOut, OS EXIT crossing branch, fresh-fix two-fix branch — all window-independent, zone-identity cannot block when inZoneId null).
test: evening field retest with logcat — grep '[GF_MON] ... blocked by server state' vs 'punch <code>' vs 'SUCCESS' + manual OUT from app (same coordinator). PLUS new 2026-08-17 field evidence below (false OUT at 68m, offline queue, duplicate-divergence) — most local classes now fixed; remaining suspects: server-truth gate + Xiaomi WM.
expecting: one of: (a) 'blocked by server state' → todayStatus says no punches (server data/date), (b) 'punch 4xx' → server rejects OUT, (c) SUCCESS → OUT works, earlier failure = transient
next_action: evening test evidence (logcat); Xiaomi exemptions retest; OUT walk with bad internet (expect honest queued notification + sync recovery on return-IN)

## Symptoms
expected: headless OUT at walk-out (stream/OS EXIT/net) on every phone, punched In
actual: NO OUT on any phone (Samsung + Nothing), mid-shift, checked 18 min after leaving; IN landed same day on those phones; Xiaomi: IN itself missed (separate thread)
errors: nothing visible in UI (no skip notification seen)
reproduction: build c253932, punched In, leave office during shift, wait 18+ min, no OUT
started: first noticed in current testing session; OUT code path unchanged since it last worked (61m Nothing OUT, Samsung cycle)

## Eliminated
- hypothesis: shift-window gate blocks OUT outside window
  evidence: no window gate in the geofence punch path (isPastShiftEnd used only by scheduler arm + wifi worker); user was mid-shift anyway
  timestamp: 2026-08-17
- hypothesis: local OUT gates reject (bands/two-fix/zone identity)
  evidence: _reconcileOut confirmOut + _verifyTransition fresh-fix branch + crossing branch all read sound for a normal walk; zone-identity skips only when inZoneId non-null and mismatched; _punchOutConfirmed falls back to zones.first
  timestamp: 2026-08-17
- hypothesis: FGS stream absence — FGS was running (punched In → startIfNeeded)
  evidence: post-revert build starts FGS on IN; even without stream, OS EXIT + 15-min net cover OUT
  timestamp: 2026-08-17
- hypothesis: 68m false-OUT was an accurate fix (geography)
  evidence: user was CONFIDENTLY INSIDE at the time; fix accuracy 120m (wifi blend) > band 45m → untrusted; trust floor now rejects the class
  timestamp: 2026-08-17
- hypothesis: queued punch notification was server-confirmed
  evidence: bad internet at the time; server never recorded the OUT; queue-only path. Honest queued notifications now distinguish.
  timestamp: 2026-08-17

## Evidence
- timestamp: 2026-08-17
  checked: User field session (build c253932, ~same week)
  found: THREE user-visible failures: (1) FALSE 'Auto-Punched Out' notification ~8 min after leaving while physically inside + no OUT actually registered (bad internet → queued only, server never recorded it, yet UI claimed 'Auto-Punched OUT'); (2) no IN on return — server still 'In' → return ENTER judged duplicate → silently skipped, queue never flushed; (3) earlier event: false OUT at ~68m beyond radius while confidently INSIDE (wifi-blend accuracy 120m), plus ~30 min no reconciliation → manual IN.
  implication: local OPPOSITE direction failure classes confirmed on hardware: untrusted-accuracy OUT (68m class), offline-queue-vs-notification dishonesty, duplicate-divergence deadlock (queued OUT + server IN → ENTER skipped). All three now FIXED in code (geo_bands trust floor, queued notifications, divergence flush). Xiaomi IN-miss (IN=0 on Xiaomi) is a SEPARATE class — WM throttle / bg-start.
- timestamp: 2026-08-17
  checked: geo_bands.dart (NEW) + _reconcileOut/_verifyTransition (geofence_monitor.dart)
  found: OUT trust floor implemented: accuracy <= radius+slack required for any OUT claim (was dist-only — 68m-false-OUT class). Applied to stream, reconcile confirmOut, verifyTransition fresh-fix, crossing. Pure unit-tested (test/core/utils/geo_bands_test.dart). All 180 tests green.
  implication: wifi-blend 68m false OUT class closed at all four punch paths.
- timestamp: 2026-08-17
  checked: _executePunch queued/duplicate flow (geofence_monitor.dart)
  found: POST-fail + queue → notification now honest ('Auto-Punched Out (offline) — syncing when online'); undecided-IN queue → honest queued IN notification; duplicate branch flushes queue (scheduleNow) + emits skip notification on divergence; already-confirmed-locally skip avoids redundant POST.
  implication: user can no longer believe a queued punch is server-recorded; divergence self-heals on next ENTER.
- timestamp: 2026-08-17
  checked: OUT code delta since last working OUT
  found: no changes to PunchCoordinator/_executePunch/verify/reconcile since 61m OUT + Samsung cycle (pre-fix)
  implication: delta is server payload/data/date or environment — evidence must come from the device (logcat) or server response

## Resolution
root_cause: (pending — evening test evidence)
fix: (pending)
verification: (pending)
files_changed: []