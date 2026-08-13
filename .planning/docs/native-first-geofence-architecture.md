# Native-First Geofence: Battery & Reliability Architecture

> Status: implemented, field-verified on user devices (446m / 104m / 80m
> late-EXIT incidents all fixed)
> Date: 2026-08-13 (updated; original 2026-08-11)
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
  while armed: armed = `gf_containment_alarm_armed` flag AND (punched In OR
  in shift window). `_persistPunchState` flips the flag on every punch.
- Alarm → WorkManager headless → `ContainmentCheckWorker.run()` →
  `registerZones(initialTriggers: {})` (re-registers dropped OS fences) →
  `reconcileContainment(confirmOut: true)` (two back-to-back fixes, jump
  guard, honest confirm-fix location).
- `HeadlessAlignmentWorker._runInner()` does the same heal+reconcile.
- On aggressive OEMs the receiver additionally revives the keep-alive FGS and
  uses exact alarms (mode flag `gf_keep_alive_mode`). Non-aggressive OEMs:
  headless WorkManager task only — no foreground service, no banner.

### Keep-alive service (process-holder on aggressive OEMs only)

- `OemKeepAliveService` FGS (ID 889) runs when no feature needs the combined
  service, **aggressive OEMs only** (MIUI/Redmi/POCO/Honor/Oppo/Realme/
  OnePlus/Vivo): always, as process holder — these ROMs won't spawn the app
  from background, and the service holding the process is what makes
  geofence/alarm/WorkManager work. Started/revived by main isolate,
  containment alarm (exact alarm), BootReceiver.
- **Other OEMs NEVER get the keep-alive** (user spec: no "Geofence Active"
  banner — Android requires a persistent notification for any foreground
  service). Stock Android runs the OS geofence + the headless 15-min
  containment alarm with no process holding; with the fixed 45m OUT band the
  alarm punches at ~boundary+25m, worst-case one alarm interval late.
- **Movement-gated GPS stream while punched in** (`field_tracking_service.dart`
  keep-alive branch, aggressive devices): `getPositionStream` high accuracy,
  `distanceFilter: 30` → stationary desk = zero fixes (no GPS churn); walking
  out = fix every ~30m. First fix outside ALL office radii
  (`isOutsideAllOffices`, fixed radius+25m band) → immediate
  `reconcileContainment(confirmOut:true)` → honest OUT at the confirm fix.
  Stream self-cancels once punched out.
- No timers. Stops on `stopKeepAlive` / `stop`.
- The combined service (tracking/wifi) is separate — `startIfWithinShiftWindow`
  stops keep-alive before starting it; never both.

## Service process (`flutter_background_service`, combined service)

- Runs ONLY when `serviceRequired()`: wifi auto-punch (bg|fg) or field tracking.
- **Geofence-only users: combined service never starts.** (`serviceRequired()`
  checks wifi bg/fg + field tracking only — NOT geofence auto or client sites.)
- Keep-alive FGS is a separate, lightweight service (all OEMs while punched
  in; aggressive OEMs always as process holder) — not the combined service.
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
| `[keep-alive revert]` | **Keep-alive FGS = aggressive OEMs only** (user spec: no "Geofence Active" banner — Android requires a persistent notification for any FGS): non-aggressive OEMs run headless (OS geofence + 15-min containment alarm; OUT punches at the alarm fire with the fixed 45m band); movement-gated stream stays for aggressive devices |

## Verification

- Full suite 173/173 (`flutter test`)
- `flutter analyze`: 0 errors (pre-existing infos/warnings only)
- Field-tested: 446m → ~20m (containment loop), 104m → boundary (snap, then
  reverted), 80m-actual-vs-20m-logged inconsistency → snap removed + live
  stream (in testing)
