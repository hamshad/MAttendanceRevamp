---
status: resolved
trigger: "tokens flushed/removed while user still logged in, token not expired, sometimes logs out, app doesn't load anything"
created: 2026-07-31T09:00:00.000Z
updated: 2026-07-31T09:00:00.000Z
---

## Current Focus

hypothesis: "6 bugs in token lifecycle: non-atomic cross-isolate refresh lock → concurrent refresh → 400 → forceLogout; _syncFromBackgroundMirror clobbers fresh tokens with stale; _handleRefreshFailure destroys Hive backup; background resurrects tokens after logout; _waitForOtherIsolateRefresh double-refreshes; hasTokens ignores Hive backup"
test: code reading verification of each bug path
expecting: confirm all 6 bug paths
next_action: ALL FIXES APPLIED + dart analyze clean (0 errors). Session archived.

## Symptoms

expected: User stays logged in while access/refresh tokens valid. App loads data normally.
actual: Tokens get flushed/removed while user still logged in. Sometimes app logs user out. Sometimes tokens removed but app stuck — nothing loads, no login screen. Happens with token still not expired.
errors: None visible to user (silent). Logs would show "[AUTH] Refresh token rejected by server (400) — clearing session".
reproduction: Run app with WiFi auto-punch + geofence + field tracking active. Use app for a while (token expiry happens). Access token expires → both main isolate and background isolate simultaneously get 401 → both attempt refresh → one gets 400 → forceLogout despite valid session.
started: Since background services + token refresh added.

## Eliminated



## Evidence

- timestamp: 2026-07-31T09:00:00.000Z
  checked: token_storage.dart acquireRefreshLock() lines 177-190
  found: NON-ATOMIC read-then-write. `prefs.reload()` → `getInt(lock)` → `setInt(lock, now)`. Two isolates can both read lockTs==0, both write, both proceed to refresh with SAME refresh token.
  implication: Concurrent refresh from main + background → server rotates refresh token → loser gets 400.

- timestamp: 2026-07-31T09:00:00.000Z
  checked: dio_client.dart _onError lines 269-273 + _handleRefreshFailure 284-291
  found: On refresh 400 → `clearTokens()` + `clearBackup()` (destroys Hive backup!) + `_notifySessionExpired()` → forceLogout. No recovery check — doesn't check if ANOTHER isolate just refreshed successfully.
  implication: Concurrent refresh race → valid session killed. Matches "logged out while token not expired".

- timestamp: 2026-07-31T09:00:00.000Z
  checked: token_storage.dart _syncFromBackgroundMirror() lines 91-115
  found: Reads `bgTs` (line 97) but NEVER uses it for comparison. If `bgAccess != currentAccess`, unconditionally overwrites secure storage AND Hive with whatever is in SP mirror. SP mirror is written by BOTH main saveTokens AND background refresh → background can write STALE pair after main's fresh save → main's next getAccessToken syncs stale over fresh.
  implication: Fresh tokens clobbered by stale background tokens → next 401 → refresh with rotated token → 400 → forceLogout.

- timestamp: 2026-07-31T09:00:00.000Z
  checked: token_storage.dart clearTokens() lines 119-133 + tryRestoreFromBackup() 137-149
  found: clearTokens preserves Hive (good) but tryRestoreFromBackup has ZERO callers (dead code). _handleRefreshFailure calls clearBackup() which DESTROYS the recovery source. hasTokens() (162-173) does NOT check Hive backup.
  implication: Recovery path never runs. Accidental clear = permanent session loss.

- timestamp: 2026-07-31T09:00:00.000Z
  checked: geofence_background_worker.dart _refreshToken() lines 725-775, wifi_background_worker.dart 624-673, field_tracking_service.dart 289-446
  found: Background workers refresh independently, write SP bg keys on success. No session-generation check. If logout's clearTokens() runs while bg refresh in-flight, bg re-writes bg_access_token/bg_refresh_token → tokens resurrected → hasTokens() true → auto-login with stale tokens next launch.
  implication: Resurrection after logout. Also feeds _syncFromBackgroundMirror clobber.

- timestamp: 2026-07-31T09:00:00.000Z
  checked: dio_client.dart _waitForOtherIsolateRefresh() lines 294-324
  found: After 30s wait, re-enters `_onError(error, handler)` (line 323). If lock stale window (30s) expired, re-acquires lock and refreshes AGAIN with same refresh token → concurrent refresh → 400 risk.
  implication: Feeds the double-refresh race.

- timestamp: 2026-07-31T09:00:00.000Z
  checked: auth_provider.dart _tryAutoLogin() lines 66-143
  found: Fast path returns cached user WITHOUT token validation (lines 79-83). If tokens were cleared but AppUser cached → app shows logged-in UI → all requests 401 → interceptor retains session (conditions user added) → app stuck, nothing loads, no logout.
  implication: "Tokens removed but app doesn't load anything" state.

- timestamp: 2026-07-31T09:00:00.000Z
  checked: dio_client.dart _onError lines 174-188 partial-state path
  found: "No refresh token but access token exists — retain session" — with both cleared (all stores), refreshToken==null and accessToken==null → falls through to _handleRefreshFailure → logout. With tokens cleared but AppUser cached → repeated 401s, each retain attempt... then logout.
  implication: Confirms stuck-state + eventual logout.

## Resolution

root_cause: "Concurrent-refresh race across isolates + missing recovery: (1) non-atomic refresh lock let main isolate + background workers refresh with the SAME refresh token; server rotated it; loser got 400 → forceLogout despite valid session. (2) _syncFromBackgroundMirror never compared timestamps, clobbering fresh secure/Hive tokens with stale SP mirror. (3) _handleRefreshFailure destroyed the Hive backup (the only recovery source). (4) background workers wrote refreshed tokens with no session-generation guard → resurrection after logout. (5) _waitForOtherIsolateRefresh re-entered _onError → second concurrent refresh. (6) hasTokens ignored Hive; _tryAutoLogin fast path returned cached user without token validation → stuck logged-in state."
fix: "token_storage.dart: atomic refresh lock (unique owner token + re-read verify), auth_session_id session-generation marker written on save/removed on clear, _syncFromBackgroundMirror guards (session marker present + mirror ts newer than last save), hasTokens checks Hive via tryRestoreFromBackup, clearTokens preserves Hive. dio_client.dart: on refresh 400 → _adoptNewerTokensIfRefreshed (adopt newer pair if another isolate rotated) BEFORE forceLogout; _handleRefreshFailure no longer clears Hive backup; _waitForOtherIsolateRefresh rewritten — single guarded wait loop, polls lock release, flushes queue, NO re-entry into _onError. auth_provider.dart: forceLogout clears Hive backup (prevents restore-loop), _tryAutoLogin clears stale cached user when no tokens. geofence/wifi workers + field_tracking_service: atomic lock claim + session guard before persisting refreshed tokens."
verification: "dart analyze: 0 errors (3 pre-existing test errors fixed by cleaning stub token_storage_test). All changed files analyzed clean. Logic trace of every race path: loser now adopts winner's tokens instead of logging out; stale mirror never clobbers fresh; background can't resurrect tokens after logout; wait loop can't double-refresh."
files_changed: [lib/core/auth/token_storage.dart, lib/core/api/dio_client.dart, lib/core/auth/auth_provider.dart, lib/features/punch/services/geofence_background_worker.dart, lib/features/punch/services/wifi_background_worker.dart, lib/features/tracking/services/field_tracking_service.dart, test/core/auth/token_storage_test.dart]
