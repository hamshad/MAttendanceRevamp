# Native-First Geofence: Battery & Reliability Architecture

> Status: **CONTRACTED 2026-08-14 (user decisions — we only make it
> STRONGER, never redesign)**; field-verified on user devices (446m /
> 104m / 80m late-EXIT incidents all fixed)
> Date: 2026-08-14 (updated; original 2026-08-11)
> Scope: Android auto-punch (iOS intentionally out of scope — user decision)

## Goal

- Native OS geofences do ALL auto-punching (battery-cheap, works with app dead)
- Background service kept only where a live isolate is genuinely required
- Zero or near-zero battery cost while punches stay reliable
- Reboot-safe self-healing without opening the app
- **Honest data**: every punch records the REAL detection location. We do
  NOT rewrite/snap coordinates (see "Honesty rule" below).

## Key architectural facts (verified in plugin source 2026-08-10/11)

1. `native_geofence-1.3.1` delivery is ALWAYS WorkManager headless: the
   manifest-registered `NativeGeofenceBroadcastReceiver` parses the transition
   and enqueues an expedited one-time work; `NativeGeofenceBackgroundWorker`
   spawns a **fresh FlutterEngine per event** and runs the Dart callback
   handle. There is NO live-isolate shortcut — a running service process does
   not change geofence delivery, it only makes WorkManager execute promptly
   (in-process, no cold start).
2. Geofences live in the Android system (GeofencingClient). Process death and
   battery restrictions do NOT remove them; only reboot and force-stop do.
3. `NativeGeofenceRebootBroadcastReceiver` re-registers persisted geofences on
   BOOT_COMPLETED (pure native, no Flutter needed).
4. The punch pipeline (GPS gate → zone identity → server-truth coordinator →
   POST → notification) runs identically in the headless isolate.

## Honesty rule (2026-08-13 — user decision, do not regress)

- Punch locations are the truth: OS crossing point or the reconcile confirm
  fix, **never snapped/rewritten**.
- `snapOutToBoundary` was added (e6ce478) to make late-OS-exit punches read at
  the boundary, then **removed** (8b6329e) when the user proved it lied: an
  ~80m actual walk-out logged 20m. Inconsistency between logs and reality is
  worse than an honest big number.
- The accurate-EXIT problem is solved at the source instead: movement-gated
  GPS in the keep-alive service catches the crossing itself (below).

## Design contract (user decisions — we only make it STRONGER, never "better")

Decided 2026-08-14 (Nothing 3a field session, after the `18f3e45`
mistake and its revert `835c2a7`). This is the agreed shape of the
geofence feature. Do NOT renegotiate, do NOT re-architect. All future
work = hardening within these decisions ("stronger"), never redesign
("better"). Any proposed shape change needs the user explicitly.

1. **IN = the simple headless path, permanently.** OS geofence ENTER
   fires at the crossing, dead-process safe → headless punch at the
   crossing point. IN was ALWAYS accurate this way (21m; even the one-off
   61m fused artifact was acceptable — close to radius). No service, no
   stream, no shift-window logic ever participates in IN again.
2. **OUT = FGS + movement stream while punched In (the walk-out
   monitor).** The FGS exists for exactly ONE job: deliver fixes at the
   boundary so OUT punches early and honest (~radius+25m fixed band,
   two-fix confirm, ≤ ~1 min after leaving). OUT was chronically late
   because OS EXIT fires late in Doze AND the reconcile had no fix at the
   right moment — the stream is the fix-delivery pipeline, not a faster
   process.
3. **FGS gated to punched-IN only.** OUT → unconditional stop → headless.
   Banner shows exactly while at work — never at home, nights, weekends
   or leave days. No timers in the service; movement-gated stream
   (distanceFilter 30m); stationary = zero fixes.
4. **Anti-fake layers stay — they are the only defense.** Android fused
   fixes blend GPS + wifi + cell (the 300-500m single-fix jump class) and
   geolocator exposes no provider → pure-GPS filtering is impossible.
   Fixed bands (IN radius+5m, OUT radius+25m), two-fix confirm,
   zone-identity gate, server-truth coordinator, accuracy trust floor.
   These cost an honest user nothing — they only delay fake crossings.
   Never strip, loosen or accuracy-widen them.
5. **Battery floor is the design, not a target.** OS geofence primary
   (~0); movement-gated streams, never timers; 15-min containment alarm
   (1 native wakeup / 15 min); FGS only while In; last-known-first +
   90s fix budget + wifi-proxy skip. Any change RAISING the floor needs
   user sign-off with measured numbers.
6. **The 15-min containment chain never rests while armed** (master
   enable = geofence auto on, punch-state independent — `82f2d0a`) and
   re-registers with `{enter}` catch-up (`f5a53dd`) = dead-process
   insurance for BOTH directions.
7. **Rejected designs — do not resurrect without the user:**
   - stream-based return-IN (premise falsified — IN never used the FGS
     stream; battery while away; `18f3e45` reverted `835c2a7`)
   - FGS surviving the OUT punch through the shift window (banner +
     battery outside punch state; same revert)
   - stripping/loosening the anti-fake layers ("jumps only happen on
     wifi, mobile data is clean") — fused-provider reality kills it
   - polling as the primary mechanism (rejected since day one)

Strengthening = defense depth, edge cases, battery efficiency inside
these shapes — verified by field evidence (logcat) before adding
machinery. Evidence first, always.

## Punch paths (all of them)

| Path | When | Battery | Notes |
|---|---|---|---|
| OS geofence ENTER/EXIT → WorkManager headless punch | Always (primary) | ~0 (OS fused location, no polling) | OS EXIT can fire late in Doze/battery-saver — see containment loop + keep-alive stream |
| App resume: reconcile + registerZones (initialTriggers re-fires ENTER catch-up) | App opened | ~0 | |
| Shift-start alarm fires headless → reRegisterFromHeadless() | 1 wakeup/day | ~0 | |
| **Containment loop** (below) | Every 15 min while armed | 1 native alarm wakeup / 15 min | Self-heals missed IN/OUT |
| **Keep-alive stream** | While punched in (all OEMs) | GPS only while moving ≥30m (0 fixes at desk) | Catches the EXIT OS/Doze drops |

### Containment loop (self-healing, all Android users)

- Native `ContainmentAlarmReceiver` (REQUEST_CODE 902) fires every 15 min
  while armed. Armed = `gf_containment_alarm_armed` — the MASTER ENABLE
  (geofence auto on), written by `_persistPunchState` on every punch,
  lifted at every shift start by `GeofenceAlarmReceiver`, cleared on
  disable/logout ONLY. Punch state never disarms it (the missed-IN net
  must stay alive exactly when Out+window).
- Alarm → WorkManager headless → `ContainmentCheckWorker.run()` →
  `reRegisterZonesFromCache(initialTriggers: {enter})` (re-registers dropped
  OS fences AND re-arms the catch-up ENTER — a punched-OUT phone already
  inside a zone re-fires ENTER fix-independently, the headless IN recovery
  for OEM-dropped/deferred transitions; own-source duplicates persist
  silently, no notification spam for a punched-IN user sitting inside) →
  `reconcileContainment(confirmOut: true)` (two back-to-back fixes, jump
  guard, honest confirm-fix location).
- `HeadlessAlignmentWorker._runInner()` does the same heal+reconcile.
- Aggressive OEMs (`aggressive_oem.dart` Dart + native list; `nothing`
  included `f5a53dd`): the alarm runs as an EXACT alarm (falls back to
  inexact if the permission is revoked); NO FGS revival — the FGS is
  sticky-close (`0c1ec2c`), the checker always enqueues the headless task.
  Non-aggressive OEMs: same headless WorkManager task.

### Keep-alive service (process-holder, ALL Android devices, punched-IN gated)

- `OemKeepAliveService` FGS (ID 889) runs when no feature needs the combined
  service, **all Android devices**, **gated to the punched-IN state**
  (user design: no banner outside actual work — Android requires a
  persistent notification on any FGS). Lifecycle is punch-driven from
  ANY isolate (`_persistPunchState`): IN punch → start; OUT punch →
  unconditional stop → back to headless (OS ENTER for IN, OS EXIT +
  15-min net for OUT). Disable/logout/takeover → same stop.
- **Why IN needs no service:** OS geofence ENTER is motion-assisted,
  fires even with a dead process (field-proven 12h+ without app open) —
  IN has ALWAYS been the headless path and stays that way; the 15-min
  containment catch-up (`{enter}` re-register, `f5a53dd`) is the
  dead-process backup for OEM-dropped ENTERs. The FGS exists for
  exactly ONE job — the walk-out monitor: OUT was chronically late
  because OS EXIT fires late in Doze/battery-saver AND the reconcile
  needed a fresh GPS fix at the right moment (indoor/poor GPS = no fix
  = wait). The stream delivers fixes continuously while walking, so the
  OUT decision has data at the boundary: honest OUT at ~radius+25m
  (fixed band, two-fix confirm), within ~a minute of leaving.
- **Movement-gated GPS stream** (`field_tracking_service.dart` keep-alive
  branch): `getPositionStream` high accuracy, `distanceFilter: 30` →
  stationary = zero fixes (no GPS churn); moving = fix every ~30m.
  First fix outside ALL office radii (`isOutsideAllOffices`, fixed
  radius+25m band) → immediate `reconcileContainment(confirmOut:true)`
  → honest OUT at the confirm fix. Stream self-cancels once punched out.
  (An IN-side "return monitor" was tried — `18f3e45` — and REVERTED:
  IN was always headless-at-point; the return-IN stream added battery
  without fixing anything. Anti-fake layers stay: Android fused
  locations blend wifi/cell positions (the 300-500m single-fix jump
  class), and the plugin exposes no provider — the layers are the only
  defense, and they cost an honest user nothing.)
- **Android 15 (API 35)+:** never start the FGS from `BOOT_COMPLETED` —
  `location`-type FGS start is banned there (throws
  `ForegroundServiceStartNotAllowedException`); the exact-alarm revive
  path is exempt, so BootReceiver skips the start and the containment
  alarm brings the service up within 15 min.
- **Headless WorkManager containment = the missed-ENTER/missed-EXIT net:**
  `gf_containment_alarm_armed` is the MASTER ENABLE (geofence auto on —
  written by `_persistPunchState` headless-safe, lifted every shift start
  by `GeofenceAlarmReceiver`, cleared on disable/logout). The 15-min
  chain never rests while armed (24/7 since `e624167` — the morning-IN
  net must be alive exactly when Out+window). Leave days: no shift alarm
  → no chain, no banner.
- **FGS lifecycle = punch state from ANY source** (strengthened 2026-08-17):
  `_persistPunchState` was the only writer that started/stopped the FGS —
  manual UI punches, the server-state mirror (`PunchStateInterceptor`,
  attendance poll) and offline queue flushes persisted `gf_last_punch_type`
  directly, so a manual OUT left "Geofence Active" stuck in the tray and a
  manual IN never armed the walk-out monitor.  New
  `OemKeepAliveService.syncToPunchState()` — cheap transition-gated
  start/stop — is called by all four non-geofence writers
  (`main_shell`, `PunchStateInterceptor`, `OfflineSyncManager`,
  `SyncService`).  No-op when nothing transitioned.
- **No timers in the service.** Two event-driven listeners added (2026-08-17):
  alignment warning streams — `getServiceStatusStream()` → GPS-off (996) and
  `onConnectivityChanged` → airplane/no-network (998) + wifi-hidden (997 on
  wifi (re)connect, 10-min rate limit). Pure event streams: wake only on an
  actual state change, never poll, never request a fix — battery contract
  intact (stationary = zero radio churn). Gated punched-IN + any auto (same
  gates as the headless worker). IDs/channel/prefs keys SHARED with the
  foreground monitor, headless worker and wifi worker (replace, never
  duplicate). Before this, the keep-alive FGS was deaf to GPS-off/airplane
  for geofence-only users: total silence until the ~30-min WorkManager fire
  (deferrable on aggressive OEMs). Stops on `stopKeepAlive` / `stop`.
- The combined service (tracking/wifi) is separate — `startIfWithinShiftWindow`
  force-stops keep-alive before starting it; never both.

## Service process (`flutter_background_service`, combined service)

- Runs ONLY when `serviceRequired()`: wifi auto-punch (bg|fg) or field tracking.
- **Geofence-only users: combined service never starts.** (`serviceRequired()`
  checks wifi bg/fg + field tracking only — NOT geofence auto or client sites.)
- Keep-alive FGS is a separate, lightweight service (all OEMs while punched
  in) — not the combined service.
- **Every service start path honors `serviceRequired()`** — WorkManager
  shift/restart tasks, the native `GeofenceAlarmReceiver` (0b729e3), and the
  Dart entrypoint itself (self-heal + stopSelf when geofence-only). No path
  may cold-start the combined service for a geofence-only user.
- `wifi_auto_punch_enabled_bg` defaults **false** (0ddb03a). It used to default
  true, which forced the combined service to start on shift start for
  geofence-only users.

## Alarms

- Shift-start alarm: armed for ALL users (service start for wifi/tracking;
  reboot-safe self-heal heartbeat for geofence-only). BootReceiver re-arms
  after reboot.
- Restart safety-net (+15 min): service users only.
- Containment alarm (15 min, REQUEST_CODE 902): all users while armed — see
  containment loop. Native exact alarm + keep-alive revival on aggressive OEMs.

## Battery principles

- OS fused geofence = primary detection (~0 cost). Never poll as primary.
- Movement-gated streams (distanceFilter) instead of timers wherever possible.
- One position reused for all offices; last-known reused when <10 min old;
  90s fix-budget window; WiFi-proxy skip (on registered office AP, wifi worker
  owns IN, reconcile skips GPS); stale-cache guard (>10 min never trusted).
- Keep-alive stream: high accuracy but distanceFilter 30 → battery only while
  walking.

## Honest OEM limits

| Barrier | Effect | Mitigation |
|---|---|---|
| Force-stop (Settings) | Geofences removed + broadcasts blocked until app reopened | OS design, uncodable; fg service running prevents it |
| MIUI / aggressive OEM without autostart + battery exemption | Boot broadcasts blocked, alarms cleared, WorkManager throttled → nothing runs until app opened once | Autostart + battery-exemption onboarding (exists); after one open, heartbeat + resume re-register take over |
| MIUI with exemptions | Everything works | Keep-alive FGS + exact containment alarm guarantee in-process execution |
| Battery restrictions (tolerant OEMs) | Headless punch proven working (user device test) | — |
| Late OS EXIT (Doze/battery-saver) | OUT punches far past boundary (446m/104m/80m incidents) | Containment loop + keep-alive movement-gated stream punch near the crossing; location stays honest either way |

## Zone persistence & identity

- Zones persisted as JSON under `gf_zone_ids` / `gf_zone_$id`
  (`GeofenceZone.toJson/fromJson`). Registered from the main isolate by
  MainShell, re-registered/healed by: resume, containment alarm, alignment
  worker, keep-alive start, shift-start alarm.
- OUT zone-identity gate: only the fence the user is actually punched into
  may punch OUT (spurious batch exits when a provider drops).
- Server-truth gate: `PunchCoordinator.check` runs FIRST in `_executePunch`
  (server decides; local gate only when server unreachable; offline queue).

## Key files

- `lib/features/punch/services/geofence_monitor.dart` — event pipeline,
  reconcile, `_executePunch`, zone persistence, `GeofenceZone`
- `lib/features/punch/services/geofence_scheduler.dart` — alarms,
  `serviceRequired()`, `ContainmentCheckWorker`
- `lib/features/punch/services/wifi_background_worker.dart` — wifi IN,
  `_isEnabled()` default false
- `lib/features/tracking/services/field_tracking_service.dart` — combined
  service + keep-alive branch, `keepAliveOfficeZones`/`isOutsideAllOffices`
- `lib/features/punch/services/oem_keep_alive_service.dart` +
  `lib/core/utils/aggressive_oem.dart` — keep-alive FGS + OEM matcher
- `android/app/src/main/kotlin/com/mattendance/mattendance_mobile/` —
  `ContainmentAlarmReceiver.kt`, `MainActivity.kt`, `BootReceiver.kt`
- Tests: `test/features/punch/services/geofence_monitor_test.dart`,
  `test/features/tracking/services/keep_alive_monitor_test.dart`,
  `test/core/utils/aggressive_oem_test.dart`,
  `test/features/punch/services/geofence_scheduler_test.dart`

## Change log

| Commit | Change |
|---|---|
| `2ecf01a` | Resume-time registerZones self-heal (OEM drops, stale callback handle, ENTER catch-up) |
| `d0e03ee` | GPS+ wakeup budget: single fix/offices, last-known-first, 90s budget, wifi-proxy skip, poll 15s→60s, BSSID confirm 30s→90s |
| `d5dfcab` | Phase 2: geofence-only = no service process, no restart alarm (`serviceRequired()` gate) |
| `7c61ebe` | Shift-start alarm = reboot-safe heartbeat: headless `reRegisterFromHeadless()` self-heal |
| `9abc3f7`/`16bddfc`/`45e0d96` | Notification hygiene, confirmOut recovery, containment alarm |
| `6a1f670` | Keep-alive FGS + `AggressiveOem` matcher for MIUI & friends |
| `68ce662` | Zone self-heal in containment alarm + alignment worker (`registerZones(initialTriggers: {})` before reconcile) |
| `0ddb03a` | `wifi_auto_punch_enabled_bg` default → false (fixes service start leak) |
| `e6ce478` | snapOutToBoundary added (cosmetic boundary snap) |
| `8b6329e` | **Snap removed** (honesty rule) + movement-gated keep-alive GPS stream; zone identity + server-truth gates preserved |
| `0b729e3` | **Native shift-start alarm gated**: `GeofenceAlarmReceiver` no longer starts the combined service when `serviceRequired()` is false (geofence-only = headless self-heal); Dart entrypoint self-heal+stop defense-in-depth |
| `ef0ce33` | **Universal OUT monitor + tight IN band**: keep-alive FGS + movement stream now run on ALL OEMs while punched in (not just aggressive): Nothing/stock Android get boundary-accurate OUT too (was 15-min containment fallback at 149m); IN margin capped at `min(2×accuracy, radius)` — a 20m-radius office can no longer punch IN at 61m |
| `77eb8af` | **IN band tightened to 1.5x radius**: IN margin cap `min(2×accuracy, radius)` → `min(2×accuracy, radius/2)` — 20m-radius office punches IN within 30m (user decision) |
| `ab070de` | **Fixed punch bands (user spec)**: IN = `radius+5m` fixed (25m @ 20m office, 105m @ 100m office — never 150m), accuracy as trust floor (fixes claiming worse than the radius defer to the OS crossing point); OUT = `radius+25m` fixed (45m) with two-fix confirmation; stream trigger mirrors OUT band. Accuracy never widens either band — the 2×accuracy margins caused the 61m IN and the delayed 149m OUT |
| `72bf9d7` | **Keep-alive FGS = aggressive OEMs only** (user spec: no "Geofence Active" banner — Android requires a persistent notification for any FGS): non-aggressive OEMs run headless (OS geofence + 15-min containment alarm; OUT punches at the alarm fire with the fixed 45m band); movement-gated stream stays for aggressive devices |
| `8dc7894` | **Keep-alive FGS time-gated** (user spec: no banner outside work): aggressive OEM AND (punched in OR within shift window) — `keepAliveActive()`/`_withinShiftWindow()`; night/weekend = zero banner, containment alarm revives the FGS within 15 min when needed. **Android 15+ fix**: BootReceiver no longer starts the FGS from `BOOT_COMPLETED` (location-type FGS start banned on API 35+ — exact-alarm revive path exempt); also stops `was_field_tracking` full-service start from being clobbered by the keep-alive mode flag |
| `47130be` | **Keep-alive FGS on ALL devices** (user decision — uniform behavior, no headless-only OEM split): `AggressiveOem` gate dropped from Dart start + `keepAliveActive()`; headless WorkManager containment demoted to fallback when the FGS can't start; Android 15 boot guard now applies device-wide |
| `8787c56` | **FGS punched-IN only (user design)**: time-gate (shift window) replaced by punch-state lifecycle — `_persistPunchState` starts the FGS on IN, stops it on OUT (banner exists exactly while at work; IN needs no service, field-proven). Keep-alive gate = armed && In; GeofenceAlarmReceiver arms the containment chain at every shift start while geofence auto is on (headless ENTER punch can't reach the Dart MethodChannel to bootstrap it); `_withinShiftWindow` (Dart) removed |
| `82f2d0a` | **Work-hours gating restored + containment-chain bug fix** (user spec: correct punching absolute, FGS OK if no banner outside work/leave days): FGS gate = (In OR shift window) on all devices; OUT punch keeps idle FGS through work hours, receiver closes at first post-window fire. **Chain fix**: armed flag is now the MASTER ENABLE (geofence auto on) — was cleared on OUT punch, killing the missed-ENTER net exactly when OUT+window needed it (candidate cause of the 2026-08-14 morning IN miss after `8787c56`); GeofenceAlarmReceiver lifts it + arms every shift start; chain rests outside window, re-armed next shift start; leave days → no shift alarm → no chain, no banner |
| `10197aa` | **Leave-day gate (shift-today marker) + keep-alive takeover fix** (proofread findings): (1) `OemKeepAliveService.stop()` gained a work-hours early-return in `82f2d0a` but service-takeover callers relied on it to clear the keep-alive MODE flag — while In/window the stop no-oped and the combined service started in keep-alive (light) mode instead of full wifi+tracking. `stop({force})` now force-cleans on takeover (`FieldTrackingService.start()` + main_shell + scheduler); OUT punch keeps the smart gate. (2) Leave-day banner: the daily shift-start alarm arms the 15-min chain from stale prefs (end = last workday), so leave days ran the chain + FGS + banner. Date-scoped marker `gf_shift_today`/`gf_shift_today_date`: written FALSE when the app loads an empty shift list (leave day), TRUE on any server-accepted punch. Native `shiftToday()`/Dart gate suppress chain arm + keep-alive FGS + window checks only when the marker is freshly FALSE today; STALE marker defaults TRUE (workday) — the headless morning-IN net must survive days without app opens; banner suppression is inherently unavailable without fresh server truth (documented limitation). Tests 173→189, analyze 0 errors |
| `e624167` | **Headless-IN-anytime + 24/7 checker (user design)**: IN is the always-available headless path (OS geofence ENTER, dead-process-safe) — no FGS, no window, no shift dependency. The 15-min containment chain NEVER rests while armed (master enable): every fire re-registers the OS geofences from PERSISTED zone metadata — NEW `reRegisterZonesFromCache()` (no network; `registerZones` fetches offices via API and is banned from 15-min cadence — would be 96 requests/day) — and re-checks containment (last-known-first + fix budget; no GPS when away). Permanently closes the morning-IN-miss class (the pre-`e624167` chain rested Out+outside-window, leaving the missed-ENTER net dead). FGS is punched-IN ONLY (walk-out monitor): `startIfNeeded` gate = In, native `keepAliveActive` = armed && In, OUT punch stops the service unconditionally (`stop()` force/work-hours semantics dropped) → back to headless IN. Banner exactly at work. Alignment warnings already In-gated. Leave-day marker (10197aa) removed — dead under punch-state gating (leave days never punch server-side). Battery honesty: ~96 light prefs-read wakeups/day while geofence auto on. Tests 189→173 (window/marker tests removed), analyze 0 errors |
| `0c1ec2c` | **Sticky-close FGS (user design)**: if the user closes the keep-alive FGS it stays closed — no banner behind their back — and headless OUT covers it. Removed the checker's FGS-revival branch (was: `startForegroundService` every 15-min fire while In; headless task only as fallback) and BootReceiver's post-reboot revival. Checker now always enqueues the headless task: OS geofence EXIT is the primary headless OUT path, the 15-min reconcile guarantees OUT within one interval (fixed 45m band, two-fix confirm). FGS lifecycle purely punch-state: starts on IN punch, stops on OUT/disable/logout. Bonus: no more close→revive→banner loop or its engine-spawn battery cost; also sidesteps the API 35+ boot FGS ban entirely |
| `f5a53dd` | **Headless catch-up ENTER restored on the containment + alignment workers** (Nothing 3a missed-IN fix): both workers now `reRegisterZonesFromCache(initialTriggers: {enter})` — re-registering re-fires OS ENTER for a phone already inside a zone, so a punched-OUT user whose ENTER was OEM-dropped/deferred gets a fix-independent headless IN within one 15-min interval (the reconcile alone was fix-dependent — indoor high-accuracy GPS fails on the Nothing — and the app-open IN came from foreground reconcile). Own-source duplicates persist silently (no notification spam for a punched-IN user inside; the resume-path `{}` rationale predates the silent-echo handling). Catch-up ENTER fires only when genuinely inside the radius — no far-away IN class (honesty rule, `ab070de`). Also added `nothing` to `AGGRESSIVE_BRANDS` (Dart + native): Nothing defers inexact alarms, so the checker's alarm is now exact-alarm on Nothing (falls back to inexact if the permission is revoked). Debug: `.planning/debug/resolved/nothing-fgs-not-stop-in-missed.md` |
| `18f3e45` | **At-point background IN restored (user spec: "IN should work at point")** — the Nothing-class fix on top of `f5a53dd`'s 15-min net: the keep-alive FGS + movement-gated stream are back after an OUT punch while the shift window is open, so the return-IN punches AT POINT (~radius+5m, first honest inside fix — the Aug-8-proven 21m IN). `8787c56` had restricted the FGS to punched-IN only, killing the stream exactly when the return-IN needed it. Changes: `startIfNeeded` banner gate = (In OR within window); `_persistPunchState` OUT → smart `stop()` keeps/starts the FGS within the window (covers the headless-OUT case — process dead — by (re)starting it), closes past the window; keep-alive stream dual-mode: walk-out monitor (In) + return-IN monitor (Out, `isInsideAnyOffice` radius+5m band → `reconcileContainment()`); past `gf_shift_end_time` (stale/absent = past, fail-safe) the stream closes the FGS — banner never outside work. Takeover/disable/logout still `stop(force:true)`. OS ENTER + the 15-min catch-up net remain the dead-process backup. Unit tests: `isInsideAnyOffice` (IN band never widened by accuracy), `shouldKeepAliveAfterOut` (geofence off / window / punch-type gates). Tests 173→183, analyze 0 errors. Debug: `.planning/debug/nothing-in-at-point.md` — **REVERTED by `835c2a7`**: the stream-return-IN premise was false (IN was always headless-at-point on the Nothing; the FGS never carried IN), it added battery (stream ran while away) without fixing anything |
| `835c2a7` | **Revert of `18f3e45` — IN stays headless (user correction, premise falsified)**: the at-point IN never came from the FGS stream — IN was always the straightforward headless OS ENTER path (accurate, dead-process safe) and OUT the late one; the FGS exists ONLY as the walk-out monitor (OUT-accelerator: stream delivers fixes at the boundary → honest OUT ~radius+25m within a minute). Restored: `startIfNeeded` In-only gate, unconditional `stop()` on OUT, In-only stream self-cancelling on OUT, plain `stop()` on takeover/disable/logout. Kept from `f5a53dd`: catch-up ENTER net + Nothing exact alarm (zero-battery dead-process IN insurance). Anti-fake layers stay — Android fused fixes blend wifi/cell (300-500m jump class), plugin exposes no provider, so bands + two-fix + zone-identity are the only defense and cost honest users nothing. Tests 183→173, analyze 0 errors. Debug: `.planning/debug/resolved/nothing-in-at-point.md` |
| (pending) | **OUT accuracy TRUST FLOOR + honest offline punches + divergence self-heal (2026-08-17 field evidence)**: (1) NEW `lib/core/utils/geo_bands.dart` — `isOutsideOfficeBand` = distance beyond `radius+slack` AND fix accuracy ≤ the band (45m @ 20m office). Applied to ALL FOUR OUT paths (keep-alive stream `isOutsideAllOffices`, `_reconcileOut` confirmOut + insideAny, `_verifyTransition` fresh-fix, crossing branch). Closes the false-OUT class: a fused wifi-blend fix at 68m beyond the radius claiming 120m accuracy can no longer punch OUT while the user sits inside (old dist-only check believed it). Accuracy NEVER widens bands (`ab070de` intact); the floor only ADDS a defer. (2) Honest queued punches: `_executePunch` POST-fail + queue → notification now says "Auto-Punched Out (offline) — syncing when online" instead of claiming the server recorded it; undecided-IN queue likewise. (3) Duplicate-divergence deadlock closed: user's field session showed queued OUT + server-still-In → return ENTER silently skipped as duplicate, queue never flushed. `_executePunch` now snapshots local punch type BEFORE persist, and on own-source echo with divergence flushes the queue (`scheduleNow`) + notifies "Server already shows — offline punches syncing"; already-confirmed-locally skip added before the server call. Tests 173→180, analyze 0 errors. Debug: `.planning/debug/xiaomi-in-missed.md` |
| (pending) | **Alignment warnings in the keep-alive FGS (2026-08-17 user report)**: geofence-only users got NO GPS-off/airplane warnings while the FGS ran — warnings lived only in the combined service, foreground monitor and ~30-min headless WorkManager (deferrable on aggressive OEMs). Keep-alive branch now runs two event-driven streams (`getServiceStatusStream` → 996, `onConnectivityChanged` → 998 + wifi-hidden 997 rate-limited 10 min), punched-IN + any-auto gated, shared IDs/channel/keys with the other monitors (replace, never duplicate), cancelled on stop. No timers, no polling, no fixes — battery contract intact. Tests 180, analyze 0 errors |
| (pending) | **FGS lifecycle on ALL punch sources (2026-08-17 user report)**: FGS stayed running after a manual OUT (banner "Geofence Active" stuck in the tray); manual IN never started the walk-out monitor. Only the geofence persist path wired start/stop — manual UI, server-state mirror (`PunchStateInterceptor`), attendance poll and offline queue flushes wrote `gf_last_punch_type` directly. New `OemKeepAliveService.syncToPunchState()` (transition-gated, no-op when unchanged) called from `main_shell`, `PunchStateInterceptor`, `OfflineSyncManager._publishLocalState`, `SyncService._publishLocalState`. Confirms the contracted shape: native IN headless 24/7, FGS = walk-out monitor EXACTLY while punched IN, closed on any OUT. Tests 180, analyze 0 errors |

## Verification

- Full suite 173/173 (`flutter test`)
- `flutter analyze`: 0 errors (pre-existing infos/warnings only)
- Field-tested: 446m → ~20m (containment loop), 104m → boundary (snap, then
  reverted), 80m-actual-vs-20m-logged inconsistency → snap removed + live
  stream (in testing)
