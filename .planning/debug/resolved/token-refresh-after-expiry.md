---
status: resolved
trigger: "we are still facing token issues? the jwt access tokes have 30days ttl, and after token expires, the app doesn't refreshes the token, and because of that the app doesn't work because all apis give errors now, and when user needs to be punched IN/OUT the punch is getting into the queue for it to be synced but obviously those won't sync as the token is expired. we have refresh token api and logic so why is it not working? or the refresh token logic might be broken from backend? if thats the case give proof"
created: 2026-09-12T00:00:00.000Z
updated: 2026-09-12T00:00:00.000Z
---

## Current Focus

hypothesis: foreground stuck-state = status-code contract mismatch on /auth/refresh itself. Client treats ONLY HTTP 400 as "refresh rejected → logout" (dio_client.dart:278-280); any other refresh failure (401/403/404/422 from backend, or response-shape parse crash) falls into catch-all "transient — retain session". Result: every API 401s → refresh attempted → refresh fails non-400 → session retained → request fails → repeat forever. App looks logged in, all APIs error, never recovers, never logs out.
test: need live evidence — logcat [AUTH] lines + curl POST /api/v1/auth/refresh with expired access + stored refresh; status code + body decides client vs backend
expecting: refresh returns non-400 failure OR 200 with unexpected body shape; EITHER is sufficient for permanent stuck state
next_action: give user exact proof commands + outcome table

## Symptoms

expected: access token expires (30d TTL) → app silently refreshes via /api/v1/auth/refresh → APIs keep working, queued punches sync
actual: after expiry all APIs error; IN/OUT punches sit in offline queue and never sync. FOREGROUND APIs also fail — refresh seemingly never recovers the session.
errors: API 401s everywhere; queue entries stuck then marked failed
reproduction: let access token expire (or force-expire), trigger punch while app killed/background → queued punch never syncs; open app → foreground APIs also error
started: ongoing — "still facing token issues" after token-flush-logout fixes

## Symptoms

expected: access token expires (30d TTL) → app silently refreshes via /api/v1/auth/refresh → APIs keep working, queued punches sync
actual: after expiry all APIs error; IN/OUT punches sit in offline queue and never sync
errors: API 401s everywhere; queue entries stuck then marked failed
reproduction: let access token expire (or force-expire), trigger punch while app killed/background → queued punch never syncs
started: ongoing — "still facing token issues" after token-flush-logout fixes

## Eliminated

- hypothesis: foreground DioClient refresh interceptor is broken
  evidence: dio_client.dart lines 133-316 — 401 → cross-isolate lock → POST /api/v1/auth/refresh with {accessToken, refreshToken} → save → retry + flush queue; transient failures retain session, only 400 (with race-adoption check) clears. Logic internally sound. SyncService._shouldDrop uses _dioClient.dio (has interceptor) so foreground queue sync self-heals. PunchStateInterceptor.onError always calls handler.next — never swallows 401, never blocks refresh.
  timestamp: 2026-09-12T00:00:00.000Z

## Evidence

- timestamp: 2026-09-12T00:00:00.000Z
  checked: lib/core/offline/offline_sync_manager.dart executeSyncTask lines 89-127
  found: per punch, FIRST calls _shouldDropPunch (gate), `if (...) continue`. Only the punch POST below is wrapped in on DioException → _handleDioError (which holds the ONLY refresh call in this file, lines 210-246).
  implication: gate runs before any refresh logic; a 401 at the gate never reaches the refresh path

- timestamp: 2026-09-12T00:00:00.000Z
  checked: offline_sync_manager.dart _buildDio lines 136-144 + _shouldDropPunch → PunchCoordinator.check
  found: _buildDio is a PLAIN Dio (static Bearer header, NO 401 interceptor). PunchCoordinator.check lines 68-87 catches ALL errors (including 401) → returns PunchCheck.undecided. _shouldDropPunch lines 175-182 maps undecided → retryCount++ → save → return true (skip punch).
  implication: with expired token, todayStatus GET 401s → undecided → punch skipped with retry bump, refresh never attempted. Deterministic freeze.

- timestamp: 2026-09-12T00:00:00.000Z
  checked: lib/core/utils/constants.dart line 32, offline_sync_manager line 82
  found: maxRetryCount = 3; pending filter is retryCount < maxRetryCount. Each 15-min periodic run burns one retry on the gate-401.
  implication: after ~3 runs (~45 min) the punch drops out of the pending set entirely — IN/OUT silently lost, matches "queue won't sync". Offline screen then shows it as failed (retryCount >= maxRetryCount).

- timestamp: 2026-09-12T00:00:00.000Z
  checked: lib/core/offline/sync_service.dart _shouldDrop lines 130-134
  found: foreground sync passes _dioClient.dio (WITH 401 interceptor) into the same PunchCoordinator.check — gate GET 401 triggers interceptor refresh + retry transparently.
  implication: bug is ISOLATE-SPECIFIC: foreground self-heals, background Workmanager isolate does not. Explains "app doesn't work / queue stuck" when app is killed or in background at expiry.

- timestamp: 2026-09-12T00:00:00.000Z
  checked: refresh request/response contract across all 5 call sites (dio_client 223-232, offline_sync_manager 220-228, geofence_monitor 1602-1608, wifi_background_worker 996-1002, field_tracking_service 800-809)
  found: ALL send {'accessToken': <expired>, 'refreshToken': <refresh>} to POST /api/v1/auth/refresh and read resp.data['accessToken'/'refreshToken'] (camelCase, TOP-LEVEL). Consistent client-side.
  implication: no client-side contract mismatch between paths. Whether the BACKEND honors this contract (accepts expired accessToken + valid refreshToken, returns rotated pair) cannot be proven from this repo — needs live proof (see Resolution).

- timestamp: 2026-09-12T00:00:00.000Z
  checked: dio_client.dart catch block lines 259-315 (foreground refresh failure classification)
  found: ONLY status==400 counts as token rejection → logout. Refresh returning 401/403/404/422 (typical backend conventions for bad refresh — ASP.NET usually 401, not 400) falls to catch-all line 312 "non-fatal — retaining session". Response-shape mismatch (backend wraps tokens in {data:...} or different casing) makes `as String` throw TypeError → SAME catch-all path. Both produce PERMANENT stuck-logged-in state: every API 401s, every refresh fails non-400, session retained forever, user never routed to login.
  implication: if user reports "all APIs error but app does NOT drop to login screen", this classification gap is the foreground mechanism — regardless of whether backend's rejection is legitimate (refresh also expired) or a backend bug (wrong status code / validates expired accessToken / unexpected body).

- timestamp: 2026-09-12T00:00:00.000Z
  checked: punch_state_interceptor.dart onError lines 22-44
  found: always ends with handler.next(error) — pass-through on 401. Cannot block or consume the auth refresh.
  implication: eliminated as foreground blocker.

- timestamp: 2026-09-12T00:00:00.000Z
  checked: auth_provider.dart _tryAutoLogin lines 98-156
  found: on startup with expired token, GET me → 401 → interceptor refresh attempt. If refresh fails transient/non-400 → skeleton user returned (lines 144-156), app looks LOGGED IN with zero working APIs.
  implication: matches "app doesn't work, all apis give errors" while staying inside the app — skeleton-user path masks session death.

## Resolution

root_cause: TWO defects, backend + client. (1) Backend rejects bad/expired refresh with HTTP 401 {"message":"Invalid or expired refresh token."} — proven live 2026-09-12. Client DioClient treats ONLY 400 as rejection (dio_client.dart:278-280) → 401 refresh failure lands in catch-all transient-retain → permanent stuck-logged-in: every API 401s, every refresh 401s, never recovers, never routes to login. (2) OfflineSyncManager bg gate swallows 401 as undecided before refresh reachable; retries burn out (max 3) → queued punches die. Either alone explains symptoms; together they guarantee them at day-30 double-expiry.
fix:
verification: LIVE backend proof 2026-09-12 — POST /api/v1/auth/refresh valid-access+GARBAGE-refresh → HTTP 401 {"message":"Invalid or expired refresh token."} (not 400 → client never logs out). Garbage-access+valid-refresh → HTTP 400 IDX12729 (backend parses accessToken field). Valid+valid → HTTP 200 rotated pair (endpoint healthy otherwise). GET /api/v1/auth/me → HTTP 404 empty (endpoint missing — startup profile fetch always falls to skeleton user).
files_changed: [lib/core/api/dio_client.dart, lib/core/punch/punch_coordinator.dart, lib/core/offline/offline_sync_manager.dart]

## Fix Applied 2026-09-12

1. dio_client.dart: any 4xx from /auth/refresh = rejection → forceLogout (was 400-only). + log line with status code.
2. punch_coordinator.dart: new PunchCheck.authFailed on 401 (was folded into undecided).
3. offline_sync_manager.dart: authFailed → _refreshBgTokens() once → re-run gate → rebuild POST Dio from mirror on ts change. Queue survives expiry.
4. Deferred: ApiEndpoints.me 404 — needs live response-shape check, skeleton fallback works.
5. Verified: flutter analyze 0 errors, flutter test 197/197 pass. Doc: TOKEN_REFRESH_ISSUE.md.
