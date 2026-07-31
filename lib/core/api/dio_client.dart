import 'dart:io';
import 'package:dio/dio.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/token_storage.dart';
import '../utils/app_logger.dart';
import '../utils/constants.dart';
import 'api_exceptions.dart';
import 'punch_state_interceptor.dart';

class DioClient {
  late final Dio _dio;
  final TokenStorage _tokenStorage;

  /// Called when the session cannot be restored (refresh failed or no refresh token).
  /// Should trigger navigation to the login screen.
  void Function()? onSessionExpired;

  // Prevents concurrent refresh loops
  bool _isRefreshing = false;

  // Guards against spawning multiple "wait for other isolate" loops for
  // the same refresh window.
  bool _waitingForLock = false;

  // Requests that arrived while a refresh was already in progress
  final List<({RequestOptions options, ErrorInterceptorHandler handler})>
      _pendingRequests = [];

  // Device/app info populated once during init
  String _appVersion = AppConstants.appVersion;
  final String _platform = Platform.isAndroid ? 'android' : 'ios';
  String _deviceId = 'unknown';

  DioClient(this._tokenStorage) {
    _dio = Dio(BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
      connectTimeout: AppConstants.connectTimeout,
      receiveTimeout: AppConstants.receiveTimeout,
      headers: {'Content-Type': 'application/json'},
    ));

    _dio.interceptors.addAll([
      InterceptorsWrapper(
        onRequest: _onRequest,
        onResponse: _onResponse,
        onError: _onError,
      ),
      PunchStateInterceptor(),
      if (kDebugMode)
        PrettyDioLogger(
          requestHeader: true,
          requestBody: true,
          responseHeader: false,
          responseBody: true,
          error: true,
          compact: true,
          maxWidth: 90,
        ),
    ]);

    _initDeviceInfo();
  }

  Future<void> _initDeviceInfo() async {
    try {
      final pkgInfo = await PackageInfo.fromPlatform();
      _appVersion = pkgInfo.version;

      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await deviceInfo.androidInfo;
        _deviceId = info.id;
      } else if (Platform.isIOS) {
        final info = await deviceInfo.iosInfo;
        _deviceId = info.identifierForVendor ?? 'unknown';
      }
    } catch (_) {
      // Non-critical — defaults already set
    }
  }

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    String? token = await _tokenStorage.getAccessToken();
    if (token == null && !options.path.contains('/auth/')) {
      // Retry once — guards against transient FlutterSecureStorage failures
      // that would cascade into forceLogout if we synthesised a 401 here.
      token = await _tokenStorage.getAccessToken();
    }
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    // If token is still null for a non-auth endpoint, let the request through
    // without auth header. The server returns a real 401 if auth is required,
    // and our 401 interceptor handles refresh properly using the refresh token.
    // Previously we synthesised a 401 here which could cascade into
    // forceLogout on transient storage failures.

    options.headers['X-Client-Type'] = 'mobile';
    options.headers['X-Platform'] = _platform;
    options.headers['X-App-Version'] = _appVersion;
    options.headers['X-Device-Id'] = _deviceId;

    AppLogger.apiRequest(
      options.method,
      options.uri.toString(),
      data: options.data,
      query: options.queryParameters,
    );

    handler.next(options);
  }

  void _onResponse(
    Response response,
    ResponseInterceptorHandler handler,
  ) {
    AppLogger.apiResponse(
      response.requestOptions.method,
      response.requestOptions.uri.toString(),
      response.statusCode,
      data: response.data,
    );
    handler.next(response);
  }

  Future<void> _onError(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    // Only intercept 401 Unauthorized
    if (error.response?.statusCode != 401) {
      AppLogger.w('[AUTH] Non-401 error (${error.response?.statusCode}) on ${error.requestOptions.path}');
      return handler.next(_mapError(error));
    }

    AppLogger.i('[AUTH] 401 on ${error.requestOptions.path} — isRefreshing=$_isRefreshing');

    // If a refresh is already in progress in THIS isolate, queue this request for retry
    if (_isRefreshing) {
      AppLogger.i('[AUTH] Queuing request (refresh already in progress): ${error.requestOptions.path}');
      _pendingRequests.add((options: error.requestOptions, handler: handler));
      return;
    }

    _isRefreshing = true;

    // Check cross-isolate lock
    if (!await _tokenStorage.acquireRefreshLock()) {
      AppLogger.w('[AUTH] 401: Another isolate is already refreshing tokens. Queuing request.');
      _pendingRequests.add((options: error.requestOptions, handler: handler));

      // Only start ONE wait loop for all queued requests.  When the other
      // isolate's refresh completes, we re-read tokens and retry everything.
      if (!_waitingForLock) {
        _waitingForLock = true;
        _waitForOtherIsolateRefresh();
      }
      return;
    }

    // Snapshot of the mirror timestamp BEFORE our refresh attempt.  On a
    // refresh 400 we compare against this to detect that another isolate
    // refreshed successfully while we were trying (concurrent-refresh race)
    // so we can adopt its tokens instead of force-logging-out.
    final refreshStartTs = await _mirrorTokenTs();

    // Refresh token we actually sent — captured outside try so the catch
    // block can compare against the current pair on a 400.
    String? sentRefreshToken;

    try {
      String? refreshToken = await _tokenStorage.getRefreshToken();
      String? expiredAccessToken = await _tokenStorage.getAccessToken();

      if (refreshToken == null) {
        // Retry once — could be transient FlutterSecureStorage failure
        AppLogger.w('[AUTH] Refresh token null — retrying read...');
        await Future.delayed(const Duration(milliseconds: 100));
        refreshToken = await _tokenStorage.getRefreshToken();
        if (expiredAccessToken == null) {
          expiredAccessToken = await _tokenStorage.getAccessToken();
        }
      }

      if (refreshToken == null) {
        if (expiredAccessToken != null ||
            await _tokenStorage.getAccessToken() != null) {
          // Access token exists but refresh missing — partial state, don't
          // force logout. The request fails but session survives.
          AppLogger.w('[AUTH] No refresh token but access token exists — retaining session');
          _isRefreshing = false;
          await _tokenStorage.releaseRefreshLock();
          _rejectPendingRequests(error);
          return handler.next(_mapError(error));
        }
        AppLogger.w('[AUTH] No refresh token — clearing session');
        await _handleRefreshFailure(error, handler);
        return;
      }

      AppLogger.i('[AUTH] Starting token refresh...');
      sentRefreshToken = refreshToken;
      
      // Implement retry for the refresh call itself (max 3 attempts)
      String? newAccess;
      String? newRefresh;
      int retryCount = 0;
      bool refreshSuccess = false;

      while (retryCount < 3 && !refreshSuccess) {
        try {
          final refreshDio = Dio(BaseOptions(
            baseUrl: AppConstants.apiBaseUrl,
            connectTimeout: const Duration(seconds: 15),
          ));
          final response = await refreshDio.post(
            '/api/v1/auth/refresh',
            data: {
              'accessToken': expiredAccessToken ?? '',
              'refreshToken': refreshToken,
            },
          );

          newAccess = response.data['accessToken'] as String;
          newRefresh = response.data['refreshToken'] as String;
          refreshSuccess = true;
        } catch (e) {
          retryCount++;
          final isTransient = e is DioException && 
              (e.type != DioExceptionType.badResponse || (e.response?.statusCode ?? 0) >= 500);
          
          if (!isTransient || retryCount >= 3) {
            rethrow;
          }
          AppLogger.w('[AUTH] Refresh attempt $retryCount failed (transient). Retrying in 2s...');
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      if (refreshSuccess && newAccess != null && newRefresh != null) {
        await _tokenStorage.saveTokens(newAccess, newRefresh);
        await _tokenStorage.releaseRefreshLock();

        AppLogger.i('[AUTH] Tokens saved. Retrying original request: ${error.requestOptions.path}');
        error.requestOptions.headers['Authorization'] = 'Bearer $newAccess';
        final retryResponse = await _dio.fetch(error.requestOptions);
        
        _isRefreshing = false;
        _flushPendingRequests(newAccess);
        return handler.resolve(retryResponse);
      }
    } catch (e) {
      await _tokenStorage.releaseRefreshLock();
      _isRefreshing = false;

      final isNetworkError = e is DioException &&
          (e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.sendTimeout ||
              e.type == DioExceptionType.receiveTimeout ||
              e.type == DioExceptionType.connectionError ||
              e.response == null);

      final isServerError = e is DioException &&
          e.response != null &&
          e.response!.statusCode != null &&
          e.response!.statusCode! >= 500;

      // Only 400 Bad Request from the refresh endpoint means the token was
      // definitively rejected (revoked / invalid). All other errors are
      // transient and MUST NOT force-logout the user.
      final isTokenRejected = e is DioException &&
          e.response != null &&
          e.response!.statusCode == 400;

      if (isNetworkError || isServerError) {
        AppLogger.w('[AUTH] Refresh failed due to network/server error. Session retained.');
        _rejectPendingRequests(e);
        return handler.next(_mapError(e));
      }

      if (isTokenRejected) {
        // A 400 from /auth/refresh means the refresh token we sent was
        // definitively rejected.  BUT this can also be the loser's outcome
        // in a concurrent-refresh race: another isolate refreshed with the
        // SAME refresh token a moment earlier, the server rotated it, and our
        // attempt failed.  Before force-logging-out, check whether the token
        // pair actually changed while we were refreshing — if so, adopt the
        // newer pair and retry instead of destroying the session.
        final adopted = await _adoptNewerTokensIfRefreshed(
          refreshStartTs: refreshStartTs,
          attemptedRefresh: sentRefreshToken ?? '',
          error: error,
          handler: handler,
        );
        if (adopted) return;

        AppLogger.e('[AUTH] Refresh token rejected by server (400) — clearing session', e);
        await _handleRefreshFailure(error, handler);
        return;
      }

      // Catch-all for ambiguous errors (429, 403, parse failures, etc.).
      // Never force-logout on errors we can't positively identify as
      // token-revocation — the next request may succeed.
      AppLogger.w('[AUTH] Refresh failed (non-fatal) — retaining session', e);
      _rejectPendingRequests(error);
      return handler.next(_mapError(error));
    }
  }

  Future<void> _handleRefreshFailure(DioException error, ErrorInterceptorHandler handler) async {
    await _tokenStorage.clearTokens();
    // NOTE: Hive backup is intentionally preserved here.  It survives an
    // accidental/race-induced clear and acts as a recovery source in
    // AuthProvider._tryAutoLogin (restore + re-validate).  Only explicit
    // user logout calls clearBackup().
    _isRefreshing = false;
    _rejectPendingRequests(error);
    _notifySessionExpired();
    handler.next(_mapError(error));
  }

  /// Timestamp of the token mirror before we started refreshing.  Used to
  /// detect whether another isolate completed a refresh while we were trying.
  Future<int> _mirrorTokenTs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return prefs.getInt(TokenStorage.bgTokenTimestampKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// If tokens changed while we were refreshing (another isolate won the
  /// concurrent-refresh race and rotated the refresh token), adopt the newer
  /// pair and retry the original request instead of force-logging-out.
  Future<bool> _adoptNewerTokensIfRefreshed({
    required int refreshStartTs,
    required String attemptedRefresh,
    required DioException error,
    required ErrorInterceptorHandler handler,
  }) async {
    try {
      await _tokenStorage.releaseRefreshLock();
      // Re-read current tokens (getRefreshToken syncs a newer mirror first).
      final currentRefresh = await _tokenStorage.getRefreshToken();
      if (currentRefresh == null || currentRefresh == attemptedRefresh) {
        // Tokens did not change — our 400 was genuine token rejection.
        return false;
      }
      final newAccess = await _tokenStorage.getAccessToken();
      if (newAccess == null) return false;

      AppLogger.i('[AUTH] Concurrent refresh detected (ts $refreshStartTs) — adopting newer tokens and retrying');
      _isRefreshing = false;
      _flushPendingRequests(newAccess);

      error.requestOptions.headers['Authorization'] = 'Bearer $newAccess';
      try {
        final resp = await _dio.fetch(error.requestOptions);
        handler.resolve(resp);
        return true;
      } catch (e) {
        handler.next(e is DioException ? e : error);
        return true;
      }
    } catch (e) {
      AppLogger.w('[AUTH] _adoptNewerTokensIfRefreshed failed: $e');
      return false;
    }
  }

  /// Waits for another isolate's refresh to complete, then flushes queued
  /// requests with the refreshed token.  NEVER re-enters [_onError] — if the
  /// other isolate never releases the lock, queued requests are rejected and
  /// the next API call starts a fresh refresh attempt (no double-refresh loop).
  void _waitForOtherIsolateRefresh() async {
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 2));
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.reload();
        if (prefs.containsKey(TokenStorage.bgRefreshLockKey)) continue;

        // Other isolate finished — sync mirror → secure storage, retry queue.
        AppLogger.i('[AUTH] Other isolate finished refresh. Syncing and retrying queued requests.');
        final newAccess = await _tokenStorage.getAccessToken();
        _isRefreshing = false;
        _waitingForLock = false;
        if (newAccess != null) {
          _flushPendingRequests(newAccess);
        } else {
          _rejectPendingRequests(DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.unknown,
            error: 'Token refresh failed',
          ));
        }
        return;
      } catch (_) {
        // Transient SharedPreferences error — keep waiting.
      }
    }

    // Timed out: the other isolate never released the lock.  Fail queued
    // requests cleanly; do NOT re-enter _onError (would double-refresh).
    AppLogger.w('[AUTH] Timed out waiting for other isolate refresh');
    _isRefreshing = false;
    _waitingForLock = false;
    _rejectPendingRequests(DioException(
      requestOptions: RequestOptions(path: ''),
      type: DioExceptionType.unknown,
      error: 'Token refresh timed out',
    ));
  }

  /// Retry all queued requests with the new access token after a successful refresh.
  void _flushPendingRequests(String newAccessToken) {
    final pending = List.of(_pendingRequests);
    _pendingRequests.clear();
    for (final req in pending) {
      req.options.headers['Authorization'] = 'Bearer $newAccessToken';
      _dio.fetch(req.options).then(
        (response) => req.handler.resolve(response),
        onError: (e) => req.handler.next(
          e is DioException
              ? e
              : DioException(requestOptions: req.options, error: e),
        ),
      );
    }
  }

  /// Reject all queued requests when refresh fails.
  void _rejectPendingRequests(DioException originalError) {
    final pending = List.of(_pendingRequests);
    _pendingRequests.clear();
    for (final req in pending) {
      req.handler.next(
        _mapError(originalError.copyWith(requestOptions: req.options)),
      );
    }
  }

  void _notifySessionExpired() {
    onSessionExpired?.call();
  }

  DioException _mapError(DioException error) {
    if (error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.connectionTimeout) {
      return error.copyWith(error: const NetworkException());
    }

    final status = error.response?.statusCode;
    final message =
        _extractMessage(error.response?.data) ?? error.message ?? 'Unknown error';

    if (status == 401) {
      return error.copyWith(
        error: ApiException(
          message.isNotEmpty ? message : 'Session expired. Please log in again.',
          statusCode: 401,
        ),
      );
    }
    if (status == 404) return error.copyWith(error: NotFoundException(message));
    if (status == 400) return error.copyWith(error: ValidationException(message));
    if (status != null && status >= 500) {
      return error.copyWith(error: ServerException(message));
    }

    return error;
  }

  String? _extractMessage(dynamic data) {
    if (data == null) return null;
    if (data is Map) {
      return data['message'] as String? ??
          data['title'] as String? ??
          data['error'] as String?;
    }
    return data.toString();
  }

  Dio get dio => _dio;
}
