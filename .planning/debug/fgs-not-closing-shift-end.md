---
status: fixing
trigger: "FGS not closing programmatically — at shift end + out of geofence it should close + remove notification, but it never closes (close or destroy not happening)"
created: 2026-08-21T00:00:00Z
updated: 2026-08-21T00:00:00Z
---

## Current Focus
hypothesis: shift-end FGS self-kill is dead code (isPastShiftEnd() defined but never called) + OemKeepAliveService.stop() guarded by unreliable svc.isRunning() so the stop signal is sometimes never sent.
test: wire isPastShiftEnd into the keep-alive FGS lifecycle (entrypoint + movement stream) gated on past-shift-end AND outside-all-offices; make stop() always invoke the running service.
expecting: at shift end with the user outside every office, the keep-alive FGS stops and the "Geofence Active" notification is removed within the entrypoint/stream, without waiting for a missed-OUT reconcile.
next_action: implement stop() robustness + shift-end+outside stop in field_tracking_service.dart entrypoint, build + test.

## Symptoms
expected: FGS (keep-alive, "Geofence Active" banner) closes programmatically when shift ends and user is out of geofence; notification removed.
actual: FGS keeps running; banner stays; never auto-closes.
errors: none in UI.
reproduction: enable geofence auto-punch → get punched In → FGS starts → wait past shift end while outside office → FGS + notification persist.
started: reported 2026-08-21.

## Eliminated
- hypothesis: stopKeepAlive handler missing
  evidence: field_tracking_service.dart:488 registers service.on('stopKeepAlive').listen → stopSelf() (line 493). Handler exists.
  timestamp: 2026-08-21
- hypothesis: _persistPunchState(Out) not calling stop
  evidence: geofence_monitor.dart:1363 calls OemKeepAliveService.stop() on OUT. Path exists; but only fires on an actual OUT punch (which can be missed by OEMs — leaving FGS holding on a stale 'In').
  timestamp: 2026-08-21

## Evidence
- timestamp: 2026-08-21
  checked: isPastShiftEnd() callers (whole repo)
  found: isPastShiftEnd() is defined in geofence_scheduler.dart:279 but has ZERO callers. The scheduler comment (269-271) claims "the background service can kill itself once the shift is over and the user has punched out" — but the kill trigger was never wired. _persistShiftEnd() IS called (shift-end time persisted), so the pref exists; the checker is simply never invoked.
  implication: the designed shift-end self-kill is dead code → FGS never stops at shift end. This matches the user's exact report.
- timestamp: 2026-08-21
  checked: OemKeepAliveService.stop() (oem_keep_alive_service.dart:165)
  found: guard `if (await svc.isRunning())` before `svc.invoke('stopKeepAlive')`. flutter_background_service.isRunning() is known-flaky (false negatives), so when it returns false the stop signal is never sent and the FGS lingers.
  implication: even the OUT-path stop can silently no-op. Make stop() always invoke the running service (invoke is a harmless no-op when not running).

## Resolution
root_cause: shift-end FGS self-kill dead (isPastShiftEnd never called) + stop() guard drops the stop signal on flaky isRunning().
fix: (1) OemKeepAliveService.stop() now always invokes 'stopKeepAlive' + 'stop' (no isRunning() guard). (2) keep-alive entrypoint: after initial heal, if shift is past AND outside all offices → stopSelf; movement stream: when outside + shift past → stopSelf after reconcile. Inlined shift-end read to avoid import cycle.
verification: flutter analyze 0 errors; 180 tests green; manual field retest pending (shift end + outside → FGS closes + notification removed).
files_changed: [lib/features/punch/services/oem_keep_alive_service.dart, lib/features/tracking/services/field_tracking_service.dart]
