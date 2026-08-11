# Native-First Geofence: Battery & Reliability Architecture

> Status: implemented (commits below), pending field test by user
> Date: 2026-08-11
> Scope: Android auto-punch (iOS intentionally out of scope — user decision)

## Goal

- Native OS geofences do ALL auto-punching (battery-cheap, works with app dead)
- Background service kept only where a live isolate is genuinely required
- Zero or near-zero battery cost while punches stay reliable
- Reboot-safe self-healing without opening the app

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

## Current architecture (post-changes)

### Punch paths
| Path | When | Battery |
|---|---|---|
| OS geofence ENTER/EXIT → WorkManager headless punch | Always (primary) | ~0 (OS fused location, no polling) |
| App resume: reconcile + registerZones (initialTriggers re-fires ENTER catch-up) | App opened | ~0 |
| Shift-start alarm fires headless → reRegisterFromHeadless() | 1 wakeup/day | ~0 |

### Service process (`flutter_background_service`)
Runs ONLY when `serviceRequired()`: wifi auto-punch (bg|fg) or field tracking.
Geofence-only users: service never starts, restart safety-net never arms.

### Alarms
- Shift-start alarm: armed for ALL users (service start for wifi/tracking;
  reboot-safe self-heal heartbeat for geofence-only). BootReceiver re-arms
  after reboot.
- Restart safety-net (+15 min): service users only.

### Battery budget in the 60s poll (wifi/tracking users)
- One position reused for all offices (was one fresh fix per office per poll)
- Last-known position reused when <10 min old (stationary = 0 GPS fixes)
- 90s fix-budget window between fresh fixes
- WiFi-proxy skip: on registered office AP, wifi worker owns IN, reconcile skips GPS
- Stale-cache guard: >10 min old cache never trusted (can't fabricate visits)

## Change log

| Commit | Change |
|---|---|
| `2ecf01a` | Resume-time registerZones self-heal (OEM drops, stale callback handle, ENTER catch-up) |
| `d0e03ee` | GPS+ wakeup budget: single fix/offices, last-known-first, 90s budget, wifi-proxy skip, poll 15s→60s, BSSID confirm 30s→90s |
| `d5dfcab` | Phase 2: geofence-only = no service process, no restart alarm (`serviceRequired()` gate) |
| `7c61ebe` | Shift-start alarm = reboot-safe heartbeat: headless `reRegisterFromHeadless()` self-heal |

## Honest OEM limits

| Barrier | Effect | Mitigation |
|---|---|---|
| Force-stop (Settings) | Geofences removed + broadcasts blocked until app reopened | OS design, uncodable; fg service running prevents it |
| MIUI / aggressive OEM without autostart + battery exemption | Boot broadcasts blocked, alarms cleared, WorkManager throttled → nothing runs until app opened once | Autostart + battery-exemption onboarding (exists); after one open, heartbeat + resume re-register take over |
| MIUI with exemptions | Everything works | — |
| Battery restrictions (tolerant OEMs) | Headless punch proven working (user device test) | — |

## What geofence-only users lost (accepted tradeoffs)

- Background alignment warnings (no-connectivity / hidden-BSSID) → foreground
  only today; **Phase 5 restores natively**
- Offline queue flush on connectivity return → syncs on next app open
- Missed-IN/OUT GPS recovery via poll → covered by native events + resume
  reconcile

## Verification

- Full suite 119/119 (`flutter test`)
- `flutter analyze`: 0 errors (pre-existing infos only)
- Not yet field-tested (user testing now)
