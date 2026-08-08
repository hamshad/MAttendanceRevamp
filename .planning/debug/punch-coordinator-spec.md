---
status: implemented
trigger: "App blind to biometric-machine/website punches → double-punch corruption; plus lossy IN when server unreachable (battery-optimization refusal → deferred WorkManager run)."
created: 2026-08-08
updated: 2026-08-08
type: feature-spec
---

# PunchCoordinator — server-truth gate for every punch path

## Problem

Two related defects:

1. **App trusts its own local state.** Punches also come from the biometric machine and the website — the app can't see them. Local `gf_last_punch_type` says `'Out'`, server says `'In'` (biometric punched in at 9:00). Any app path that fires IN then **toggles the server to OUT** (2nd IN = toggle). Affects all 7 punch paths; manual, WiFi fg, and both offline-queue paths have **no pre-check at all**.

2. **Lossy IN under server outage.** `GeofencePunchHandler` IN branch drops the punch when todayStatus is unreachable. OUT degrades gracefully (offline queue); IN silently dies. Worst case = battery-optimization refusal → WorkManager run deferred to a dead window → punch lost.

## Core insight

The timeline already exists: `GET /attendance/status` returns `todaysPunches` (`List<PunchSummary>` — `punchType: 'In'|'Out'|'BreakStart'|'BreakEnd'`, `punchTime`, `method`). **No new endpoint.** Nobody reads it pre-punch.

## Design — `PunchCoordinator` (one gate, per-path policy)

**New core service** `lib/core/punch/punch_coordinator.dart`:

```dart
enum PunchCheck { valid, duplicate, blocked, undecided }

class PunchCoordinator {
  /// 1. GET todayStatus (short timeout)
  /// 2. Parse EmployeeStatus.todaysPunches (model-backed) → last punchType;
  ///    fallback to raw keys isPunchedIn/isPunchedOut if list empty.
  /// 3. Decide:
  ///    last == direction            → duplicate  (server would TOGGLE)
  ///    direction In && isOnBreak    → blocked    (must /breaks/end first)
  ///    else                          → valid
  ///    status unreachable            → undecided  (caller picks policy)
  /// 4. Cache in prefs (bg_server_last_type + bg_server_status_ts, ~20s TTL) —
  ///    isolates share no memory; cache stops status-storms when paths fire
  ///    together (biometric IN same moment as geofence IN).
  static Future<PunchCheck> check({required Dio dio, required String direction});
}
```

Key decisions baked in:

- **Server truth via `todaysPunches`** (model-parsed, definitely real) — replaces the raw-key reads that are a latent bug (`status['isPunchedIn']` in geofence handler / wifi worker: if API omits those keys the gate is silently dead).
- **`last == direction → duplicate`** — this is what prevents the toggle corruption. No server-side reject exists (confirmed), so this client gate is the ONLY protection.
- **Break awareness** — `isOnBreak && direction In → blocked`. Punch API must not blind-fire IN mid-break; user ends break via `/breaks/end` first.
- **TTL cache in prefs** — every isolate (app, flutter_background_service, WorkManager, plugin engine) hits the same prefs; no in-memory sharing possible.
- **`PunchSummary.method`** tells where the last punch came from — future lever ("skip only if method == Biometric").

### Per-path policy

| Path | valid | duplicate / blocked | undecided (offline) |
|---|---|---|---|
| Geofence handler | punch | skip + notification "already punched in via biometric/website" | **queue IN** (fallback below); OUT → queue |
| WiFi fg + bg | punch | skip + notification | queue (same as today's failure path) |
| Manual (PunchNotifier) | punch | **warn-and-confirm dialog** "already punched in via biometric/website — punch anyway?" (default cancel) | current behavior (queue offline) |
| Offline queue bg (offline_sync_manager) | POST | **drop from queue** | keep, retry next cycle |
| Offline queue fg (sync_service) | POST | drop from queue | keep, retry |

Manual stays strict-informing, auto stays strict-blocking — user agency preserved, surprise killed.

## Queued-IN fallback (lossless IN under outage) — folded in

The coordinator subsumes the earlier queued-IN Guard 2 and generalizes it to **all directions** + break awareness. No model change: `OfflinePunch` already has `method`, `direction`, `createdAt`.

Queue path for geofence IN when status unreachable (or any auto punch whose POST fails):

```dart
if (status == null) {  // handler IN branch
  final queued = await _queueOfflinePunch('In', verifiedFix.latitude, verifiedFix.longitude);
  return;  // never silently drop
}
```

At sync time (`executeSyncTask`), every queued punch passes `PunchCoordinator.check`:

- `duplicate/blocked` → **drop from queue** (biometric won the race; punching would toggle)
- `undecided` → keep, retry next cycle (network constraint guarantees connectivity; 5xx = transient)
- **plus TTL guard:** `now - createdAt > 15 min` → drop (`AppConstants.geofenceInQueueTtl`). Enter + 15 min outage = stale; punching hours later at a maintenance window is wrong.
- Server duplicate rejection in `_handleDioError` stays as last-line net.

## Required fix — sync publishes local punch state (pre-existing bug)

`executeSyncTask` never writes `gf_last_punch_type` / `gf_last_punch_time`. Handler gate `lastType == direction → skip` then fires wrongly:

- Queued OUT syncs → lastType stays `'In'` → next ENTER event skipped.
- Queued IN syncs → lastType stays `'Out'` → next EXIT event skipped → stuck punched-in.

**Fix:** after any successful punch POST in `executeSyncTask`, write `gf_last_punch_type = punch.direction` + `gf_last_punch_time = punch.createdAt` (mirror `_persistPunchState` keys). `PunchStateInterceptor` already does this for foreground paths.

## Code changes

### New: `lib/core/punch/punch_coordinator.dart`
- `PunchCheck` enum, `check({dio, direction})`, prefs TTL cache, `todaysPunches` parse + raw-key fallback, `isOnBreak` handling.
- Must not import feature packages (core). Direction is a string; status parse via existing `EmployeeStatus.fromJson` (model in core-adjacent `models/`).

### `lib/features/punch/services/geofence_monitor.dart`
- Replace raw-key `todayStatus` gate with `PunchCoordinator.check`.
- IN branch `status == null` → `_queueOfflinePunch('In', ...)` instead of drop (never silent).
- Add `queueOverride` constructor seam (Hive unavailable in unit tests → decision untestable).

### `lib/features/punch/services/wifi_background_worker.dart` + `wifi_auto_punch_service.dart`
- Replace raw-key `_syncPunchStateFromServer` gate with `PunchCoordinator.check` at punch decision points.

### `lib/features/dashboard/providers/dashboard_providers.dart` (manual)
- Before POST: `PunchCoordinator.check` → `duplicate/blocked` → confirmation dialog → proceed on confirm.

### `lib/core/offline/offline_sync_manager.dart`
- TTL const `_geofenceInTtl` (or `AppConstants.geofenceInQueueTtl`).
- Pre-POST: coordinator check for **every** queued punch (not just IN) — `duplicate/blocked` → delete + log; `undecided` → retryCount++, save, end batch.
- Post-success: write `gf_last_punch_type` / `gf_last_punch_time`.
- Same treatment in `lib/core/offline/sync_service.dart` (fg).

### `lib/core/app_constants.dart`
- `geofenceInQueueTtl = Duration(minutes: 15)`.

## Edge cases

| Case | Outcome |
|---|---|
| Biometric IN at 9:00, app geofence IN at 9:01 | Coordinator sees last=`In` → duplicate → skip. No toggle. ✓ |
| Manual IN while offline → queued; biometric also INs | Sync: coordinator sees `isPunchedIn` → drop queued IN ✓ |
| Two IN events queued (dedupe passed, still offline) | First syncs → success; second → duplicate → dropped ✓ self-healing |
| Offline > 15 min | TTL drops stale IN; bounded loss, correct > complete |
| App killed + restart | Hive queue persists; periodic sync re-runs ✓ |
| Break started via /breaks/start, geofence IN fires | `isOnBreak` → blocked → skip ✓ |
| Sync-time status 5xx | undecided → retry next cycle, never drop ✓ |
| Successful queued OUT | pref-write fixes stale-local-gate bug for enter events too ✓ |

## Risks / open questions

1. **Race window** — biometric punch between our check and our POST slips through (no server-side reject). Mitigated by short TTL; residual accepted. **Real fix = server duplicate detection (out of our control).**
2. **Backend toggle semantics** — 2nd IN toggles OUT (user-confirmed). Coordinator's `duplicate` gate is therefore the *only* protection. If backend ever changes to reject, coordinator becomes belt-and-suspenders. No action needed beyond relying on Gate.
3. **TTL 15 min** — arbitrary. v1 default, revisit with field data.
4. **Manual punch policy** — warn-and-confirm chosen (strict auto, informed manual). Hard-block is the fallback if users abuse "punch anyway".
5. **Status fetch cost** — 1 request per punch attempt, 20s prefs cache. Negligible.

## Tests

### `test/core/punch/punch_coordinator_test.dart` (new)
- last==In, want In → duplicate; last==Out, want In → valid; last==Out, want Out → duplicate.
- isOnBreak + want In → blocked; isOnBreak + want Out → valid (leaving break).
- todaysPunches empty → raw-key fallback path.
- status unreachable → undecided.
- TTL cache: 2nd call within TTL skips network (mock dio call count).
- 20s expiry → refetch.

### Handler (`geofence_monitor_test.dart`)
- status unreachable → IN queued (via `queueOverride`), not dropped.
- duplicate (biometric IN) → skip, no punch, no queue.
- Existing 17 tests keep passing (gate semantics preserved — raw-key mock now feeds coordinator).

### Sync manager (`test/core/offline/offline_sync_manager_test.dart`, new — Hive temp-dir mock)
- Queued IN + status says not-in → POSTed, deleted, prefs `gf_last_punch_type == 'In'`.
- Queued IN + duplicate → dropped, not POSTed.
- Queued IN older than TTL → dropped.
- Queued IN + 5xx → kept, retryCount bumped.
- Queued OUT success → prefs `gf_last_punch_type == 'Out'` (closes pre-existing gap).
- Non-geofence punches (QR/selfie) → unchanged path, prefs untouched on failure.

### WiFi / manual
- WiFi duplicate → skip; manual duplicate → dialog, cancel → no POST, confirm → POST.

## Acceptance

1. Biometric IN at 9:00 → geofence/WiFi/queue punches afterward all skip (notification), no server toggle. Verify server timeline shows single IN.
2. Manual punch while server says punched-in → dialog; cancel = no POST.
3. Enter office with server unreachable → IN queued; sync within one periodic run (≤15 min); `gf_last_punch_type` correct afterwards.
4. Break started → no auto IN mid-break.
5. `flutter test` green, `flutter analyze` 0 errors.

## Status

**implemented 2026-08-08** — all paths wired, 79/79 tests green, analyze 0 errors:

- `lib/core/punch/punch_coordinator.dart` + 12 unit tests
- geofence (coordinator gate, queue-on-unreachable IN, `queueOverride` seam) — 21 handler tests
- WiFi fg + bg — model-backed status sync replaces raw keys
- manual — `PunchResult.isDuplicate` + "Punch anyway?" dialog (short/direct, `force: true` retry)
- offline sync fg + bg — coordinator + 15-min auto TTL + local-state publish; 7 sync-manager tests
- race residual accepted (user decision; real fix = server-side reject, out of scope)

Commits: 52bc939 → 4465bb5 (7 commits).
