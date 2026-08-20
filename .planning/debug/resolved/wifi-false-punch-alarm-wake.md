---
status: resolved
trigger: "fix false wifi auto-punches on production — IN+OUT same second 10:41:43 AM at home"
created: 2026-07-31T10:00:00Z
updated: 2026-08-01T15:12:00Z
---

## Current Focus
hypothesis: re-entrancy guard + server-state sync + BSSID confirmation gate prevent false IN+OUT on alarm wake
test: emulator run with fresh install, watch [WIFI_BG] logs
expecting: exactly ONE check at startup, "No match and not IN — noop", zero punches
next_action: verify final analyze 0 errors + report to user; DO NOT COMMIT until user says so

## Symptoms
expected: no punches when background worker wakes while user at home
actual: at 10:41:43 AM alarm spawn fired IN+OUT same second (WiFi, "In office" + "Auto Punch-Out (WiFi disconnected)")
errors: none
reproduction: background alarm wakes worker while at home; connectivity_plus emits initial event + start() immediate check run concurrently; first scan returns stale cached office BSSID → false IN; second scan real home BSSID → lastPunchType now 'In' → false OUT
started: production incident, date unknown

## Eliminated
- hypothesis: GPS/geofence caused the false punches
  evidence: GPS punch at 02:31:46 PM (24m away) is user's own manual punch — "the gps is the one I put". IN+OUT at 10:41:43 are WiFi-method, both worker punches.
  timestamp: 2026-07-31

## Evidence
- timestamp: 2026-08-01T15:02:00Z
  checked: emulator run (OLD code — install failed, stale app)
  found: TWO concurrent [WIFI_BG] "Loading offices..." at 43.666 + 43.672; both checks ran to completion
  implication: confirms concurrent-check root cause; old build had no guard
- timestamp: 2026-08-01T15:05:00Z
  checked: fresh install of fixed APK, restart, logcat
  found: start() → connectivity event → check #1; "Check already in progress — skipping" at 43.952; exactly ONE "Loading offices..."; single BSSID read → "No match and not IN — noop"
  implication: re-entrancy guard works — second concurrent check blocked
- timestamp: 2026-08-01T15:05:00Z
  checked: sync before check
  found: "Failed to sync punch state from server" (401, stale emulator token) → check waited for sync via _waitForStateSync() before proceeding
  implication: server-state sync gates the first check; on real device with valid token, stale cross-day 'In' will be corrected to server truth
- timestamp: 2026-08-01T15:06:00Z
  checked: BSSID confirmation gate code (lines 255-272)
  found: IN only after same matched BSSID on two checks within 30s window; pending state cleared on mismatch/already-IN paths
  implication: single stale BSSID read can no longer punch IN

## Resolution
root_cause: wifi_background_worker.start() ran an immediate check concurrently with connectivity_plus's initial stream event. First scan read Android's stale cached BSSID (office AP from last connection) → false auto-IN; second scan read real home BSSID → local punch state now 'In' → false auto-OUT, same second. Worker also trusted stale cross-day local punch state with no server sync, so alarm wakes at home could punch on yesterday's state.
fix: (uncommitted, wifi_background_worker.dart)
  1. _checkInProgress re-entrancy guard — _checkCurrentWifi() wrapper, only one check at a time
  2. _syncPunchStateFromServer() at start() — first check deferred behind server punch-state sync (_waitForStateSync, 10s cap)
  3. BSSID confirmation gate — auto-IN requires same matched BSSID on 2 checks within 30s; clears on mismatch
verification: emulator logcat shows single check, skip log, zero punches. flutter analyze 0 errors. flutter test +90 -13 (baseline unchanged). NOT COMMITTED.
files_changed: [lib/features/punch/services/wifi_background_worker.dart]
