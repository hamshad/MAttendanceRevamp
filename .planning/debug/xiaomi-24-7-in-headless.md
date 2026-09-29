---
status: investigating
trigger: "24/7 IN geofence not working on Xiaomi (battery restrictions OFF) — Nothing auto-IN on radius entry + starts FGS at shift; Xiaomi does neither until app opened. User must open app -> immediate IN -> FGS starts."
created: 2026-08-21T00:00:00Z
updated: 2026-08-21T00:00:00Z
---

## Current Focus
hypothesis: Xiaomi needs AUTO-START permission (separate from Battery saver) for the 15-min containment alarm + OS geofence + WorkManager to run in the background. Battery "No restrictions" alone is insufficient. Either the user skipped Auto-start, OR our openMiuiAutoStart deep-link failed to open the Auto-start page on HyperOS so it could not be enabled.
test: confirm on the device whether Auto-start (Security Center → Permissions → Autostart) is ENABLED for MAttendance. If off -> user enables -> retest headless IN. If on and still failing -> need logcat (did ContainmentAlarmReceiver fire? did WorkManager run? did OS geofence ENTER deliver?).
expecting: with Auto-start ON, Xiaomi behaves like Nothing (headless IN on radius entry, FGS not required for IN).
next_action: ship hardened openMiuiAutoStart deep-link (multiple HyperOS intents, land in Security Center) + emphasize Auto-start in the gate dialog; ask user to confirm Auto-start state + retest.

## Symptoms
expected: headless auto-IN when entering office radius (no app open); FGS optional (Nothing proves IN works without FGS).
actual: Xiaomi — no headless IN, no FGS; must open app -> immediate IN -> FGS starts. Battery restriction OFF on this Xiaomi.
errors: none.
reproduction: Xiaomi, app closed/background, enter office radius next day -> no IN until app opened.
started: reported 2026-08-21.

## Eliminated
- hypothesis: battery restriction still on
  evidence: user states battery restriction is OFF on the Xiaomi. (Xiaomi phone 2 earlier had it on; this is a different/now-exempted device.)
  timestamp: 2026-08-21
- hypothesis: geofence registration / IN punch logic broken
  evidence: opening the app produces IMMEDIATE IN + FGS start -> registration + catch-up ENTER + punch path are sound. Only the headless trigger is missing.
  timestamp: 2026-08-21

## Evidence
- timestamp: 2026-08-21
  checked: native openMiuiAutoStart (MainActivity.kt)
  found: only tried one hardcoded class (com.miui.permcenter.autostart.AutoStartManagementActivity) then fell back to app-details settings — which on MIUI does NOT expose Auto-start. On HyperOS the class often fails to resolve, so the user lands on a useless page and can never enable Auto-start. This is a plausible reason the exemption was never actually granted.
  implication: HARDEN the deep-link (try several intents, land in Security Center) so the user CAN enable Auto-start.
- timestamp: 2026-08-21
  checked: MIUI/HyperOS background model
  found: Auto-start (autolaunch) is a SEPARATE toggle from Battery saver / battery optimization. Battery "No restrictions" does not grant background execution; without Auto-start, BOOT_COMPLETED, AlarmManager, OS geofence broadcasts and WorkManager are blocked for a killed app. Nothing/stock Android deliver these without any exemption.
  implication: the 24/7 IN failure on Xiaomi is the classic missing Auto-start, not a code defect in the punch path.

## Resolution
root_cause: (pending device confirmation) missing Auto-start permission on Xiaomi; our deep-link made it hard/impossible to enable on HyperOS.
fix: hardened openMiuiAutoStart (multi-intent + Security Center fallback) + gate dialog now states Auto-start is THE critical requirement for headless IN. (committed)
verification: device retest — with Auto-start ON, headless IN on radius entry; if still failing, capture logcat.
files_changed: [android/app/src/main/kotlin/com/mattendance/mattendance_mobile/MainActivity.kt, lib/features/settings/screens/geofence_settings_screen.dart]
