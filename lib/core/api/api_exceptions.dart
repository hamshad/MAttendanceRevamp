class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class UnauthorizedException extends ApiException {
  const UnauthorizedException() : super('Session expired. Please log in again.', statusCode: 401);
}

class NotFoundException extends ApiException {
  const NotFoundException(super.message) : super(statusCode: 404);
}

class ValidationException extends ApiException {
  final Map<String, List<String>>? errors;

  const ValidationException(super.message, {this.errors, super.statusCode = 400});
}

class NetworkException extends ApiException {
  const NetworkException() : super('No internet connection. Please check your network.');
}

class ServerException extends ApiException {
  const ServerException([super.message = 'Server error. Please try again later.'])
      : super(statusCode: 500);
}

class TooManyRequestsException extends ApiException {
  /// Seconds to wait before retrying, from the server's `Retry-After` header.
  final int? retryAfterSeconds;

  const TooManyRequestsException([
    super.message = 'Too many requests. Please wait a moment and try again.',
    this.retryAfterSeconds,
  ]) : super(statusCode: 429);
}

/// Raised by the DioClient interceptor when the token-refresh call fails for
/// a transient reason (429 rate limit, 5xx, network, ambiguous status).
///
/// The session is RETAINED — callers MUST NOT clear tokens on this. It
/// signals "this request failed, but not because the session is dead".
/// Callers must only treat a genuine `ApiException(statusCode: 401)` as
/// definitive token rejection.
class SessionRefreshFailedException extends ApiException {
  const SessionRefreshFailedException()
      : super('Session refresh temporarily failed. Please try again.');
}
