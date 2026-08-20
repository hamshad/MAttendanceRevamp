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

## 9. User alignment layer (employee-facing warnings)

Purpose: employees do things that quietly break auto punch (GPS off,
airplane mode, revoking "Allow all the time", location hiding WiFi names).
The app now warns them in plain words + tells them the tap-path fix.

**Architecture — `lib/features/alignment/`:**
- `AlignmentMonitor` (singleton, main isolate): subscribes GPS service-status
  stream + connectivity stream, polls `Geolocator.checkPermission()` every
  1 min + on app resume. Owns the PERMISSION alert (bg workers can't detect
  permission changes). Surface: in-app dialog (critical, app open) /
  heads-up notification (app backgrounded, id 999) / home banner.
- Background isolate owns the other three popups (keeps running when app
  killed):
  - GPS off (id 996, `field_tracking_service.dart` gpsStatusSub) — now also
    fires for wifi-only users, not just geofence.
  - No connectivity / airplane mode (id 998, `wifi_background_worker.dart`
    `_onConnectivity` none-branch, transition-gated via prefs flag).
  - WiFi connected but BSSID hidden (id 997, same worker `_checkCurrentWifi`
    bssid-null branch, 10-min cooldown).
- Notification IDs shared main↔bg so both sides REPLACE not duplicate.
- Home banner (`AlignmentBanner`): persistent alert list, warnings
  dismissible per session, critical stay until fixed. Refresh on resolution.
- `user_alignment` high-importance channel created in `main()`.

**Fixed bug in the same change (false punch-OUT):** `_checkCurrentWifi`
previously called `_handleDisconnect()` when BSSID was null WHILE
connectivity confirmed WiFi was connected — GPS off (Android hides BSSID
when location off) punched employees OUT while sitting at the office.
Now: bssid-null while connected = warn + skip. Foreground
`wifi_auto_punch_service._checkCurrentConnection` catch does the same
(verify `Connectivity` before flushing pending OUT / punching OUT).
Android platform truth: SSID/BSSID unreadable unless location permission +
location services ON (SSID since API 29, BSSID since API 31).

**Alert copy (employee-facing, human):**
- GPS off (🔴): "Auto punch won't work and you could be marked absent even
  at the office. Turn Location back on." → Fix: open Location settings.
- Permission (🔴): "Allow location 'All the time'" — auto punch stops when
  app closed. → Fix: app settings.
- Airplane (🟠): "No network (airplane mode?) — WiFi punches will be saved
  and sent when you're back online." (no fix button; swipe-down instruction
  in bg notification body).
- WiFi hidden (🟠): "Connected to WiFi, but the app can't read it — turn on
  Location so auto punch can confirm the office network." → Fix: Location.

**Manual test scenarios (physical device):**
1. Geofence on → toggle GPS off → expect heads-up "GPS is off" (id 996)
   + banner on home; toggle on → notification dismissed + banner gone.
2. WiFi auto on → toggle airplane mode → expect "No network" popup (998);
   turn off airplane → popup clears.
3. WiFi auto on + GPS off while connected to office WiFi → expect
   "Connected to WiFi, but the app can't read it" (997) + NO auto punch OUT
   (was the bug). Turn GPS on → popup clears, auto punch resumes.
4. Geofence/field tracking on → revoke location to "While using" → open app
   → permission dialog + banner. Grant "All the time" → clears.
5. All alerts resolve → banner empty, notification shade clean.

**Emulator verification (API 36, `emulator-5554`):**
- GPS off → notification 996 posted on `user_alignment` (importance 4,
  sound+vibrate), `[ALIGN] alert active: gps_off` + in-app dialog shown.
  PASS.
- Airplane mode on → notification 998 posted; off → `alert resolved:
  no_connectivity` + banner cleared. PASS. (Found + fixed a race here:
  `_warnNoConnectivity` fired before `_checkCurrentWifi → _handleDisconnect`,
  which cancelled the popup instantly; `_handleDisconnect` no longer clears
  the no-connectivity warning.)
- Revoke FINE location while on WiFi → `[ALIGN] alert active: wifi_hidden`
  + banner (997). PASS, and no false punch-OUT.
- Permission alert (999): NOT emulator-testable end-to-end. `field_tracking_enabled`/`geofence_auto_enabled` are app-managed (auto-false when not punched in; Hive box for geofence can't be seeded via prefs file — `_syncGeofenceFlag` overwrites the SP copy from Hive each boot). In-session revoke while tracking active should be verified on a physical device (scenario 4). The 999 branch shares the exact `_setOrClear` dialog/notification machinery proven by the GPS-off test.
