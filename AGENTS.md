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
   gated to WORK HOURS, not punch state** (Android requires a persistent
   notification for any FGS). The FGS runs punched IN (the walk-out
   monitor: movement stream catches the EXIT, OUT punches at the
   boundary) AND stays up after an OUT punch while the shift window is
   still open — its stream then punches the RETURN-IN at point (~radius
   +5m, first honest inside fix; Nothing-class OEMs drop the headless OS
   geofence ENTER, field-proven). Past the shift end the FGS stops (banner
   must never show at home, nights, weekends or leave days — work-hours
   gate; leave days never punch). The FGS is NEVER auto-revived (sticky
   close, user design): closed stays closed — no banner behind the
   user's back; headless OUT covers it (OS geofence EXIT primary +
   15-min headless reconcile guarantee). Commits
   `8dc7894`/`47130be`/`8787c56`/`82f2d0a`/`10197aa`/`e624167`/`0c1ec2c`/
   `f5a53dd`). The
   15-min AlarmManager containment alarm is the **24/7 headless-IN
   checker**: `gf_containment_alarm_armed` is the MASTER ENABLE
   (geofence auto on, never cleared by punch state — cleared on
   disable/logout only) and the chain NEVER rests while armed — every
   fire re-registers the OS geofences from persisted metadata
   (`reRegisterZonesFromCache` — NO network; `registerZones` fetches
   offices over the API and must not run on 15-min cadence) and
   re-checks containment (last-known-first + fix budget, no GPS when
   away). This permanently closes the morning-IN-miss class — the
   pre-`e624167` chain rested outside the shift window, leaving the
   missed-ENTER net dead exactly when Out+window.
   Android 15+ (`VANILLA_ICE_CREAM`): never start the FGS from
   `BOOT_COMPLETED` — location-type FGS start is banned there; the
   exact-alarm revive path is exempt.
4. `wifi_auto_punch_enabled_bg` defaults **false**. A `?? true` here leaks a
   service start (commit `0ddb03a`).
5. Containment alarm + alignment worker must call
    `reRegisterZonesFromCache(initialTriggers: {enter})` (cache-only, no
    network) BEFORE `reconcileContainment()` — zones self-heal AND the
    catch-up ENTER re-fires for an already-inside punched-OUT phone
    (fix-independent headless IN recovery when the OS ENTER is
    OEM-dropped/deferred — Nothing-class missed-IN). Own-source duplicates
    persist silently (no notification spam for a punched-IN user sitting
    inside). Catch-up ENTER only fires when genuinely inside the geofence
    radius — cannot fabricate a far-away IN (commit `68ce662`; `e624167`
    made the checker 24/7 and switched it to cache-only re-registration;
    the `{enter}` catch-up was restored in the Nothing 3a fix).
6. Keep-alive branch: no timers. Only the movement-gated GPS stream
   (distanceFilter 30m) while punched in OR punched out within the open
   shift window (the return-IN monitor — punches IN at point on the
   first honest fix inside `radius+5m`; Nothing-class OS-ENTER drops
   make the stream the at-point IN guarantee, the Aug-8-proven 21m IN).
   Past the shift end the stream (or a containment check) closes the
   FGS — banner never outside work. Stationary = zero fixes.
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
