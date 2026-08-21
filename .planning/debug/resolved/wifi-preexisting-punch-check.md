---
status: resolved
trigger: "Wifi is not checking for the preexisting punches like web or biometric"
created: 2026-08-21T00:00:00Z
updated: 2026-08-21T00:00:00Z
---

## Current Focus
hypothesis: WiFi auto-punch decides IN/OUT from LOCAL state only, never consults backend, so Web/GPS/Biometric punches on other devices cause duplicate punches.
test: traced both wifi_auto_punch_service.dart and wifi_background_worker.dart; manual WiFiPunchScreen uses attendanceStatusProvider (server truth) — confirming only the auto paths lacked it.
expecting: adding a backend status mediator before each IN/OUT prevents duplicates
next_action: done — fix applied & compiles

## Symptoms
expected: WiFi auto-punch should not punch IN if already punched in via Web/GPS/Biometric, and not punch OUT if already punched out.
actual: WiFi auto-punch punched IN/OUT based solely on local lastPunchStatus/lastPunchType/lastInMethod, ignoring server punches from other methods → duplicate punches.
errors: none (silent duplicate punches)
reproduction: punch in via Web/Biometric (other device) → connect phone to office WiFi → auto-punch fires a second IN.
started: always (by design — local-only state)

## Eliminated

## Evidence
- wifi_auto_punch_service.dart: IN/OUT gated on `lastPunchStatus`, `lastInMethod`, `manualOutOnWifi` (all local Hive).
- wifi_background_worker.dart: gated on `lastPunchType`/`isLastInByWifi` (local SP).
- punch_button.dart + wifi_punch_screen.dart: manual WiFi punch derives `direction` from `attendanceStatusProvider` (server todayStatus) → already correct.
- attendance.dart `EmployeeStatus.isPunchedIn/isPunchedOut` derive from `todaysPunches` (server truth incl. method).

## Resolution
root_cause: WiFi auto-punch paths used only device-local punch state as the IN/OUT decision, so punches recorded via other methods (Web/GPS/Biometric) on the server were invisible → duplicate IN/OUT.
fix: Added PunchStateService (mediator) that GETs /api/v1/attendance/status and gates every WiFi auto-punch on server truth. Integrated into wifi_auto_punch_service.dart (_triggerPunch IN+OUT, _handleWifiDisconnected OUT) and wifi_background_worker.dart (_checkCurrentWifi IN+OUT, _handleDisconnect OUT). Falls back to local state on fetch error.
verification: flutter analyze passes (no new issues). Logic gates: server.isPunchedIn → skip IN; server.isPunchedOut → skip OUT; manual-IN-not-undone-by-WiFi guard preserved.
files_changed:
  - lib/features/punch/services/punch_state_service.dart (new)
  - lib/features/punch/services/wifi_auto_punch_service.dart
  - lib/features/punch/services/wifi_background_worker.dart
