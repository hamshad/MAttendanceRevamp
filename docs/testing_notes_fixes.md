# Testing Context — Attendance App Fixes

Purpose: maintain context of everything fixed so far. When a test fails, find
the related section below, report symptom + which scenario, then debug from
that anchor.

Debug session docs: `.planning/debug/resolved/` (token-flush-logout, wifi-duplicate-punch-out).

---

## 1. Token lifecycle / accidental logout — commit `47f1255`

6 bug paths around concurrent token refresh + logout cleared SP tokens mid-flight:

1. DIO interceptor + AuthProvider race — two 401s at once, both refresh, one
   gets a rejected refresh (server rotated token) → forceLogout.
2. `forceLogout`/`logout` called twice — 2nd call cleared freshly-written tokens.
3. Wrong-password login failure did `SharedPreferences.clear()` — wiped token
   backup used by geofence background worker.
4. Password-change 401 refresh failure → forceLogout mid-session.
5. `authGuard` (router) reading stale `authState` provider after logout → brief
   flash of login screen after successful login.
6. Token backup (`token_backup` box) cleared before logout navigation finished.

**Test signals:** app randomly logs out; login screen flashes after login;
geofence worker dies after wrong password attempt.

## 2. GPS auto-punch runs WITHOUT geofence permission — NOT YET FIXED

Auto-geofence background path checks **only the auth token**, never
`allowGeofenceAuto` permission:

- `main.dart:44-59` `_scheduleAlarmFromCachedShifts()` — token-only check
- `geofence_scheduler.dart:233` `startIfWithinShiftWindow()` — no check
- `geofence_background_worker.dart:828` `_isEnabled()` — only
  `geofence_auto_enabled` SP flag (defaults **true** via
  `main.dart:28-37` `_syncGeofenceFlag`, Hive `auto_punch_enabled`)
- Only gate: `main_shell.dart:164` `if (perms?.allowGeofenceAuto != true)`
  — stops only the foreground service

**Known symptom:** user WITHOUT geofence permission gets auto punched In/Out
with GPS records. Reported by real user before.

## 3. Offline queue sync via Workmanager — commit `a41763c`

- `offline_sync_manager.dart` — Workmanager tasks `offline_sync` (one-off on
  enqueue) + `offline_sync_periodic` (15 min safety net,
  `ExistingPeriodicWorkPolicy.keep`), `NetworkType.connected` constraint.
  Syncs chronologically (oldest first → server alternation correct).
- Manual offline punches are **GPS-only**: `dashboard_providers._queueOffline`
  rejects non-GPS; missing lat/lng → forced LocationService capture (3
  attempts); `sync_service._validate` (line 80-81) rejects `latitude == null`
  — the old bug that made queued GPS punches un-syncable.
- Duplicate drops: `_handleDioError` deletes punch on "Duplicate"/"already
  recorded"; 4xx → `retryCount=99` (dead); 5xx/network → retry.
- 401 refresh inside sync task via bg mirror keys (`bg_access_token`,
  `bg_refresh_token`, `bg_token_ts`).
- Cooldown persisted to Hive (`persistedLastPunchTime`) — survives restart.
- Same-direction guards on offline screen + `lastPendingDirection` (failed
  punches excluded).
- `OfflineSyncManager.cancel()` on `logout()`/`forceLogout()`.
- Registered in `main.dart` after `GeofenceScheduler.init()`; dispatcher in
  `geofence_scheduler.dart` routes task names.

## 4. Auto-punch offline queueing — commit `bf0d533` (NEWEST)

Design: *trigger = trust sensor, delivery = async.* Auto punches that fail on
no-connectivity now enqueue to the Hive offline queue instead of being dropped
(local SP pending-OUT kept only for legacy flush).

| Path | Behavior |
|---|---|
| Geo IN/OUT, no network / 5xx | queued (`GeofenceAuto` + lat/lng), local punch state updated → no re-trigger; 4xx → dropped, never queued |
| WiFi IN, no internet but wifi on | queued (`WiFi` + BSSID) |
| WiFi disconnect OUT, no network | queued (`WiFi` + office MAC), state set Out |
| Reconnect to registered wifi before sync | queued WiFi punches **cancelled** (`deleteQueuedByMethod('WiFi')` — disconnect never happened) |
| App killed while offline | punch in Hive, workmanager syncs on connectivity |
| Mixed manual + auto offline | single queue, chronological sync |

Mechanics:
- `field_tracking_service.dart` bg isolate now inits Hive + opens
  `offline_punch` / `cache` boxes (workers are plain Dart, had no Hive).
- `_isTransientError`: no-response (network/timeout) or 5xx → queue.
- Sync body carries `WifiMAC`/`WifiSSID` now.

**Known limitation:** queued geofence OUT that syncs after user already
re-entered office → server records OUT then IN (if re-IN also queued).
Chronological so net-correct; WiFi path handles via cancel-on-reconnect,
geofence relies on order.

## 5. Test scenarios

Scenario matrix (each: normal online, airplane-mode offline, app killed while offline):

1. **Manual offline punch** — punch IN offline via offline screen → airplane
   mode → reconnect → verify sync (order In→Out→In preserved).
2. **Auto geo IN offline** — geo enabled, wifi OFF, cellular OFF (airplane),
   enter office → expect queued IN → enable network → synced, no re-trigger
   duplicates.
3. **Auto wifi OUT offline** — punched IN via office wifi, airplane mode on
   wifi disconnect → expect queued OUT → network back → synced once.
4. **Wifi reconnect cancel** — airplane OFF at office wifi before sync →
   queued OUT cancelled, no spurious OUT.
5. **App killed offline** — queue punches, kill app, network back → workmanager
   syncs (check attendance records).
6. **Duplicate safety** — leave+reconnect wifi repeatedly → max 1 OUT per
   disconnect; no duplicate punch records.
7. **Mixed** — geo IN queued offline, then manual OUT offline → sync in
   chronological order → server alternates correctly.
8. **4xx rejection** — manual punch while GPS off / invalid state → NOT queued,
   clear error shown.

## 6. Known pre-existing failures (not caused by our changes)

- `geofence_scheduler_test.dart` — 3 failures, stale shift dates in tests
  (verified identical on unmodified code via git stash).
- `geofence_background_worker_test.dart` — 3 failures, same pre-existing.
- `wifi_auto_punch_service_test.dart` — load error (missing test infra).

## 7. Test infra notes

- `flutter analyze` clean (0 errors) on all our changes.
- Baseline comparison method: `git stash` → run test → `git stash pop`.
