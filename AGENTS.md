# Project Memory — mAttendance Mobile

Context for any agent working in this repo. Architecture docs live in
`.planning/docs/` — READ before touching auto-punch / tracking / geofence code.

## Must-read before geofence/punch/tracking changes

- `.planning/docs/native-first-geofence-architecture.md` — the canonical
  architecture: punch paths, containment loop, keep-alive service, battery
  principles, honest-OEM limits, change log.
- `.planning/docs/device-gps-accuracy-plan.md` — accuracy/uncertainty model.
- Debug incident records: `.planning/debug/` (resolved → `resolved/`).

## Hard invariants (do not regress)

1. **Honesty rule**: punch locations are the REAL detection point (OS
   crossing or confirm fix). NEVER snap/rewrite coordinates. The old
   `snapOutToBoundary` was added then removed on purpose (commit `8b6329e`).
2. OS geofence ENTER/EXIT → WorkManager headless is the PRIMARY punch path.
   Never replace it with polling as the primary mechanism.
3. Geofence-only users must NOT get the combined background service
   (`serviceRequired()` checks wifi bg/fg + field tracking only). The
   keep-alive FGS is separate and lightweight: **all Android devices,
   gated to work hours** (punched IN OR within shift window — Android
   requires a persistent notification for any FGS; IN itself needs no
   service — OS geofence ENTER is motion-assisted and fires even with a
   dead process, field-proven 12h+ without app open. The FGS exists for
   the walk-out only: movement stream catches it, OUT punch keeps the
   idle service through work hours and the receiver closes it at the
    first post-window fire — banner never shows on non-work hours, weekends
    or leave days (leave days have no shift window; the leave-day gate is
    the date-scoped `gf_shift_today`/`gf_shift_today_date` marker — app
    opened that day + empty shift list → false; stale marker defaults TRUE
    so the headless morning-IN net survives days without app opens),
    commits
    `8dc7894`/`47130be`/`8787c56`/`82f2d0a`/`10197aa`). Headless WorkManager
   containment (15-min alarm) is the missed-ENTER/missed-EXIT net:
   `gf_containment_alarm_armed` is the MASTER ENABLE (geofence auto on,
   never cleared by punch state — cleared on disable/logout only), the
   chain self-perpetuates while (In OR within shift window) and rests
   outside the window until the next shift-start alarm re-arms it
   (GeofenceAlarmReceiver lifts the flag + arms while geofence auto is
   on). Leave days: no shift alarm → no chain, no banner.
   Android 15+ (`VANILLA_ICE_CREAM`): never start the FGS from
   `BOOT_COMPLETED` — location-type FGS start is banned there; the
   exact-alarm revive path is exempt.
4. `wifi_auto_punch_enabled_bg` defaults **false**. A `?? true` here leaks a
   service start (commit `0ddb03a`).
5. Containment alarm + alignment worker must call
   `registerZones(initialTriggers: {})` BEFORE `reconcileContainment()` —
   zones self-heal or missed punches recur (commit `68ce662`).
6. Keep-alive branch: no timers. Only the movement-gated GPS stream
   (distanceFilter 30m) while punched in. Stationary = zero fixes.
7. Punch pipeline order is sacred: fresh-fix GPS gate → OUT zone-identity gate
   → server-truth `PunchCoordinator` (FIRST in `_executePunch`) → POST →
   offline queue → `_persistPunchState`. Server decides; local gate only when
   server unreachable.
8. **Fixed punch bands (user spec)**: IN accepts only within `radius+5m`
   (25m at a 20m office); OUT requires beyond `radius+25m` (45m) with
   two-fix confirmation. Accuracy NEVER widens either band — the old
   2×accuracy margins caused the 61m IN and the delayed 149m OUT
   (commit `ab070de`). IN trust floor: fixes claiming worse accuracy than
   the radius defer to the OS crossing point; a fix at 61m must never
   punch IN.

## Conventions

- Commits: conventional (`fix(geofence): …`), one logical change, run
  `flutter analyze` + `flutter test` before committing. Full suite must stay
  green (173 tests).
- Zone metadata: persisted JSON `gf_zone_ids` / `gf_zone_$id`
  (`GeofenceZone.toJson/fromJson`). Native/Android pieces under
  `android/app/src/main/kotlin/com/mattendance/mattendance_mobile/`.
- Incident → open `.planning/debug/<slug>.md`, follow the debug-file protocol,
  archive to `resolved/` when done, and append the commit to the architecture
  doc's change log.
