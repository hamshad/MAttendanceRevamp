import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// Application-wide logger for debugging and activity tracking.
class AppLogger {
  static final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 2,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      printTime: true,
    ),
  );

  /// Log a debug message
  static void d(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.d(message, error: error, stackTrace: stackTrace);
  }

  /// Log an info message
  static void i(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.i(message, error: error, stackTrace: stackTrace);
  }

  /// Log a warning message
  static void w(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.w(message, error: error, stackTrace: stackTrace);
  }

  /// Log an error message
  static void e(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
  }

  /// Log a verbose/trace message
  static void v(String message, [dynamic error, StackTrace? stackTrace]) {
    _logger.t(message, error: error, stackTrace: stackTrace);
  }

  /// Activity Logger: Can be extended to save logs to a database or file
  /// For now, it logs as INFOMATION level with a consistent prefix.
  static void activity(String activity, {Map<String, dynamic>? data}) {
    final message = 'ACTIVITY: $activity${data != null ? ' | DATA: $data' : ''}';
    _logger.i(message);
    
    // In a real application, you might want to save this to a remote service
    // or a local database for audit trails.
    if (kDebugMode) {
      print('📝 [ActivityLog] $activity');
    }
  }

  /// Specialized API Request Logger
  static void apiRequest(String method, String url, {dynamic data, Map<String, dynamic>? query}) {
    final message = '🚀 API REQUEST [$method]: $url\n  Body: $data\n  Query: $query';
    _logger.i(message);
  }

  /// Specialized API Response Logger
  static void apiResponse(String method, String url, int? status, {dynamic data}) {
    final icon = (status != null && status >= 200 && status < 300) ? '✅' : '❌';
    final message = '$icon API RESPONSE [$method] ($status): $url\n  Data: $data';
    if (status != null && status >= 200 && status < 300) {
      _logger.i(message);
    } else {
      _logger.e(message);
    }
  }
}
