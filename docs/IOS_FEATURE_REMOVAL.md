# iOS Build Blocker — Feature Removal Documentation

**Date:** 2026-07-20
**Branch:** `ios`
**Target:** iPhone 16e simulator (iOS 26, Apple Silicon)
**Status:** RESOLVED — app builds, installs, and launches on simulator

## Root Cause

Running the app on the iPhone 16e simulator failed at the iOS build stage with:

```
The following target(s) do not support arm64 architecture, which is a
requirement for Apple Silicon iOS 26+ simulators:
  - GoogleMLKit        (transitive dep of google_mlkit_face_detection)
  - MLImage / MLKitVision / MLKitCommon / MLKitFaceDetection ...
  - MLKitBarcodeScanning (transitive dep of mobile_scanner)
  - mobile_scanner
```

The `mobile_scanner` and `google_mlkit_face_detection` plugins (and their
transitive Google MLKit native frameworks) ship **x86_64-only** simulator
binaries. Apple Silicon iOS 26+ simulators require **arm64** slices. These
plugins cannot run on the simulator at all (only on real devices / older
Intel-sim combos). They compile fine on Android, which is why the app worked
there.

Per instruction, the two affected features were **removed entirely** rather
than worked around.

## Features Removed

### 1. QR Code Punch (feature: `QRCode`)
- Plugin: `mobile_scanner` (MLKit-based barcode scanning)
- Affected files deleted:
  - `lib/features/punch/screens/qr_scan_screen.dart`
  - `lib/features/punch/widgets/qr_verification_view.dart`
- Affected files edited:
  - `lib/features/punch/screens/punch_flow_screen.dart` — removed `QRCode`
    case from the verification-view switch and the `extras['qrCodeToken']`
    branch in `_handlePunch`; removed `qr_verification_view` import.
  - `lib/features/dashboard/widgets/punch_button.dart` — removed `QRCode`
    navigation case and the `'QRCode': (label: 'QR', icon: Icons.qr_code_scanner)`
    entry from `MethodSelector._methodMeta`.

### 2. Face Recognition Punch + Face Enrollment (feature: `FaceRecog`)
- Plugins: `google_mlkit_face_detection` (MLKit face detection) +
  `tflite_flutter` (MobileFaceNet embedding) + `image` (image utils,
  only used by the face service chain).
- Model asset removed: `assets/models/facenet.tflite`
- Affected files deleted:
  - `lib/features/punch/services/face_service.dart`
  - `lib/features/punch/screens/face_recog_screen.dart`
  - `lib/features/settings/screens/face_enrollment_screen.dart`
- Affected files edited:
  - `lib/features/punch/screens/punch_flow_screen.dart` — removed the
    `FaceVerificationView` class + `_OvalGuidePainter`, the `FaceRecog` case
    in the switch, the `extras['faceEmbedding']` branch, and the
    `face_service` import.
  - `lib/features/dashboard/widgets/punch_button.dart` — removed `FaceRecog`
    navigation case and the `'FaceRecog': (label: 'Face', icon: Icons.face)`
    entry from `MethodSelector._methodMeta`.
  - `lib/features/shell/main_shell.dart` — removed the "Face Recognition"
    settings ListTile (enrollment entry point) and its import.

## pubspec.yaml Changes

Removed dependencies:
- `mobile_scanner: ^6.0.2`
- `google_mlkit_face_detection: 0.12.0`
- `image: ^4.5.4`
- `tflite_flutter: ^0.12.0`

Removed asset entry:
- `assets/models/`

## iOS Build Cleanup Required

After editing `pubspec.yaml`, the stale CocoaPods cache still referenced the
MLKit frameworks and the build failed with the same error. Required:

```bash
cd ios
rm -rf Pods Podfile.lock
rm -rf ~/Library/Developer/Xcode/DerivedData/Runner-*
flutter pub get
```

## Verification

- `flutter build ios --simulator` → ✅ `Built build/ios/iphonesimulator/Runner.app`
- `xcrun simctl install` → ✅ installed on iPhone 16e
- `xcrun simctl launch` → ✅ launched (PID confirmed running in simulator)

## Known Remaining Issue (NOT a feature error)

`flutter run -d <simulator>` fails with:
```
Xcode build is missing expected TARGET_BUILD_DIR build setting.
```
This is a **Flutter 3.41.7 / Xcode 26 tooling incompatibility** in the
`flutter run` launcher — the actual Xcode build succeeds. Workaround: use
`flutter build ios --simulator` + `xcrun simctl install/launch`, or upgrade
the Flutter SDK. This is unrelated to the removed features.

## Server-Side Note

The backend may still return `QRCode` / `FaceRecog` in `allowedMethods`.
Those chips no longer render in the method selector, and if selected via a
cached/default they fall through to the generic "Verify via <method>" /
direct-punch default branch. No client crash. If the server should stop
offering these methods on iOS, that is a backend config change, out of scope
here.
