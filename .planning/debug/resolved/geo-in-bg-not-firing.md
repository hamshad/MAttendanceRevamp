---
status: resolved
trigger: "auto punch-IN delayed ~5-6min until app opened; OUT worked in bg (both user + Samsung device)"
created: 2026-08-10T00:00:00Z
updated: 2026-08-10T00:00:00Z
---

## Current Focus
hypothesis: ROOT CAUSE FOUND — OS ENTER event deferred while app backgrounded (OEM battery/Doze); no app-side bg fallback existed. Fixed.
test: 6 new reconcile tests + full suite 99/99
expecting: IN recovers within ~15s of re-entry via bg poll
next_action: done — commit 925cf6e

## Symptoms
expected: re-entering office radius auto punches IN in background (like OUT did)
actual: IN only fires after opening app (5-6 min inside radius)
errors: none reported
reproduction: punch IN at office, leave 60m (OUT fires), return inside radius, do not open app -> no IN; open app -> IN
started: after 70913ed self-kill ship (recent) / unknown

## Eliminated
- hypothesis: bg service self-killed after OUT (shift-end passed) — rejected: geofence punches run in plugin's own bg isolate (`geofenceTriggered`), independent of fg service; `_maybeStopAfterShift` also requires shift-end passed which mid-day OUT wouldn't. Fences stay registered (registerZones/unregisterAll only on enable/disable/zone-change, not on punch).
  evidence: geofence_monitor.dart:153-246 register/unregister sites; _maybeStopAfterShift wifi_background_worker.dart:135-149; IN processing requires OS event via handleEvent
  timestamp: 2026-08-10

## Evidence
- timestamp: 2026-08-10
  checked: user report
  found: OUT fired in bg at ~61m; IN did not fire for 5-6 min in-radius; IN fired immediately on app open. Two devices (user + Samsung).
  implication: background IN processing path dead/starved; foreground re-init recovers it
- timestamp: 2026-08-10
  checked: geofence_monitor.dart IN path
  found: `_handleZoneEvent` requires OS event (enter); `_verifyTransition` In lenient (fresh fix inside radius+margin OR triggerLoc inside radius+50) — a delivered event would punch within ~10s
  implication: event genuinely not delivered in bg, not verification-drop
- timestamp: 2026-08-10
  checked: register/unregister + worker poll
  found: fences persist after punch; 15s poll ran wifi checks only, geofence containment never re-checked; resume path (didChangeAppLifecycleState) also has no containment check
  implication: no app-side recovery for missed OS enter event — opened app wakes location → plugin delivers deferred ENTER → IN fires
- timestamp: 2026-08-10
  checked: fix verification
  found: extracted `_executePunch` (shared by events + recovery); added `GeofencePunchHandler.reconcileContainment()` (enabled+token+state gates, office containment only, client sites skipped, `_freshFix` + margin check, coordinator gate / queue / persist); called from 15s poll as `_checkGeofenceContainment` gated on geofence_auto_enabled
  implication: IN lands within ~15s of re-entry even when OS never delivers transition

## Resolution
root_cause: OEM battery optimizations defer geofence ENTER delivery while app backgrounded (fused location throttled after EXIT). IN processing depended solely on OS transition events; the 15s bg poll checked wifi only, never geofence containment — a deferred/missed enter event was unrecoverable until app open woke location.
fix: extract `_executePunch` shared helper; add `GeofencePunchHandler.reconcileContainment()`; call from combined service 15s poll (gated on geofence_auto_enabled)
verification: +6 tests (punched-out+inside→IN, already-in no-op, outside no-op, disabled no-op, server-unreachable→queue, biometric-dup→sync state); monitor 32/32, full suite 99/99, analyze clean (pre-existing infos only)
files_changed: [lib/features/punch/services/geofence_monitor.dart, lib/features/punch/services/wifi_background_worker.dart, test/features/punch/services/geofence_monitor_test.dart]