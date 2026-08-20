---
status: resolved
trigger: "audit: false jumps/wifi-provider GPS must not punch OUT; no missed punches; no token flush; timeline consistent no dupes; Xiaomi/OnePlus reliability"
created: 2026-08-10T00:00:00Z
updated: 2026-08-10T00:00:00Z
---

## Current Focus
hypothesis: audit closed 3 real gaps: (A) local lastType gate before server truth → cross-day stale 'In' skipped today's IN (missed punch); (B) no OUT reconciliation → OEM-dropped EXIT = stuck In; (C) OUT fresh-fix fallback trusted one fix → wifi-derived jumps could false-punch OUT
test: 110/110 suite; +5 new tests (stale-In server decides, offline skip, reconcile-OUT 2-poll, inside-other-office no-OUT, jump reset)
expecting: server-first ordering everywhere; OUT requires 2 confirmed outside fixes (event fallback + reconcile)
next_action: done — commit pending

## Symptoms
expected: no false OUT from wifi-provider GPS jumps; in→in always, out→out never; no missed IN/OUT; no token flushes; consistent timeline
actual: audit found gaps (A)(B)(C) — see Current Focus
errors: none reported new; user asks guarantee
reproduction: (A) day2 open app never → leftover In + IN event → skipped silently; (C) office+office-wifi fix jumps >radius+margin on exit event w/o crossing loc

## Eliminated
- token flush issues (token-flush-logout.md): atomic lock, session generation, adopt-on-400, Hive-preserving clear — all VERIFIED present in token_storage/dio_client
  evidence: greps: authSessionIdKey, _adoptNewerTokensIfRefreshed, comment blocks
- xiaomi-gps-far-away: precise-location enforcement present (MainActivity split logic, LocationPrecision, entrypoint stop+notify)
- mi-precise-screen-stuck: version-split detection + resume re-check present
- alarm re-arm/boot/Doze: GeofenceAlarmReceiver self-rearm + setExactAndAllowWhileIdle + BootReceiver local-tz parse present
- wifi dup OUT: cross-isolate wifi_disconnect_processed_ts + cooldown + mobile-data-only flush present
- 429/login: TooManyRequests + refresh marker logic present (dio_client)
  timestamp: 2026-08-10

## Evidence
- 2026-08-10 read _executePunch: local gate ran BEFORE PunchCoordinator → offline-order bug (A) confirmed
- 2026-08-10 read reconcileContainment: IN-only → OEM-missed EXIT unrecoverable (B) confirmed
- 2026-08-10 read _verifyTransition OUT fallback: single fresh fix strictly outside → wifi jump false-OUT (C) confirmed
- 2026-08-10 fix: server-truth first (local gate only when undecided/offline); _reconcileOut 2-poll hysteresis (marker gf_out_poll1_*, >800m jump = noise reset, <=2min window); _verifyTransition OUT fallback double-fix + 800m movement sanity
  implication: missed IN/OUT closed; duplicates impossible when server reachable; false OUT needs 2 stable outside fixes

## Resolution
root_cause: three ordering/verification gaps in geofence punch paths (see Evidence)
fix: (A) PunchCoordinator.check moved before local gate; local gate applies only under PunchCheck.undecided; (B) reconcileContainment now also reconciles OUT with 2-poll confirmation; (C) OUT fallback requires 2 fixes both outside + ≤800m apart
verification: +5 tests regressions; monitor 43/43; full suite 110/110; analyze no new issues
files_changed: [lib/features/punch/services/geofence_monitor.dart, test/features/punch/services/geofence_monitor_test.dart]