---
status: resolved
trigger: "CORRECTED 2026-08-19: User: auto-IN not working on ANY device since the 08-17/08-18 update — only works when app is OPEN, never backgrounded; user sits INSIDE office hours with no IN. Auto geofence OUT worked fine on all devices mid-shift. (Original 08-17 trigger claimed Xiaomi-only IN miss + OUT broken on any phone — both superseded by user correction.)"
created: 2026-08-17T00:00:00Z
updated: 2026-08-19T00:00:00Z
---

## Current Focus
hypothesis: OUT common-path blocker is the server-truth gate — PunchCoordinator._decide returns blocked (no punches today) or the OUT POST is 4xx-rejected; both device-independent, driven by the todayStatus payload (timeline empty / firstIn-lastOut null) or server-side date drift. Local OUT gates verified sound (stream confirmOut, OS EXIT crossing branch, fresh-fix two-fix branch — all window-independent, zone-identity cannot block when inZoneId null).
test: evening field retest with logcat — grep '[GF_MON] ... blocked by server state' vs 'punch <code>' vs 'SUCCESS' + manual OUT from app (same coordinator). PLUS new 2026-08-17 field evidence below (false OUT at 68m, offline queue, duplicate-divergence) — most local classes now fixed; remaining suspects: server-truth gate + Xiaomi WM.
expecting: one of: (a) 'blocked by server state' → todayStatus says no punches (server data/date), (b) 'punch 4xx' → server rejects OUT, (c) SUCCESS → OUT works, earlier failure = transient
next_action: evening test evidence (logcat); Xiaomi exemptions retest; OUT walk with bad internet (expect honest queued notification + sync recovery on return-IN)

## Symptoms
expected: headless auto-IN on arrival at office (OS ENTER or 15-min containment catch-up) on every phone, punched Out; auto-OUT at walk-out
actual: auto-IN NOT working on ANY device in background — only when app opened (foreground Hive/bootstrapping ran); no IN for hours while inside office radius. Auto-OUT worked on ALL devices mid-shift. (Original 08-17 entry recorded 'NO OUT on any phone (Samsung + Nothing)' — superseded by user correction 2026-08-19: OUT was working.)
errors: 08-19 emulator repro: `[GF_SCHED] Containment check failed: HiveError: Box not found`; server 400 'Geofence auto-punch already recorded within the last 5 minutes'
reproduction: build c253932+, punched Out, arrive/remain inside office radius with app backgrounded or killed, wait 20+ min, no IN
started: since 08-17/08-18 update (pending-exit auto-OUT era); IN-missed class observed fleet-wide

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
- timestamp: 2026-08-19
  checked: emulator + code archaeology for "auto-IN only when app open, all devices"
  found: ROOT CHAIN for the IN-missed background class:
    1. e624167-era headless containment WorkManager callback opened Hive boxes in main.dart/background entrypoint but NOT in the geofence WorkManager callback → `GeofenceMonitor.isEnabled` (`Hive.box(geofenceSettingsBox)`) threw `HiveError: Box not found` on EVERY headless fire (repro at 08-19 18:07:56 `[GF_SCHED] Containment check failed: HiveError: Box not found`) → the entire 15-min containment/reconcile/catch-up-ENTER net DIED when app was backgrounded/killed. Foreground worked only because main.dart opened all boxes → exactly matches "IN only when app is opened".
    2. Yesterday's pending-exit auto-OUT (+ return ENTER) exposed the server's GeofenceAuto rate limit: untouched-in-5min ENTER → 400 'Geofence auto-punch already recorded within the last 5 minutes'. Every IN-attempt path treated this as PERMANENT (no retry): event path dropped the IN; PunchStateInterceptor.onError mirrored `gf_last_punch_type=In` on ANY 'already recorded' 400 (faked local IN → reconcile + wifi worker then gated off IN permanently); wifi worker `_handleDuplicateError` did the same false-dup fake; sync_service flush capped queued IN at retryCount=99 (never flushed again). Local IN + server OUT divergence = hours punched-out inside the office.
  implication: four-armed fix (all committed 2026-08-19):
    (1) geofence_scheduler.dart headless callback now opens geofenceSettingsBox + shiftsBox + tokenBackupBox alongside offlinePunchBox/cacheBox → containment net revives headless.
    (2) punch_state_interceptor.onError: transient rate-limit message ('within the last') no longer mirrors state.
    (3) wifi_background_worker._handleDuplicateError: same exclusion — rate-limit ≠ duplicate, return false → next 60s poll retries.
    (4) sync_service badResponse flush: 'within the last' → retryCount++ (transient) instead of 99 → queued IN survives the window and lands.
  verification: emulator background test (app killed via am kill, NOT force-stop): OUT SUCCESS 18:25:40 → re-ENTER 18:26:56 → 400 → `[GF_MON] office_4: transient geo auto rate limit — reconcile net will retry IN` → auto 'Auto punched-in' notification landed seconds later in background (user-confirmed) without app open. flutter analyze 0 errors, flutter test 180/180 green. All four fixes + live emulator = verification.
- timestamp: 2026-08-18
  checked: geofenceScheduler.geofenceWorkmanagerCallback (headless WorkManager isolate)
  found: Hive was NEVER initialized in the geofence WorkManager callback → any headless punch POST-fail → _queueOfflinePunch threw on Hive box open → OUT silently LOST without notification (exact 'no OUT' class on Samsung/Nothing). Background-service entrypoint had init; WorkManager path did not. FIXED: root-zone `_initHive` now runs in the callback before any punch; scheduled/complete ignore repeats.
  implication: headless OUT after OS EXIT with bad/missing network = silent total loss in every build before this. Queue now survives; server-truth gate retries (PunchCoordinator) instead of throwing.
- timestamp: 2026-08-18
  checked: _executePunch silent-failure branches (geofence_monitor.dart)
  found: two more silent-OUT classes: (a) undecided-offline skip (`lastType == direction` return) while actually OUT-side — OUT silently dropped when network dead; (b) POST non-2xx / DioException without queue → OUT dropped silently (no state change, no notification) → next ENTER judged duplicate (server In + local In) → missed-IN class.
  implication: FIXED via pending-exit recovery: silent OUT failures persist the honest crossing fix; 15-min reconcile auto-OUTs via server-truth gate even when user already back inside (fix-based branch could never confirm); flag recycles until success or 2h GC; cleared on any successful IN/OUT convergence. Verified: all 180 tests green, 0 analyzer errors.
- timestamp: 2026-08-18
  checked: MI battery restrictions + aggressive-OEM list (commit 9ee84a8, 8b21ada)
  found: aggressive-inexact-alarm list narrowed to MI family ONLY (xiaomi/redmi/poco); Samsung/Nothing/OnePlus removed (field-proven fine without). MI gate MANDATORY both enable paths: auto-punch cannot enable until Auto-start + battery saver + battery optimization off confirmed (`gf_oem_restrictions_confirmed`). MIUI per-app battery state not programmatically readable → user-verified, honest. Samsung/Nothing = plain inexact alarm (works, less drain).
  implication: MFI field evidence (xiaomi-in-missed) closed by design: MI now gates cranky backgrounding explicitly; non-MI never sees aggressive path.
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
root_cause: MULTI-CLASS: (DONE) WorkManager headless Hive gap → silent OUT loss; silent OUT failure branches → duplicate-divergence missed-IN; MI battery backgrounding behind user's back (design gate); (DONE 2026-08-19) auto-IN background class: headless containment net dead via missing Hive box (geofenceSettingsBox) in WorkManager callback + server GeofenceAuto 5-min rate-limit 400 treated as permanent everywhere (IN dropped, faked local In in interceptor + wifi duplicate handler, queued IN capped retryCount=99). (PENDING) server-truth gate OUT rejection — evening field test evidence; Xiaomi WM headless IN throttle — exemptions retest.
fix: (committed 2026-08-17: trust floor, honest queue, divergence flush, FGS lifecycle, MI aggressive list+gate; 2026-08-18: geofence WorkManager callback Hive init + pending-exit auto-OUT recovery; 2026-08-19: headless callback opens all Hive boxes; transient rate-limit excluded from state-mirror interceptor + wifi worker duplicate handler + sync_service flush capping)
verification: flutter analyze 0 errors, 180/180 tests green; emulator background proof: OUT success → re-ENTER → 400 transient log → auto punched-in notification landed in background with app killed (user-confirmed). Real-device field test pending user run.
files_changed: [lib/features/punch/services/geofence_monitor.dart, lib/features/punch/services/geofence_scheduler.dart, lib/core/api/punch_state_interceptor.dart, lib/features/punch/services/wifi_background_worker.dart, lib/core/offline/sync_service.dart, lib/features/settings/screens/geofence_settings_screen.dart]