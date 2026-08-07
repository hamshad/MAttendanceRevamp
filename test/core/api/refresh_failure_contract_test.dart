import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/core/api/api_exceptions.dart';

/// Guards the "never logout on transient refresh failure" contract.
///
/// Regression test for: access token expired → request 401 → interceptor
/// refresh hits a 429 rate limit → interceptor retained the session but
/// propagated the original 401-flagged error → AuthProvider._tryAutoLogin
/// misinterpreted it as definitive token rejection and cleared tokens.
///
/// The decision predicate in _tryAutoLogin is:
///   apiErr is ApiException && apiErr.statusCode == 401  →  clear tokens
/// A transient refresh failure must NEVER satisfy it.
void main() {
  group('SessionRefreshFailedException contract', () {
    test('is an ApiException but never looks like a 401 rejection', () {
      const transient = SessionRefreshFailedException();

      expect(transient, isA<ApiException>());
      expect(transient.statusCode, isNot(401));
      // The exact predicate used by _tryAutoLogin to decide "clear tokens".
      // (apiErr is ApiException && apiErr.statusCode == 401)
      expect(transient.statusCode == 401, isFalse);
    });

    test('genuine rejection still satisfies the clear predicate', () {
      const genuine = ApiException('Session expired', statusCode: 401);

      expect(genuine.statusCode, 401);
    });

    test('429 maps to a 429 typed exception, not 401', () {
      const rateLimited = TooManyRequestsException();

      expect(rateLimited.statusCode, 429);
      expect(rateLimited.statusCode == 401, isFalse);
    });

    test('TooManyRequestsException carries Retry-After hint', () {
      const withRetryAfter = TooManyRequestsException('Wait 30s', 30);
      expect(withRetryAfter.retryAfterSeconds, 30);
      expect(withRetryAfter.statusCode, 429);
    });
  });
}
