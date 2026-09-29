---
status: resolved
trigger: "sometimes when user tries to punch in, then he gets 'A in punch is already queued - waiting to sync' when there is no in punch, or network issue, or gps issue, that error keeps popping up and they can't punch IN on a brand new day where there aren't supposed to be any previous punches, it shouldn't be a blockade"
created: 2026-09-08T00:00:00Z
updated: 2026-09-08T00:00:00Z
---

## Current Focus

hypothesis: lastPendingDirection ignores date — stale yesterday-pending In blocks today's In as hard failure
test: read offline_queue + both guard call sites + sync service
expecting: guard scoped to all-time queue, success:false blockade confirmed
next_action: apply minimal fix (today-scoped guard + idempotent success) and verify with flutter test

## Symptoms

expected: brand new day, no previous punches → user can punch IN (queues fresh if offline)
actual: 'A In punch is already queued — waiting to sync' pops repeatedly, user cannot punch IN
errors: 'A $direction punch is already queued — waiting to sync'
reproduction: queue an In offline (network fail) one day, try In next day while offline/flaky → guard hits
started: reported 2026-09-08

## Eliminated

## Evidence

- timestamp: 2026-09-08
  checked: offline_queue.dart lastPendingDirection (lines 58-64)
  found: filters only retryCount < maxRetryCount, NO date filter — returns most recent pending across ALL days
  implication: yesterday's pending In blocks today's In

- timestamp: 2026-09-08
  checked: dashboard_providers.dart _queueOffline guard (lines 295-305)
  found: if queue.lastPendingDirection == direction → PunchResult(success:false, message already-queued)
  implication: hard failure → red error snackbar each retry, no punch enqueued, feels like blockade

- timestamp: 2026-09-08
  checked: offline_screen.dart _handlePunch guard (lines 135-139)
  found: same all-time check, same blockade message
  implication: both punch paths share the bug

- timestamp: 2026-09-08
  checked: getTodayPunches vs lastPendingDirection
  found: getTodayPunches filters by createdAt day; lastPendingDirection does NOT — inconsistent
  implication: timeline knows about days, guard does not

- timestamp: 2026-09-08
  checked: sync_service + offline_sync_manager _shouldDrop
  found: manual punches never expire (only auto GeofenceAuto/WiFi have 15-min TTL); transient failures bump retryCount but stay < maxRetryCount=3 for a while
  implication: stale manual In lingers across midnight and keeps blocking

- timestamp: 2026-09-08
  checked: UI handling (gps_punch_screen, punch_button)
  found: success:false → red snackbar + stays on screen, retry pops same error; only 2 callers of lastPendingDirection (the two guards)
  implication: safe to scope getter to today + return idempotent success

## Resolution

root_cause: OfflineQueueService.lastPendingDirection is all-time scoped while attendance alternation is per-day — a stale pending In from a previous day (network failure) permanently blocks the next day's In with a hard-failure message
fix: scoped lastPendingDirection to today-only (matches getTodayPunches); guard now returns idempotent success(true, 'already saved — waiting to sync') instead of success(false) so retry never blockades; same wording fix in offline_screen
verification: flutter analyze clean (5 pre-existing infos only); flutter test 197/197 passed
files_changed:
- lib/core/offline/offline_queue.dart
- lib/features/dashboard/providers/dashboard_providers.dart
- lib/features/offline/screens/offline_screen.dart
