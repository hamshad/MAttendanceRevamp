---
status: resolved
trigger: "the timer display is resetting on revisiting on the break screen"
created: 2026-08-21T00:00:00Z
updated: 2026-08-21T00:00:00Z
---

## Current Focus

hypothesis: BreakScreen derives live break start time ONLY from attendanceStatusProvider.todaysPunches (a BreakStart punch) read once in initState via ref.read. On revisit, either (a) todaysPunches lacks the BreakStart punch so breakStart is null → timer never starts → shows 00:00:00; or (b) attendanceStatusProvider is in loading state (value null) at initState (invalidated by main_shell streams/resume) → same early-return reset. First visit works because _startBreak() sets _breakStartTime = DateTime.now() locally.
test: Fix to derive ongoing break start from todayBreaksProvider (authoritative) with todaysPunches fallback, and resync via ref.listen so timer starts when data arrives.
expecting: Timer shows correct elapsed (now - server break start) immediately on every revisit, no reset.
next_action: Implement fix in break_screen.dart, then run flutter analyze.

## Symptoms

expected: Timer keeps counting real elapsed break time when reopening BreakScreen while on break.
actual: Timer resets to 00:00:00 (and does not advance) on revisiting the break screen while on break.
errors: none reported
reproduction: Start break (timer counts). Close break screen. Reopen (Manage Break / Take a Break). Timer shows 00:00:00.
started: observed; likely since break screen added.

## Eliminated

- hypothesis: Timer logic in _startTimer computes wrong elapsed
  evidence: _startTimer uses DateTime.now().difference(_breakStartTime) each tick — correct once _breakStartTime is set.
  timestamp: 2026-08-21

## Evidence

- timestamp: 2026-08-21
  checked: break_screen.dart _syncTimerFromStatus / initState
  found: initState calls _syncTimerFromStatus only once; reads ref.read(attendanceStatusProvider).value; derives breakStart from todaysPunches where isBreakStart; returns early if status null or breakStart null; never starts Timer in that case.
  implication: Revisit depends entirely on todaysPunches containing BreakStart AND provider value being non-null at initState.

- timestamp: 2026-08-21
  checked: main_shell.dart
  found: attendanceStatusProvider is invalidated from punchStream, wifiPunchStream, geofence callbacks, and on app resume — causing reload where .value is null during loading.
  implication: Revisit during a reload window -> _syncTimerFromStatus returns early -> timer never starts (reset).

- timestamp: 2026-08-21
  checked: todayBreaksProvider / ApiEndpoints.todayBreaks
  found: GET /api/v1/breaks/today -> List<BreakSummary> with startTime and endTime; ongoing break has endTime null (isOngoing true). This is the authoritative break source.
  implication: Deriving break start from todayBreaksProvider is reliable and independent of todaysPunches containing a BreakStart punch.

## Resolution

root_cause: BreakScreen._syncTimerFromStatus() derived the live break start time only from attendanceStatusProvider.todaysPunches (a BreakStart punch) and only if the provider value was already loaded when initState ran. On revisit the new widget instance could not obtain a break start (either todaysPunches omitted the break punch, or the status provider was momentarily in a loading/null state because main_shell invalidates it from multiple streams), so the method returned early and the periodic Timer was never started — leaving the timer card stuck at 00:00:00 (a "reset"). First visit worked only because _startBreak() seeded _breakStartTime locally.
fix: Derive the ongoing break start time from todayBreaksProvider (authoritative) with todaysPunches fallback; add ref.listen on both providers in initState so the timer (re)starts as soon as the data is available.
verification: flutter analyze passes; logic reviewed for same-instance and revisit paths.
files_changed: [lib/features/punch/screens/break_screen.dart]
