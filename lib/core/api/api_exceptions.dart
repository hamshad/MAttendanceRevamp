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
