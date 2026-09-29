---
status: investigating
trigger: "auto-geofence-wrong-punch — audit auto geofence punch: wrong punch (time/location/state) despite ENTER→IN and EXIT→OUT recently working"
created: 2026-09-23T00:00:00+05:30
updated: 2026-09-23T10:00:00+05:30
---

## Current Focus
hypothesis: H2-leading — identical 3862m across wrong OUTs 5258/5260/5263 equals real-departure distance 5254 → same stored lat/lng replayed (pending-exit store surviving successful punch + re-firing, or offline-queue payload flushed repeatedly); disable→re-enable cleared the stored key. In-flips likely 15-min containment net restoring IN after each false OUT (fresh office-area coords → 18-24m). GPS flip 5269/5270 separate path (method=GPS assignment).
test: (T1) POST body fields → what server distanceFromOffice reads; (T3) read pending-exit store/clear/replay lifecycle — can it fire 3× with identical coords after successful 5254; (T2) disable/toggle path — which keys cleared; (T4) grep method=GPS assignment; map In-flips to catch-up/reconcile cadence
expecting: file:line proving one stored-coordinate source for all three 3862m OUTs + cleared by disable → root cause confirmed; separate explanation for GPS flip
next_action: read geofence_monitor.dart pending-exit lifecycle (:672-718,:833-840,:1089-1091) + POST body (:1019-1026), offline_sync_manager flush, method assignment, disable path

## Symptoms
expected: Both auto-geofence directions correct: OS geofence ENTER → headless auto punch-IN; geofence EXIT / in-only FGS walk-out stream → auto punch-OUT at boundary. Punch lands at real detection point, correct state, correct time.
actual: 2026-09-22 server timeline (method GeofenceAuto unless noted): CORRECT: 5248 In 05:22:43Z d26m; 5254 Out 08:03:17Z d3862m (real departure); 5257 In 08:30:31Z d22m (arrival); 5266 Out 11:44:29Z d108m (walk-out); 5268 In 12:11:32Z d27m; 5274 Out 13:12:53Z d64m; 5276 In 13:22:09Z d44m; 5278 Out 13:35:10Z d92m. WRONG (user idle at office, no movement): 5258 Out 08:48:22Z d3862m; 5259 In 09:17:36Z d22m; 5260 Out 09:23:41Z d3862m; 5261 In 09:29:30Z d24m; 5263 Out 10:13:16Z d3862m; 5264 In 10:21:54Z d18m; 5269 Out 12:11:33Z d25m method GPS (1s after 5268); 5270 In 12:11:46Z d18m method GPS (13s later).
errors: None (no logcat; server records only).
reproduction: wrong-punch window 08:48–10:21 (3× Out/In flip-flop while idle) + GPS flip-flop at 12:11. Fixed in field by device owner DISABLE → RE-ENABLE auto-geofence option (full teardown + registerZones re-registration).
started: 2026-09-22; worked before; disable/re-enable restored correct behavior same day.

## Eliminated
- hypothesis: invariant #5 violation (reRegister after reconcile)
  evidence: ContainmentCheckWorker.run geofence_scheduler.dart:231-234 and HeadlessAlignmentWorker._runInner:101-104 both call reRegisterZonesFromCache({enter}) BEFORE reconcileContainment(confirmOut:true). Keep-alive entrypoint field_tracking_service.dart:294-295 registerZones() before reconcile. Order intact.
  timestamp: 2026-09-23
- hypothesis: invariant #6 violation (pipeline order)
  evidence: _executePunch: PunchCoordinator.check FIRST (:922) → POST (:1019) → offline queue fallback (:1056/:1064) → _persistPunchState (:1073). GPS/zone gates run in callers before _executePunch. Order intact.
  timestamp: 2026-09-23
- hypothesis: invariant #7 band widening by accuracy (ab070de regression)
  evidence: geo_bands.isOutsideOfficeBand = dist > radius+slack AND accuracy <= band (floor only ADDS defer); reconcile IN band radius+5 (:642); _verifyTransition IN requires accuracy <= radius (:1217); fresh-fix OUT uses isOutsideOfficeBand. Bands never widened.
  timestamp: 2026-09-23
- hypothesis: invariant #3/4 regressions (FGS lifecycle, wifi bg default)
  evidence: startIfNeeded banner gate = punched-In only (oem_keep_alive_service.dart:100); _persistPunchState In→start/Out→stop (:1375-1379); no BOOT_COMPLETED FGS start (BootReceiver.kt:42-48); wifi_auto_punch_enabled_bg read with ?? false everywhere (GeofenceAlarmReceiver.kt:128, scheduler :311). Intact.
  timestamp: 2026-09-23
- hypothesis: snap/rewrite coordinates regression (honesty rule)
  evidence: no snapOutToBoundary anywhere; punch POST uses fix lat/lng directly (:997-1025); pending-exit replays stored crossing coords. Intact.
  timestamp: 2026-09-23
- hypothesis: TOCTOU double-POST toggle (concurrent isolates pass check then both POST)
  evidence: server GeofenceAuto rate limit 5min ('already recorded within') rejects 2nd same-direction POST (PunchStateInterceptor comment :28-35; geofence_monitor :1044-1054 treats as transient for IN). 20s PunchCoordinator cache widens check race but server rate-limit caps outcome — no toggle for GeofenceAuto. Cross-method race = server decides (by design).
  timestamp: 2026-09-23
- hypothesis: stale-day auto punch flushed from offline queue (wrong DAY time)
  evidence: auto punches (GeofenceAuto/WiFi) expire at autoPunchQueueTtl=15min in _shouldDropPunch (offline_sync_manager:173-178; constants:39). Only MANUAL punches never expire — out of auto-geofence scope.
  timestamp: 2026-09-23

## Evidence
- timestamp: 2026-09-23
  checked: full flow — registration (registerZones / reRegisterZonesFromCache from resume/shift-alarm/containment/alignment/keep-alive) → OS event (geofenceTriggered → handleEvent → dedupe 30s → _handleZoneEvent) → client-site prompt OR _verifyTransition → OUT zone-identity gate → _executePunch (server-truth → POST → queue → persist + FGS lifecycle)
  found: IN paths: (a) OS ENTER → verify: fresh fix in radius+5m & accuracy<=radius, else trigger fallback trigDist<=radius+50; (b) reconcile band-only radius+5 (cached fix ≤10min); (c) catch-up ENTER {enter} on every 15-min fire. OUT paths: (1) OS EXIT crossing fast-path trigDist∈(radius, radius+250] → immediate punch at trigger, NO two-fix, NO accuracy floor; (2) fresh-fix two-fix isOutsideOfficeBand; (3) _reconcileOut confirmOut two-fix + trust floor + ≤800m jump guard; (4) keep-alive stream isOutsideAllOffices (trust floor) → reconcile confirmOut; (5) pending-exit replay at stored crossing.
  implication: full semantics-point inventory established (see ranked audit below)

- timestamp: 2026-09-23
  checked: 43d4c69 diff vs commit message
  found: message claims trust floor applied to FOUR OUT paths incl. "crossing"; diff shows crossing branch (_verifyTransition trigDist∈(radius, radius+250]) UNCHANGED — no isOutsideOfficeBand, no two-fix. Plugin native_geofence Location exposes lat/lng ONLY (model.dart:7-9) — no accuracy on OS trigger, so accuracy floor impossible there; but tolerance stays 250m.
  implication: **H1 — the field-proven 68m fused-jump false-OUT class can still fire via OS EXIT crossing fast-path**: OS uses same fused provider → jump beyond radius fires EXIT with trigger=jump point (≤radius+250 accepted) → immediate OUT, bypassing the anti-fake layers added for exactly this class. Commit claim vs code mismatch.

- timestamp: 2026-09-23
  checked: e1995f5 pending-exit path (geofence_monitor :672-718, :833-840, :1089-1091) + _executePunch POST body (:1019-1026)
  found: pending-exit replays OUT up to 2h late (_pendingExitMaxAge); POST carries NO offlineTimestamp (unlike offline queue sync :346) → server stamps FIRE time, not crossing time. Fires even when user already back inside (comment :674-679 explicit) → "Auto-Punched Out" notification while at desk; FGS stops; catch-up ENTER re-INs ≤15min.
  implication: **H2 — wrong TIME (server records up-to-2h-late OUT) + perceived wrong STATE (OUT-while-inside)**. By-design tradeoff from xiaomi-in-missed, but user-visible wrong punch.

- timestamp: 2026-09-23
  checked: divergence-flush (geofence_monitor :937-956, 43d4c69)
  found: queued OUT (offline) + server still In + user returns → return ENTER verdict=duplicate(In), local=Out → diverged → persist In + scheduleNow flush → queued OUT POSTs (createdAt=queue time, offlineTimestamp=queue time) → server flips to Out while user INSIDE; then 15-min net re-punches IN.
  implication: **H3 — wrong-state/time server record (OUT flushed after re-entry)**. Closes old deadlock by design; produces transient wrong punch timeline entry.

- timestamp: 2026-09-23
  checked: late OS EXIT tolerance (_outCrossingTolerance=250, :479, :1194-1199)
  found: trigger up to radius+250m accepted as genuine crossing → punch at detection point up to ~270m from center, no confirmation. Detection lag in Doze = honest-but-far location (446m class rejected >250 and falls to fresh-fix; 100-270m class accepted here).
  implication: **H4 — wrong-LOCATION (far) OUT via accepted late/spurious crossing; honesty rule says location is real detection point, but user perceives wrong.**

- timestamp: 2026-09-23
  checked: IN trigger fallback (:1223-1225)
  found: trigDist <= radius+50 accepted when fresh fix unusable/untrusted → IN possible up to radius+50 (70m @ 20m office) vs fix band radius+5 (25m). Fallback path contradicts fix band but serves headless-indoor no-fix IN (the field-proven 21m-61m class).
  implication: H5 — wrong-LOCATION IN up to 70m possible without fresh-fix corroboration; partially by design (OS crossing honesty).

- timestamp: 2026-09-23
  checked: reconcile IN accuracy floor (:631-647) vs _verifyTransition IN (:1215-1218)
  found: reconcile IN = band check ONLY (dist ≤ radius+5), NO accuracy trust floor; verifyTransition IN requires accuracy ≤ radius.
  implication: H10 — asymmetric trust: a fused fix claiming poor accuracy landing inside the 25m band can punch IN via 15-min reconcile. Low likelihood (error must land in tiny band) but floor is a one-line strengthen.

- timestamp: 2026-09-23
  checked: _punchOutConfirmed zone fallback (:818-822) + _publishLocalState (offline_sync_manager :223-233)
  found: orElse → zones.first when gf_last_punch_zone_id missing/mismatched; _publishLocalState does not write zone id (only _persistPunchState does, at queue time).
  implication: H6 — Address attribution can name wrong office on OUT if zone id stale/absent (lat/lng honest). Low.

- timestamp: 2026-09-23
  checked: temporal correlation — commits since 2026-09-01
  found: 69d1fb5 mock GPS (09-04), in-queued-blockade stale queue proven in field (09-08, resolved 09-12), auth/token recovery 0004c56+ff499c5 (09-12), offline guard 41dfa1a (09-12), proactive refresh 62dbcf8 (09-14). Token-outage period → punches queue then flush → skew if server ignores offlineTimestamp.
  implication: H7/H8 — time skew ≤15min for auto (TTL) if server ignores offlineTimestamp (server behavior unknown — needs server-side check); auth window raised queue/flush frequency in exactly the reported window. Mock false-positive would MISSES not wrong punches (accuracy<1m heuristic rare).

### Ranked audit (every wrong-punch semantics point)
| # | Dim | Path | Mechanism | file:line | Likelihood |
|---|-----|------|-----------|-----------|------------|
| H1 | location+state | OS EXIT crossing fast-path | trigger (radius, radius+250] accepted with NO trust floor/two-fix; fused jump fires EXIT → false OUT at jump point while inside; 43d4c69 claim-vs-code gap | geofence_monitor.dart:1194-1199,479 | HIGH (field-proven class, gap survives fix) |
| H2 | time+state | pending-exit auto-OUT (e1995f5) | replay ≤2h late, POST no offlineTimestamp → server time=fire time; fires while back inside → OUT-at-desk | geofence_monitor.dart:672-718,1019-1026 | MEDIUM (needs failed OUT + return <2h) |
| H3 | state+time | divergence-flush (43d4c69) | queued OUT flushed on return-ENTER duplicate → server Out while inside, re-IN ≤15min | geofence_monitor.dart:937-956 | MEDIUM (needs offline OUT + return) |
| H4 | location | late OS EXIT within 250m tolerance | honest detection point 100-270m from center | geofence_monitor.dart:1194-1199 | MEDIUM (Doze lag; honesty-rule class) |
| H5 | location | IN trigger fallback radius+50 | headless indoor no-fix IN up to 70m | geofence_monitor.dart:1223-1225 | LOW-MED (partially by design) |
| H6 | location(Address) | _punchOutConfirmed zones.first | wrong office name when zone id stale | geofence_monitor.dart:818-822 | LOW |
| H7 | time | offline queue flush (server ignores offlineTimestamp?) | auto ≤15min skew; server semantics unknown | offline_sync_manager.dart:346 | LOW (needs server check) |
| H8 | state | auth-outage queue/flush Sep 12-14 | 401→undecided→queue→flush after recovery | punch_coordinator.dart:90, offline_sync_manager:187-208 | LOW (window matches "recent days") |
| H9 | time(local) | duplicate branch persists time=now | local gf_last_punch_time drift on own-echo | geofence_monitor.dart:944 | LOW (display only) |
| H10 | state | reconcile IN no accuracy floor | band-only IN from untrusted fused fix | geofence_monitor.dart:642 | LOW |

## Resolution
root_cause: (pending — dimension + logcat required; ranked H1-H10 above)
fix: (none — field-evidence rule: no fix before root cause confirmed)
verification:
files_changed: []
