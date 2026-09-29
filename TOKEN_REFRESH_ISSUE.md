# Token Refresh Failure — What Happens and What To Fix

Date: 2026-09-12. Live backend proof included. Code refs = `lib/` in this repo.

## TL;DR

After access-token expiry the app can never recover. Two client defects plus one
backend convention guarantee a permanent stuck state: logged in, every API
erroring, queued punches dying, no logout screen. Login works, refresh works
while tokens are valid — the failure is purely in the **expiry / rejection path**.

## Proof (live, 2026-09-12, production `https://api.mattendance.com`)

| Call | Result |
|---|---|
| `GET /api/v1/attendance/status` + valid access | `200` — token path healthy |
| `GET /api/v1/auth/me` + valid access | `404` empty — endpoint does not exist (see side bug) |
| `POST /api/v1/auth/refresh` valid access + valid refresh | `200` + new rotated pair, top-level camelCase keys — endpoint healthy |
| `POST /api/v1/auth/refresh` garbage access + valid refresh | `400 IDX12729: Unable to decode header…` — backend **parses** the `accessToken` field |
| `POST /api/v1/auth/refresh` valid access + garbage refresh | `401 {"message":"Invalid or expired refresh token."}` — **backend rejects with 401, not 400** |

Last row is the smoking gun.

## What happens on API calls today

### Foreground (app open) — `DioClient` (`core/api/dio_client.dart`)

1. Request attaches `Authorization: Bearer <access>` (`_onRequest`, :86).
2. Expired access → server `401` → `_onError` starts refresh (:133-258):
   `POST /api/v1/auth/refresh` with `{"accessToken": <expired>, "refreshToken": <refresh>}`,
   saves new pair, retries original + queued requests.
3. Refresh failure classification (:259-315) — **the defect**:
   - `500+` / network → retain session (correct).
   - `400` → logout (correct **only if backend uses 400**).
   - **Anything else (401/403/404/422, parse crash on `as String`) → catch-all
     "non-fatal, retain session" (:312).**
4. Backend actually returns **401** for bad/expired refresh (proven above) →
   every API call loops `401 → refresh → 401 → retain` forever. No recovery,
   no login screen.
5. Startup masks it: `_tryAutoLogin` (`core/auth/auth_provider.dart:98-156`)
   falls back to a skeleton user when profile fetch fails — app looks logged
   in with zero working APIs.

### Background queue sync (app killed) — `OfflineSyncManager` (`core/offline/offline_sync_manager.dart`)

1. `executeSyncTask` loops queued punches. Per punch it FIRST runs the
   server-truth gate (`_shouldDropPunch` → `PunchCoordinator.check` → `GET todayStatus`).
2. Gate uses `_buildDio` — **plain Dio, no 401 interceptor** (:136-144).
3. `PunchCoordinator.check` catches ALL errors incl. `401` → `undecided`
   (`core/punch/punch_coordinator.dart:85-87`).
4. `undecided` → `retryCount++`, punch skipped (:175-182). The refresh code
   (`_handleDioError`, :204) sits behind the punch POST and is **never reached**.
5. `maxRetryCount = 3` (`core/utils/constants.dart:32`), periodic run every
   15 min → punch silently drops out of the queue after ~45 min. IN/OUT lost.

Foreground `SyncService` does NOT have this bug — it passes `dioClient.dio`
(with interceptor) into the same gate (`core/offline/sync_service.dart:130-134`).

### Side bug

`GET /api/v1/auth/me` returns `404` (proven live). `_tryAutoLogin` fetches it
when cached user data is missing, so fresh installs always degrade to the
skeleton-user path. Either the endpoint never existed or it moved —
`ApiEndpoints.me` is wrong.

## Fixes

### Client (this repo)

1. **Treat any 4xx from `/auth/refresh` as rejection, not just 400.**
   `dio_client.dart:278` — `statusCode == 400` → `statusCode >= 400 && statusCode < 500`.
   A rejected refresh must `forceLogout` (login screen), never "retain".
2. **Refresh-before-gate in `OfflineSyncManager`.** Attempt token refresh
   up-front in `executeSyncTask` (or catch 401 from the gate explicitly and
   refresh + retry gate) before `PunchCoordinator.check`. Mirror the
   foreground behavior.
3. **Surface auth failure distinctly from `PunchCoordinator.check`.**
   Return a dedicated outcome (e.g. `PunchCheck.authFailed`) for 401 instead
   of folding it into `undecided`, so callers can refresh instead of
   burning retries.
4. **Fix `ApiEndpoints.me`** — point at the real profile endpoint
   (`/api/v1/employees/my-profile` exists in the same file) or remove the
   dead `me` fetch from `_tryAutoLogin`.

### Backend (separate repo)

5. Consider returning `400` (not `401`) for rejected refresh tokens — or keep
   `401` and rely on client fix #1. Pick one contract, document it.
6. Consider sliding refresh-token expiration (or refresh TTL > access TTL) so
   the day-30 double-expiry never strands active users. If both tokens share
   the same absolute 30d TTL, every monthly-active user hits the rejection
   path by design.

## Debug session

`.planning/debug/token-refresh-after-expiry.md` (evidence trail).
