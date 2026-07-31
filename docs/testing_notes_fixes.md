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

## 2. GPS auto-punch runs WITHOUT geofence permission — FIXED in `1b3ea5f` (pending commit)

Root cause: auto-geofence background path checked only the auth token, never
`allowGeofenceAuto` permission.

- `main.dart:44-59` `_scheduleAlarmFromCachedShifts()` — token-only check
- `geofence_scheduler.dart:233` `startIfWithinShiftWindow()` — no check
- `geofence_background_worker.dart` `_isEnabled()` — only
  `geofence_auto_enabled` SP flag (defaults **true** via
  `main.dart:28-37` `_syncGeofenceFlag`, Hive `auto_punch_enabled`)
- Only gate: `main_shell.dart:164` `if (perms?.allowGeofenceAuto != true)`
  — stopped only the foreground service

**Fix (4 files, non-breaking):**
- `accessPermissionsProvider` mirrors `allowGeofenceAuto` → SP key
  `bg_allow_geofence_auto`. Written ONLY on successful fetch — a transient
  fetch failure never revokes a permitted user.
- Worker `_isEnabled()` now also requires `bg_allow_geofence_auto != false`.
  Flag ABSENT (never fetched / offline) → allowed (legacy behavior — the
  safety valve so geofence keeps working for permitted users).
- `main.dart` cold start skips alarm/service when flag definitively false.
- `_initGeofence()` distinguishes perms-null (loading → do nothing) from
  definitive denial → cancels shift alarms + `notifyGeofenceToggle()`, stops
  combined service only when field tracking is off too.
- NOT gated: workmanager shift/restart alarm service-start (shared with
  field tracking + wifi workers — gating would break them).

**Test signals:** user WITHOUT geofence permission → no auto punches (worker
gated). User WITH permission → unchanged.

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

## 6. Home screen load time — `uncommitted` (performance, not a bug fix)

Cold-start blockers found + fixed:

1. **`Firebase.initializeApp()` awaited before `runApp()`** — blocks first
   frame seconds on slow networks (config/metadata fetch). Now deferred:
   `unawaited(Firebase.initializeApp().then(...))`; FCM background handler
   registered once ready. `_initFCM()` in MainShell waits for
   `Firebase.apps.isNotEmpty` (max 8s) so push registration never races it.
   → first frame renders immediately; push unaffected.
2. **`attendanceStatusProvider` cache was last-resort** — fetch → fail →
   800ms delay → retry → fail → cache. Skeleton showed the whole time, and
   every `ref.invalidate` (app resume, punch event) flashed loading.
   Now **cache-first + stale-while-revalidate**: today's cached status
   renders instantly, `_refreshInBackground()` swaps in fresh data when it
   arrives. No skeleton flash on open or resume.
3. `refresh()` (pull-to-refresh) also cache-first — keeps UI stable.
4. **Splash blank-with-loader on EVERY open** — `AppUser.load()` did 7
   SEQUENTIAL `FlutterSecureStorage` reads (encrypted storage, each
   50-300ms+ on Android) → ~1-2s blank splash per open.  Now:
   - Hive fast-read mirror (`cached_user` in cacheBox) → load is
     near-instant on open; secure storage stays source of truth on write
   - cold path (first open after update): 7 reads run in PARALLEL + lazy
     backfill to Hive so next open skips secure storage
   - `clear()` also deletes the Hive mirror (logout stays clean)

### Benchmark (emulator, `am start -W`, cold start)

| Phase | Debug | Release |
|---|---|---|
| Hive boxes (parallel) | 595-757ms | 343-757ms (IO variance) |
| runApp (all pre-work) | ~700ms | 350-830ms |
| hasTokens | 68-560ms | 113-430ms (1 secure read) |
| AppUser.load | 0ms | **0ms** (Hive mirror) |
| First frame (TotalTime) | 1900-2030ms | **666-1563ms** (engine variance) |
| Status fetch (warm cache) | — | 380ms, renders instantly (cache-first) |

Debug builds are ~2x slower (JIT) — always benchmark RELEASE for real
numbers. Remaining cold-start cost is Hive init + engine start (emulator
IO-bound, real devices faster). `[BENCH]` prints remain in code for
re-measuring.

**Test signals:** cold start reaches home fast even on slow network; home
shows yesterday-free real data instantly (same-day cache) then updates;
resume no longer flashes skeletons. Push notifications still register
(device token in backend). If push token registration stops working →
check `_initFCM` wait loop (Firebase.apps never becomes non-empty).

Not touched: workmanager registrations, field tracking init (kept awaited —
background service registration must precede scheduling).

## 7. Known pre-existing failures (not caused by our changes)

- `geofence_scheduler_test.dart` — 3 failures, stale shift dates in tests
  (verified identical on unmodified code via git stash).
- `geofence_background_worker_test.dart` — 3 failures, same pre-existing.
- `wifi_auto_punch_service_test.dart` — load error (missing test infra).

## 8. Test infra notes

- `flutter analyze` clean (0 errors) on all our changes.
- Baseline comparison method: `git stash` → run test → `git stash pop`.
