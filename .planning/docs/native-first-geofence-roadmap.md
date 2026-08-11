# Remaining Phases: Native-First Geofence Roadmap

> Status: plan (not started)
> Date: 2026-08-11
> Depends on field-test feedback for Phase 2/3 correctness

## Phase 5 — Native alignment warnings (user-requested next)

**Problem:** geofence-only users (no service) lost background alignment
warnings: "no network (airplane mode?)", "connected but app can't read WiFi
(hidden BSSID)", GPS-off nag. Foreground AlignmentMonitor still covers
app-open, but nothing runs with app killed.

**Design — native WorkManager periodic worker (headless):**
- New Kotlin `AlignmentCheckWorker` (WorkManager periodic, ~30 min,
  flex ~10 min — system-scheduled, battery-cheap)
- On run: read SharedPreferences (FlutterSharedPreferences, same file the
  Dart side writes) for: punch state (`flutter.gf_last_punch_type`), feature
  toggles (`flutter.geofence_auto_enabled`, `flutter.wifi_auto_punch_enabled_bg`),
  last warning timestamps (rate-limit prefs keys mirror Dart constants)
- Connectivity check via `ConnectivityManager.registerDefaultNetworkCallback`
  (instant) or `NetworkCapabilities` poll (30 min cadence is fine)
- WiFi hidden check: `WifiManager.connectionInfo` — BSSID empty/`02:00:00:00:00:00`
  while connected → hidden
- Post notification via existing `user_alignment` channel (ID 998/997 match
  Dart constants so both isolates replace, never duplicate)
- Respect rate limits + only nag while punched in (mirror Dart semantics)
- Schedule worker from `GeofenceScheduler` when any auto feature enabled;
  cancel on all-off

**Alternatives rejected:**
- Manifest CONNECTIVITY_ACTION receiver: Android 8+ implicit-broadcast
  restrictions + receiver is short-lived (~10s), can't do BSSID scan reliably
- Adding the poll back to the service: reintroduces battery cost we just killed

**Effort:** ~1-2 days (Kotlin + prefs schema sync + tests for semantics)
**Tests:** unit-test the Kotlin decision logic via Robolectric (optional) or
keep Dart-side semantics doc-tested; manual OEM test matrix.

## Phase 6 — WiFi auto-punch without the service (deep cut)

**Problem:** wifi auto-punch still requires the service process (BSSID checks
need live isolate: connectivity stream + network_info_plus). Phase 2 users
with wifi enabled keep the service running all shift.

**Design options:**
- **A (recommended):** periodic WorkManager `WifiCheckWorker` (~5 min) +
  headless BSSID read + punch, mirroring the worker's two-check confirm +
  server-truth coordinator. Kills the service for wifi users too. BSSID read
  headless: `WifiManager.connectionInfo` works in a background worker when
  location permission granted (already the requirement today).
  Risk: 5-min IN latency (vs ~2 min today via stream); stale-BSSID confirm
  logic must survive cold starts (markers already persisted in prefs).
- **B:** manifest CONNECTIVITY_ACTION receiver → headless one-shot work →
  BSSID check → punch. Instant but Android 8+ restrictions + OEM filtering
  make it unreliable as the only path; needs A as fallback anyway.
- **C:** keep service (status quo). Fine if Phase 2 field test shows battery
  acceptable for wifi users (service cost is already ~90% cut).

**Decision gate:** Phase 2 field-test battery numbers. If users with wifi
auto report acceptable drain → C forever; else A.
**Effort:** A = ~2 days + migration of BSSID-confirm/pending-OUT semantics.

## Phase 7 — Field tracking battery budget

**Problem:** `field_tracking_service` pings GPS high-accuracy every 5 min
when enabled — by design GPS-heavy, but it's the same radio budget problem
in miniature.

**Design options:**
- Adaptive cadence: 5 min while moving (speed > threshold), 15-30 min while
  stationary (speed ~0), resume 5 min on movement — reuse existing
  `JumpRejection`/speed logic already in the tracking pipeline
- Accuracy: high when moving, medium/low when stationary
- Persist per-user default with server config override

**Effort:** ~1 day + tests (filters already tested)
**Gate:** only if users enable tracking; not blocking.

## Phase 8 — MIUI onboarding hardening

**Problem:** MIUI-without-autostart users are broken until they open the app
once, and silently if they never grant exemptions.

**Design:**
- First-launch geofence wizard step on MIUI/aggressive OEMs (brand detect
  via `DeviceInfo`): "Enable Autostart + battery exemption" deep-link
  (`miui.intent.action.OP_AUTO_START` etc., existing prompts already
  partially cover this)
- Detect-and-notify: if geofences were registered but no transition fired in
  N days while shift active → in-app diagnostic card
- Server-side: expose `lastPunchSource` + registration timestamps in admin
  view for support diagnosis

**Effort:** 1 day + UX review
**Gate:** after Phase 5 warnings ship (they share the diagnostic channel).

## Open questions (need user decision)

1. Phase 6 decision gate: accept service for wifi users if battery OK, or
   build the headless wifi worker regardless?
2. Phase 7: is tracking GPS-heavy behavior acceptable to product, or should
   adaptive cadence be the default for new users?
3. iOS: permanently out of scope for native-first? (user said ignore iOS —
   confirming nothing changed)

## Suggested order

```
Phase 5 (alignment warnings) → field-test feedback → Phase 6 gate → Phase 8 → Phase 7
```
