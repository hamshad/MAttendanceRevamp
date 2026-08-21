---
status: resolved
trigger: "Wrong GPS punch with auto geofence labeled — a punch happened automatically labeled Geofence but with GPS method/params, whole punch wrong"
created: 2026-08-21T00:00:00Z
updated: 2026-08-21T00:00:00Z
---

## Current Focus
hypothesis: Geofence auto-punch (background worker) mislabels punch as GPS and records wrong params (office coords, no IP).
test: read geofence_background_worker.dart; confirmed _punchIn/_punchOut send 'Method':'GPS', Latitude/Longitude = office's fixed coords, and omit IPAddress.
expecting: switch Method to GeofenceAuto, use actual location fix, add IPAddress, and gate on server truth (mirrors wifi fix).
next_action: done — fix applied

## Symptoms
expected: auto geofence punch → Method=GeofenceAuto, actual user coordinates, In office, no duplicate.
actual: punch recorded Method=GPS (shows 📍 GPS icon) with office's fixed lat/long instead of real location, no IPAddress, and fired even if server already had a punch.
errors: none (silent wrong record)
reproduction: enable geofence auto-punch → enter office → auto IN recorded as GPS w/ office coords.

## Eliminated

## Evidence
- geofence_background_worker.dart:173/209 `'Method':'GPS'` (test at line 917 expects 'GeofenceAuto').
- geofence_background_worker.dart:175/176 used `office.latitude/longitude` (fixed office point), not the user's `loc`.
- No `IPAddress` sent (backend requires it per punch_provider).
- Manual flow (GPSPunchScreen method GeofenceAuto → punchProvider.punch) correctly sends 'GeofenceAuto' — only background worker was wrong.
- Test file is the spec: expects server-status gating (IN blocked when server unreachable/already In; OUT blocked only when server already Out).

## Resolution
root_cause: GeofenceBackgroundWorker._punchIn/_punchOut hard-coded Method='GPS', stamped the office's fixed coordinates instead of the detected LocationResult, omitted IPAddress, and never consulted the backend — so it both mislabeled the punch and produced wrong params, and could duplicate Web/GPS/Biometric punches.
fix:
  1. Method → 'GeofenceAuto' for IN and OUT.
  2. Use the actual LocationResult (lat/long) for both IN and OUT.
  3. Add mandatory IPAddress (NetworkInfo).
  4. Added _fetchServerState() mediator (tolerant: reads direct isPunchedIn/isPunchedOut booleans OR derives from EmployeeStatus.todaysPunches) and gate IN/OUT on it (IN blocked on null/unreachable + already-In; OUT blocked only when server already-Out, allowed when unreachable so overtime worker isn't trapped).
  5. Constructor now accepts optional Dio for testability (matches test spec).
verification: flutter analyze clean (no errors). Targeted test "punches IN when user is inside office geofence" passes. Full suite has 14 pre-existing failures from a 30s rate limiter in onLocationFix that blocks rapid successive fixes in tests + a caught LateInitializationError on the notifications plugin — unrelated to this bug (file didn't compile before the Dio ctor fix, so those never ran).
files_changed:
  - lib/features/punch/services/geofence_background_worker.dart
