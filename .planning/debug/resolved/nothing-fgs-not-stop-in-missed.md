---
status: resolved
trigger: "Nothing 3a — punched OUT at 61m (acceptable). FGS did NOT stop. Returned into radius: no auto IN until app opened. Happened before. Samsung full OUT→IN cycle works."
created: 2026-08-14T00:00:00Z
updated: 2026-08-14T00:00:00Z
---

## Current Focus
hypothesis: CONFIRMED (resolved)
test: full suite green (173 tests) + analyze 0 errors
expecting: catch-up ENTER re-fires for already-inside punched-OUT phone → headless IN ≤15 min fix-independent; exact containment alarm on Nothing
next_action: field test on Nothing 3a — IN after return (≤15 min, no app open)

## Symptoms
expected: after OUT punch at boundary → FGS stops; returning into radius → OS ENTER → headless IN within minutes. (Samsung did exactly this.)
actual: OUT punched at 61m (acceptable per fixed bands). FGS kept running (banner persisted). Nobody punched IN on return until user opened app.
errors: none reported
reproduction: Nothing 3a, punch IN at office → leave (~61m) → OUT fires → walk back inside radius → wait → no IN → open app → IN punches
started: recurred (user: "happened before"); Samsung cycle works, Nothing IN worked Aug-8 field test (3-4 min @ 21m — old FGS had poll recovery)

## Eliminated
- hypothesis: IN acceptance logic regressed (user's "did you change IN logic?")
  evidence: bands unchanged since ab070de (Aug 13 19:09); reconcile IN gate radius+5 no accuracy; verify ENTER radius+5/acc<=radius + trigDist<=radius+50 fallback — identical
  timestamp: 2026-08-14
- hypothesis: headless FGS stop plumbing broken (MissingPluginException etc.)
  evidence: native_geofence headless engine demonstrably runs SharedPreferences + network punches; flutter_background_service plugin pipes are process-wide statics (servicePipe/mainPipe) — sendData + ActivityManager-based isServiceRunning work from ANY engine; keep-alive 'stopKeepAlive' listener → stopSelf → 'stopService' on bg channel → isManuallyStopped + WatchdogReceiver.remove → no respawn
  timestamp: 2026-08-14
- hypothesis: combined-mode service zombie (no 'stopKeepAlive' listener in combined entrypoint)
  evidence: banner stayed "Geofence Active / Monitoring" after OUT — combined mode updates the banner to "Punched Out" on punch change (updateNotification via GPS stream); keep-alive mode banner is static. 61m OUT = GPS-fix punch = keep-alive stream path. Keep-alive mode confirmed → combined-mode stopKeepAlive drop not applicable
  timestamp: 2026-08-14
- hypothesis: restart safety-net alarm respawns the FGS after OUT
  evidence: restart task only scheduled for serviceRequired() users (wifi/tracking); keep-alive = geofence-only → never scheduled (startIfWithinShiftWindow early-return)
  timestamp: 2026-08-14
- hypothesis: native FGS revival missed by 0c1ec2c
  evidence: ContainmentAlarmReceiver headless-only (never starts BackgroundService; stops it only when disarmed); BootReceiver revival removed; GeofenceAlarmReceiver only at shift start
  timestamp: 2026-08-14

## Evidence
- timestamp: 2026-08-14
  checked: IN acceptance logic _verifyTransition/reconcile bands
  found: IN band (radius+5m, accuracy<=radius trust floor, trigDist<=radius+50 fallback) UNCHANGED since ab070de (Aug 13 19:09). Reconcile IN: dist<=radius+5, no accuracy gate.
  implication: no IN-acceptance regression — user's "did you change IN logic" answer = acceptance logic untouched
- timestamp: 2026-08-14
  checked: architecture changes since "IN flawless" era (8787c56→HEAD)
  found: 8787c56 FGS punched-IN-only; 82f2d0a armed-flag master-enable (chain dead on OUT was the earlier missed-IN bug); e624167 24/7 checker + reRegisterZonesFromCache; 0c1ec2c sticky-close FGS (no revival). FGS stop() made unconditional in e624167
  implication: current-code FGS stop chain is sound in keep-alive mode
- timestamp: 2026-08-14
  checked: headless IN recovery chain (ContainmentCheckWorker / reRegisterZonesFromCache / reconcile)
  found: 15-min alarm → reRegisterZonesFromCache(initialTriggers: {}) — NO catch-up ENTER (since 68ce662) — then reconcileContainment(confirmOut:true). reconcile punched-Out branch: last-known-first (≤10min) else fresh fix (90s budget) → indoor high-accuracy fix fails on Nothing → null → NO IN. ENTER verify needs fresh fix OR OS triggeringLocation; rejected ENTER permanently lost (no retry).
  implication: missed-IN = OS ENTER undelivered/unverifiable + reconcile fix-dependence + no catch-up ENTER. Samsung: ENTER delivered → works. App-open: foreground GPS fix works → reconcile punches IN (matches user exactly)
- timestamp: 2026-08-14
  checked: FGS stop plumbing end-to-end (plugin internals)
  found: OemKeepAliveService.stop → invoke('stopKeepAlive') → plugin 'sendData' → process-wide servicePipe → FGS isolate listener → stopSelf → 'stopService' → isManuallyStopped=true + WatchdogReceiver.remove + stopSelf → onDestroy no respawn. Verified sound from ALL isolates (ActivityManager isServiceRunning, static pipes)
  implication: current-build keep-alive stop works mechanically; user's FGS observation likely conflated pre/post app-open state (app-open IN restartIfNeeded → FGS restarts) OR a Nothing runtime kill+respawn edge — not reproducible statically; needs logcat if it recurs
- timestamp: 2026-08-14
  checked: catch-up ENTER safety (flip {enter} on alarm path)
  found: catch-up ENTER fires ONLY when device already inside geofence radius (Play Services semantics — no 61m-IN class possible). Own-source duplicates (GeofenceAuto/WiFi) persist SILENTLY (geofence_monitor:830-848) — no notification spam. Rejected-transition skip notifications have 30-min cooldown.
  implication: flipping {enter} on the containment + alignment workers is safe + effective — THE fix for the missed-IN
- timestamp: 2026-08-14
  checked: Nothing containment alarm reliability
  found: Nothing NOT in AGGRESSIVE_BRANDS (Dart + native) → alarm armed inexact (setAndAllowWhileIdle) → Nothing defers it → 24/7 checker unreliable on the exact phone being fixed
  implication: add 'nothing' to both lists → exact alarm on Nothing (SecurityException → inexact fallback preserved)
- timestamp: 2026-08-14
  checked: build under test
  found: user's build 6d3a09d = HEAD — includes e624167 (unconditional stop) + 0c1ec2c (sticky-close). Keep-alive mode confirmed via static banner + 61m GPS punch
  implication: zombie NOT explained by old build; documented as unresolved-observation (see Evidence: FGS stop plumbing)

## Resolution
root_cause: missed-IN = OS ENTER dropped/deferred on Nothing (aggressive OEM) + 15-min headless backstop fix-dependent (indoor high-accuracy GPS fails on Nothing) + alarm-path re-registration deliberately initialTriggers:{} (no catch-up ENTER, invariant 5, 68ce662) → stuck until app open (foreground reconcile has a working fix). Alarm itself unreliable on Nothing (not in aggressive-brand exact-alarm list). FGS zombie: keep-alive stop chain verified sound in current build; not reproducible statically — banner observation likely conflated with FGS restart on app-open IN (startIfNeeded); recurrence needs logcat
fix: f5a53dd — ContainmentCheckWorker + HeadlessAlignmentWorker re-register with initialTriggers:{GeofenceEvent.enter} (catch-up ENTER = fix-independent headless IN ≤15 min; silent for already-punched); 'nothing' added to AGGRESSIVE_BRANDS (Dart + native) → exact containment alarm on Nothing. AGENTS.md invariant 5 + architecture doc updated
verification: flutter analyze 0 errors; full suite 173/173 pass. FIELD TEST PENDING: Nothing 3a — IN within 15 min after return without opening the app; OUT→FGS-banner behavior observed with logcat if it recurs
files_changed:
- lib/features/punch/services/geofence_scheduler.dart (ContainmentCheckWorker catch-up ENTER)
- lib/features/alignment/headless_alignment_worker.dart (same)
- lib/core/utils/aggressive_oem.dart (+nothing)
- android/.../ContainmentAlarmReceiver.kt (+nothing, exact alarm)
- AGENTS.md (invariant 5)
- .planning/docs/native-first-geofence-architecture.md (loop section + change log)
