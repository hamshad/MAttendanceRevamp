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
   keep-alive FGS is separate and lightweight: all OEMs while punched in
   (movement-gated OUT monitor), aggressive OEMs additionally as process
   holder regardless of punch state.
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
