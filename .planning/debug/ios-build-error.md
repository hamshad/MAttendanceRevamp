---
status: investigating
trigger: "Run app on iPhone 16e simulator, strip out any feature causing error, document what gets deleted"
created: 2026-07-20T00:00:00Z
updated: 2026-07-20T00:00:00Z
---

## Current Focus
status: RESOLVED — features stripped, app builds + runs on simulator
root_cause: mobile_scanner + google_mlkit_face_detection ship x86_64-only MLKit frameworks; Apple Silicon iOS 26 sim requires arm64 → build fails
fix: removed QR + FaceRecog features, deps, model asset; cleaned Pods cache
next_action: commit code + docs

## Symptoms
expected: App runs on iPhone 16e simulator like it does on Android
actual: Unknown - need to run
errors: Unknown - to be captured
reproduction: flutter run on iPhone 16e simulator
started: App works on Android, never tested iOS

## Eliminated
<!-- none yet -->

## Evidence
<!-- to be appended -->

## Resolution
root_cause:
fix:
verification:
files_changed: []
