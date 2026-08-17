---
status: resolved
trigger: "User: app shows NO warning notifications (GPS off / airplane mode) while the keep-alive FGS is running — 'i thought we moved it in fgs right?'"
created: 2026-08-17T13:00:00Z
updated: 2026-08-17T13:30:00Z
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

## Resolution
root_cause: keep-alive FGS branch returned before the alignment monitors (GPS status stream, connectivity stream, wifi-hidden check) were ever registered; those lived only in the combined-service path below the return. Geofence-only users' ONLY live process therefore never emitted GPS-off/airplane warnings — silence until app-open or the ~30-min WorkManager fire.
fix: keep-alive branch now registers two event-driven streams before returning: `getServiceStatusStream` → GPS-off 996 (punched-IN + any-auto gate), `onConnectivityChanged` → no-network 998 (warn-once per offline stretch, shared key) + wifi-hidden 997 on wifi (re)connect (10-min rate limit, shared key). Same IDs/channel/keys as the other monitors. Streams cancelled on stopKeepAlive/stop. No timers, no polling, no GPS fixes — battery contract intact.
verification: flutter analyze 0 new issues, flutter test 180/180 green. Field verification pending (user: punched in + backgrounded → GPS off → 996 within seconds; airplane → 998).
files_changed: [lib/features/tracking/services/field_tracking_service.dart, .planning/docs/native-first-geofence-architecture.md]
