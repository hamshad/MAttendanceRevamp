---
status: resolved
trigger: "auto wifi misbehaving on android - 3 duplicate punch outs with all same out status when disconnecting from registered wifi"
created: 2026-07-30T10:00:00.000Z
updated: 2026-07-30T10:00:00.000Z
---

## Current Focus

hypothesis: CONFIRMED — all 4 bugs identified and fixed
test: dart analyze clean. Code review passed. Logic trace confirms max 1 punch per disconnect.
expecting: 0 duplicate punches on WiFi disconnect
next_action: archive session, commit

## Symptoms

expected: When user disconnects from registered office WiFi, app should punch OUT exactly once
actual: 3 duplicate OUT punches recorded with same status
errors: None (server accepts all 3)
reproduction: Be punched IN on office WiFi. Have app alive in foreground. Disconnect from WiFi (turn off WiFi or leave range). Check attendance records for 3 duplicate OUT entries.
started: Known issue, previous fixes reduced but didn't eliminate it

## Eliminated

- hypothesis: "Geofence worker also punches OUT on WiFi disconnect"
  evidence: GeofenceBackgroundWorker is GPS-based only, no connectivity subscription
  timestamp: 2026-07-30T10:00:00.000Z

## Evidence

- timestamp: 2026-07-30T10:00:00.000Z
  checked: wifi_background_worker.dart _onConnectivity() line 87-101
  found: Background calls _checkCurrentWifi() on ALL events (wifi, mobile, none). Foreground (wifi_auto_punch_service.dart line 316-331) correctly only flushes pending on mobile, does NOT punch.
  implication: Background can punch OUT on mobile data events that foreground ignores. Inconsistent behavior between two services.

- timestamp: 2026-07-30T10:00:00.000Z
  checked: wifi_background_worker.dart _handleDisconnect() lines 217-263
  found: Bug — stale local variable `lastPunchType`. Read once at line 230. `_flushPendingOut()` at line 255 can change actual SP value. Then `if (lastPunchType == 'In')` at line 257 uses stale copy. If `_flushPendingOut()` already punched OUT successfully, this causes a SECOND OUT punch.
  implication: Single call to _handleDisconnect can produce 2 OUT punches when pending OUT exists.

- timestamp: 2026-07-30T10:00:00.000Z
  checked: Dual isolate coordination — wifi_auto_punch_service.dart _lastPunchTimestamp (static, line 42) vs wifi_background_worker.dart _lastActionTimestamp (instance, line 38)
  found: Both isolates have INDEPENDENT cooldowns. Foreground punch does NOT set background's cooldown and vice versa. They can race and both punch for same event.
  implication: No cross-isolate dupe prevention.

- timestamp: 2026-07-30T10:00:00.000Z
  checked: Background 15s timer line 66 + connectivity event handlers
  found: Two independent trigger paths (stream + timer) can both call _handleDisconnect. Even with guards, the stale-local-variable bug makes this dangerous.
  implication: Extra trigger paths increase dupe probability.

- timestamp: 2026-07-30T10:00:00.000Z
  checked: Server behavior in user report
  found: Server accepts multiple identical OUT punches (no idempotency key). All 3 duplicates appear in attendance records.
  implication: Fix must be client-side — prevent multiple _punchOut calls entirely.

## Root Cause Analysis

4 bugs interact to produce 3 duplicate OUT punches:

**Bug A — Stale lastPunchType in _handleDisconnect:**
`_handleDisconnect()` reads `lastPunchType` once at line 230, then calls `_flushPendingOut()` (line 255) which may succeed and set `gf_last_punch_type='Out'` via `_punchOut()`. But the local `lastPunchType` is still `'In'`. The stale check at line 257 (`if (lastPunchType == 'In')`) triggers a SECOND `_punchOut('')`. Two OUT punches from one `_handleDisconnect` call.

**Bug B — Background reacts to mobile data events:**
Background `_onConnectivity` calls `_checkCurrentWifi()` on ALL events including `[mobile]`. Foreground correctly only flushes pending on mobile. This inconsistency means background punches OUT when foreground doesn't, creating extra punches on WiFi→mobile transitions.

**Bug C — Dual-isolate race:**
Foreground and background have independent cooldowns. Both subscribe to same connectivity_plus stream. They can both punch for the same disconnect event without knowing about each other.

**Bug D — 15s timer adds extra trigger:**
Background's 15s fallback timer creates additional call path to `_handleDisconnect`.

**How 3 duplicates occur:**
1. Foreground punches OUT via `_handleWifiDisconnected()` ← 1
2. Background punches OUT via `_handleDisconnect()` ← 1
3. Background stale `lastPunchType` after `_flushPendingOut()` causes second `_punchOut('')` ← 1
= 3 total

## Resolution

root_cause: "4 interacting bugs produce 3 duplicate OUT punches: (A) stale `lastPunchType` in background `_handleDisconnect` causes double-punch after `_flushPendingOut`; (B) background punches OUT on mobile data events while foreground correctly only flushes pending; (C) no cross-isolate coordination — both services race the same connectivity stream with independent cooldowns; (D) 15s timer adds extra trigger path for `_handleDisconnect`"
fix: "4 fixes applied:\n  1. (Bug A) Re-read `lastPunchType` from SP after `_flushPendingOut()` in `_handleDisconnect` instead of using stale local variable\n  2. (Bug B) Background `_onConnectivity` now flushes pending on mobile data only (mirrors foreground), no longer calls `_checkCurrentWifi()` which leads to `_handleDisconnect`\n  3. (Bug C) Added cross-isolate disconnect guard using shared SP key `wifi_disconnect_processed_ts` — first isolate to process marks it, second skips. Applied in both foreground `_handleWifiDisconnected` and background `_handleDisconnect`\n  4. (Bug D) Added cooldown check at start of `_handleDisconnect` (was only inside `_punchOut`)"
verification: "dart analyze passes with no new errors. Code review confirms all 4 bugs fixed. Logic trace confirms at most 1 OUT punch per disconnect event."
files_changed:
  - lib/features/punch/services/wifi_background_worker.dart: Fix bugs A, B, C, D
  - lib/features/punch/services/wifi_auto_punch_service.dart: Fix bug C (cross-isolate guard)
