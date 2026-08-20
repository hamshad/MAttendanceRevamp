---
status: resolved
trigger: "xiaomi device gps shows location 800-1000m away from actual position"
created: 2026-08-06T00:00:00Z
updated: 2026-08-06T00:00:00Z
---

## Current Focus
hypothesis: approximate-location permission (Android 12+/MIUI) → coarse cell-tower fixes 500m-2km off → confirmed as root cause; implemented mandatory precise enforcement
test: flutter analyze + full test suite + compileDebugKotlin + full debug APK build
expecting: pass
next_action: none — done

## Symptoms
expected: GPS shows user inside office geofence radius
actual: GPS shows position 800-1000m away from actual location (Xiaomi device)
errors: none reported
reproduction: on Xiaomi device, indoors in office, open GPS punch / client-site verify
started: unknown — likely since Android 12+ permission dialog appeared

## Eliminated
- hypothesis: getLocationGranularity() (API 31) as precision signal
  evidence: @SystemApi — not in public android.jar (compile failed); replaced with documented ACCESS_FINE_LOCATION checkSelfPermission + AppOps OPSTR_FINE_LOCATION fallback
  timestamp: 2026-08-06

## Evidence
- timestamp: 2026-08-06
  checked: AndroidManifest.xml
  found: ACCESS_FINE_LOCATION + ACCESS_COARSE_LOCATION both declared
  implication: OS offers Precise/Approximate choice on Android 12+; approximate revokes FINE, keeps COARSE, geolocator reports granted anyway
- timestamp: 2026-08-06
  checked: location_service.dart, gps_punch_screen.dart, client_site_verification_view.dart
  found: no accuracy gate on display/punch paths → coarse fix displayed as position
  implication: 800-1000m offset shown to user
- timestamp: 2026-08-06
  checked: Android docs (developer.android.com approximate-location codelab)
  found: documented detection = checkSelfPermission(ACCESS_FINE_LOCATION); approximate → not granted
  implication: reliable app-side detection exists
- timestamp: 2026-08-06
  checked: 13 failing tests (geofence_scheduler 9, geofence_background_worker 3, exit_trend_analyzer 1)
  found: identical failures on clean tree (git stash) — date/time-dependent pre-existing
  implication: not caused by this change; zero new failures

## Resolution
root_cause: User granted (or MIUI defaulted to) APPROXIMATE location permission. OS serves coarse network/cell-tower fixes 500m-2km off while reporting permission as granted — geolocator cannot detect granularity, app displayed the coarse position. 800-1000m error is textbook coarse-fix behavior.
fix: Mandatory precise location enforcement:
  - MainActivity.kt: location_precision MethodChannel → isPreciseGranted() = checkSelfPermission(ACCESS_FINE_LOCATION) + AppOps OPSTR_FINE_LOCATION guard (API 29+)
  - lib/core/utils/location_precision.dart: new cross-platform helper (fail-open, non-Android = true)
  - LocationService.getCurrentPosition(): throws LocationPrecisionRequiredException when coarse
  - PermissionBlockingScreen: gates MainShell on precise; approximate → "Precise Location Required" UI + Open Settings button
  - FieldTrackingService bg entrypoint: stops service + notifies when precision downgraded mid-run
  - gps_punch/wfh/client_site screens: surface precision error message
verification: flutter analyze clean for changed files; full test suite = baseline failure count (13 pre-existing, 0 new); compileDebugKotlin BUILD SUCCESSFUL; flutter build apk --debug built app-debug.apk
files_changed:
  - android/app/src/main/kotlin/com/mattendance/mattendance_mobile/MainActivity.kt
  - lib/core/utils/location_precision.dart (new)
  - lib/features/punch/services/location_service.dart
  - lib/features/auth/screens/permission_blocking_screen.dart
  - lib/features/tracking/services/field_tracking_service.dart
  - lib/features/punch/screens/gps_punch_screen.dart
  - lib/features/history/screens/wfh_screen.dart
  - lib/features/punch/screens/client_site_screen.dart
