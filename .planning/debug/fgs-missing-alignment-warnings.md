---
status: resolved
trigger: "User: app shows NO warning notifications (GPS off / airplane mode) while the keep-alive FGS is running — 'i thought we moved it in fgs right?'  PLUS: 'the fgs doesn't close when the user is OUT — my idea was to keep the native IN 24/7 and the OUT with fgs only when user is IN'"
created: 2026-08-17T13:00:00Z
updated: 2026-08-17T15:00:00Z
---

## Current Focus
hypothesis: (resolved) keep-alive FGS branch returned before any alignment monitor registered — FGS was deaf to GPS-off/airplane by construction.
test: n/a — code inspection + analyze + full suite
expecting: n/a
next_action: field-verify: punched in, app backgrounded → toggle GPS off → 996 within seconds; airplane mode → 998 once per offline stretch; wifi on with location off → 997 rate-limited

## Symptoms
expected: GPS-off (996) and airplane-mode (998) warnings appear while FGS running, app backgrounded
actual: total silence — nothing until app reopened or the ~30-min headless WorkManager fire
errors: none visible
reproduction: punched in (FGS running), background app, toggle airplane mode or GPS off, wait minutes
started: since the keep-alive FGS exists (`6a1f670` era) — warnings were never in it

## Eliminated
- hypothesis: notifications channel broken / permission missing
  evidence: same channel (user_alignment) fires fine from the headless worker and combined service; skip/queued punch notifications show on the same device
  timestamp: 2026-08-17

## Evidence
- timestamp: 2026-08-17
  checked: field_tracking_service.dart geofenceAndTrackingEntrypoint keep-alive branch (lines ~279-430)
  found: keep-alive mode = heal geofences + one reconcile + movement-gated GPS stream + stop listeners, then RETURNS (line ~430) — the GPS status stream (996) and wifi worker (997/998) live BELOW the return, in the combined-service path (wifi/tracking users only). Geofence-only users never execute them.
  implication: warnings existed in exactly 3 places — foreground AlignmentMonitor (app open only), combined service (wifi/tracking users only), headless WorkManager (~30-min system-scheduled, deferrable on aggressive OEMs). The keep-alive FGS — the ONLY live process for geofence-only users — carried none. User's expectation ("moved into FGS") was false; gap real.
- timestamp: 2026-08-17
  checked: battery contract (arch doc §Keep-alive)
  found: "no timers, movement-gated stream only" — the constraint that kept warnings out
  implication: fix must be event-driven (streams), never timers/polling/fixes → contract intact
- timestamp: 2026-08-17
  checked: notification ID/channel sharing (AlignmentMonitor 996-999, headless worker 996/997/998, wifi worker 997/998)
  found: all sides share IDs 996/997/998 + channel user_alignment + prefs keys wifi_bg_no_connectivity_warned / wifi_bg_bssid_warned_ts — replace, never duplicate
  implication: FGS listeners must use the same IDs/keys — done
- timestamp: 2026-08-17
  checked: FGS not closing on OUT (second user report)
  found: `gf_last_punch_type` has FIVE writers; only ONE (`geofence_monitor._persistPunchState`) wired the FGS lifecycle. Manual UI punches (`main_shell._onAttendanceStatusChanged:551`), every punch POST response mirror (`PunchStateInterceptor:52`), and both offline queue flushes (`OfflineSyncManager._publishLocalState:191`, `SyncService._publishLocalState:129`) wrote 'Out' with NO `OemKeepAliveService.stop()`. Manual IN likewise never started the walk-out monitor.
  implication: any OUT not flowing through the geofence persist path left 'Geofence Active' pinned in the tray. Native receivers clean (no revival), geofence path clean — the gap was the non-geofence writers.
- timestamp: 2026-08-17
  checked: user design intent ("native IN 24/7, OUT-watch FGS only while IN")
  found: EXACTLY the contracted shape (IN headless always; FGS = walk-out monitor gated punched-IN, OUT → unconditional stop)
  implication: no redesign needed — enforce the existing contract on every punch-state writer: `OemKeepAliveService.syncToPunchState()` (transition-gated start/stop), called from main_shell + interceptor + both offline flush paths

## Resolution
root_cause: TWO gaps, same FGS lifecycle theme. (1) Warnings: keep-alive FGS branch returned before the alignment monitors (GPS status stream, connectivity stream, wifi-hidden check) were ever registered; those lived only in the combined-service path below the return — geofence-only users' ONLY live process never emitted GPS-off/airplane warnings. (2) FGS-not-closing: `gf_last_punch_type` has five writers but only the geofence persist path wired the FGS start/stop — manual UI punches, the punch-POST response mirror (PunchStateInterceptor), attendance-poll mirror and both offline queue flushes left the FGS running after OUT / unstarted after manual IN.
fix: (1) Keep-alive branch registers event-driven streams before returning (996 GPS-off, 998 airplane, 997 wifi-hidden rate-limited) — same IDs/channel/keys as other monitors, no timers/polling/fixes. (2) New `OemKeepAliveService.syncToPunchState()` — transition-gated `startIfNeeded`/`stop` — called from all four non-geofence writers. Contract confirmed: native IN headless 24/7, FGS = walk-out monitor EXACTLY while punched IN, closes on ANY OUT source.
verification: flutter analyze 0 new issues, flutter test 180/180 green. Field verification pending (user: manual OUT → banner gone; manual IN → FGS starts; GPS off/airplane toggles → 996/998 within seconds).
files_changed: [lib/features/tracking/services/field_tracking_service.dart, lib/features/punch/services/oem_keep_alive_service.dart, lib/core/api/punch_state_interceptor.dart, lib/features/shell/main_shell.dart, lib/core/offline/offline_sync_manager.dart, lib/core/offline/sync_service.dart, .planning/docs/native-first-geofence-architecture.md]
