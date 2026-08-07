---
status: resolved
trigger: "precise location screen persists on certain MI phones even though Precise Location is enabled; works on other phones"
created: 2026-08-06T00:00:00Z
updated: 2026-08-06T00:00:00Z
---

## Current Focus
hypothesis: AppOps OP_FINE_LOCATION check false-negatives on MIUI (stale op state after enabling precise in settings)
test: version-split detection + lifecycle resume re-check
expecting: MIUI 12+ uses permission-level check (authoritative), no stale op blocking
next_action: done

## Symptoms
expected: blocking screen clears when user enables Precise Location
actual: screen stuck on "Precise Location Required" on certain MI phones despite precise enabled
errors: none
reproduction: MI phone → enable Precise in Settings → return to app → still blocked
started: after commit 73b734b (precise mandate)

## Eliminated
- hypothesis: permission_level check itself stale on MIUI
  evidence: Android 12+ docs — checkSelfPermission(FINE) authoritative; upgrade precise does NOT restart app, state updates live. MIUI 12+/HyperOS uses same permission model.
  timestamp: 2026-08-06
- hypothesis: test/features/auth test failure
  evidence: directory does not exist — bad path arg in test invocation, not a real failure
  timestamp: 2026-08-06

## Evidence
- timestamp: 2026-08-06
  checked: Android 12 approximate-location docs (permissions table)
  found: Precise → FINE+COARSE granted; Approximate → COARSE only. checkSelfPermission(FINE) = authoritative.
  implication: AppOps check redundant on 12+ and wrong source of truth
- timestamp: 2026-08-06
  checked: github.com/yanzhenjie/AndPermission issue #306 + programmerall.com MIUI permission article
  found: MIUI permission/app-op state known-stale — settings changes don't propagate to app-visible state (needs MIUI optimization / re-request); MIUI manages pre-12 precision at app-op level while keeping permission granted
  implication: AppOps OP_FINE_LOCATION = MODE_IGNORED despite precise enabled on MIUI → my check blocked → stuck screen. Only affects MI (other phones keep op in sync).
- timestamp: 2026-08-06
  checked: AppOpsManager AppOps.md
  found: unsafeCheckOp not affected by FOREGROUND-mode translation; MODE_ERRORED when unreadable
  implication: pre-12 AppOps path fails open on ERRORED; still only signal for MIUI pre-12 toggle

## Resolution
root_cause: My AppOps OPSTR_FINE_LOCATION gate (added as belt-and-suspenders) false-negatives on MIUI: MIUI keeps permission granted but its app-op state goes stale after the user enables Precise in Settings, so unsafeCheckOpNoThrow keeps returning MODE_IGNORED → screen stuck. Stock Android keeps op in sync, so only MI phones affected.
fix:
  - MainActivity.kt: version-split detection — Android 12+ (incl. MIUI 12+/HyperOS) uses checkSelfPermission(ACCESS_FINE_LOCATION) ONLY (documented authoritative); pre-12 uses AppOps (only signal for MIUI's backported toggle), MODE_ERRORED fails open
  - PermissionBlockingScreen: WidgetsBindingObserver — auto re-check on app resume so returning from Settings unsticks immediately (MIUI applies changes asynchronously)
verification: flutter analyze clean; compileDebugKotlin BUILD SUCCESSFUL; test suite = 13 pre-existing failures (0 new); full APK build passed earlier
files_changed:
  - android/app/src/main/kotlin/com/mattendance/mattendance_mobile/MainActivity.kt
  - lib/features/auth/screens/permission_blocking_screen.dart
