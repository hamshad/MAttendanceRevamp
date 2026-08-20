---
status: verifying
trigger: "429 Too Many Requests error during login sometimes (Flutter/dio) + token suddenly flushed"
created: 2026-08-07
updated: 2026-08-07
---

## Current Focus

hypothesis: CONFIRMED - two related bugs: (1) 429 unmapped on login, (2) transient refresh failure (429) leaks original 401 to _tryAutoLogin -> clearTokens -> token flush
test: analyze + contract tests + full suite regression (13 fails after vs 15 baseline, all pre-existing unrelated)
expecting: verified - no new failures, analyze clean
next_action: commit + report

## Symptoms

expected: login succeeds; session survives transient server errors
actual: login occasionally throws 429 raw Dio message; token suddenly flushed -> kicked to login screen
errors: "status code 429, RequestOptions.validateStatus configured to throw"
reproduction: "trying to login sometimes" - intermittent
started: unknown

## Eliminated

- hypothesis: client retry storm on login
  evidence: login is single POST, no retry_dio/RetryInterceptor, `_isLoading` disables button; auth_api.dart no retry loop
  timestamp: 2026-08-07
- hypothesis: validateStatus misconfigured in client
  evidence: zero validateStatus overrides in lib/; message is standard Dio default boilerplate (throws for >=400)
  timestamp: 2026-08-07
- hypothesis: background workers flush tokens on 429
  evidence: field_tracking, geofence, wifi workers + offline_sync_manager all explicitly retain tokens on refresh failure (comments: "Do NOT wipe", "retaining tokens for main isolate")
  timestamp: 2026-08-07
- hypothesis: 429 directly clears tokens in dio_client
  evidence: _onError only intercepts 401; refresh 429 hits catch-all which retains session
  timestamp: 2026-08-07

## Evidence

- timestamp: 2026-08-07
  checked: lib/core/auth/auth_api.dart
  found: login = one POST /api/v1/auth/login; catches DioException, rethrows e.error if ApiException else Exception(e.message)
  implication: 429 error text = raw Dio message; no friendly mapping
- timestamp: 2026-08-07
  checked: lib/core/api/dio_client.dart _onError/_mapError
  found: only 401 intercepted; 429 falls through _mapError with NO branch (only 401/404/400/5xx mapped) -> stays raw DioException
  implication: client never converts 429 to user-friendly ApiException
- timestamp: 2026-08-07
  checked: whole lib/ for validateStatus, retry_dio, 429 handling
  found: no validateStatus override, no 429 handling anywhere; default Dio throws on >=400
  implication: message is standard Dio boilerplate, not config bug
- timestamp: 2026-08-07
  checked: ROOT CAUSE #2 - refresh-failure error leak (chain)
  found: token expired -> any request 401 -> interceptor refresh POST -> rate limit 429 -> catch-all "retaining session" but handler.next(_mapError(ORIGINAL 401)) -> caller AuthProvider._tryAutoLogin sees e.response.statusCode==401 -> "token definitively rejected" -> clearTokens() + return null -> LoginScreen. Same leak in partial-state branch + _rejectPendingRequests.
  implication: THE token flush. User's instinct correct: recurring rate limit on /auth/refresh (same limiter as login) -> refresh 429 -> flushed despite "no logout on 429" guard (guard held inside interceptor but leaked 401-flagged error to caller)
  timestamp: 2026-08-07
- timestamp: 2026-08-07
  checked: verification
  found: flutter analyze clean (0 errors); contract tests pass; full suite 13 fails vs baseline 15 (pre-existing: geofence notification singleton LateInitializationError, trend analyzer) — zero regressions
  implication: fix verified at code/test level

## Resolution

root_cause: (1) 429 unmapped -> raw Dio error shown on login. (2) Transient refresh failure (429/5xx/network) propagates original 401-flagged error; _tryAutoLogin misreads it as definitive rejection and clears tokens -> sudden logout. Both stem from same server-side /auth/* rate limiter.
fix: map 429 -> TooManyRequestsException (friendly msg + Retry-After); new SessionRefreshFailedException marker for transient refresh failures; dio_client propagates marker (catch-all + partial-state + queued requests); _tryAutoLogin clears tokens ONLY on genuine ApiException(401); login_screen onFieldSubmitted guarded against double-submit
verification: analyze clean; test/core/api/refresh_failure_contract_test.dart (4 tests pass); full suite no new failures
files_changed: [lib/core/api/api_exceptions.dart, lib/core/api/dio_client.dart, lib/core/auth/auth_provider.dart, lib/features/auth/screens/login_screen.dart, test/core/api/refresh_failure_contract_test.dart]
