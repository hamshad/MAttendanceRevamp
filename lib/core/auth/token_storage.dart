import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_logger.dart';

class TokenStorage {
  static const _accessKey = 'access_token';
  static const _refreshKey = 'refresh_token';

  // Keys used by the background tracking isolate.  Must stay in sync with the
  // constants in field_tracking_service.dart.
  static const bgAccessTokenKey = 'bg_access_token';
  static const bgRefreshTokenKey = 'bg_refresh_token';
  static const bgTokenTimestampKey = 'bg_token_ts';
  static const bgRefreshLockKey = 'bg_refresh_lock';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Saves tokens to encrypted secure storage AND mirrors them to
  /// plain SharedPreferences for background isolate accessibility.
  Future<void> saveTokens(String access, String refresh) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        _storage.write(key: _accessKey, value: access),
        _storage.write(key: _refreshKey, value: refresh),
        prefs.setString(bgAccessTokenKey, access),
        prefs.setString(bgRefreshTokenKey, refresh),
        prefs.setInt(bgTokenTimestampKey, now),
      ]);
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to save tokens', e);
      // Fallback: at least try to save to SharedPreferences if SecureStorage fails
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(bgAccessTokenKey, access);
      await prefs.setString(bgRefreshTokenKey, refresh);
    }
  }

  Future<String?> getAccessToken() async {
    await _syncFromBackgroundMirror();
    try {
      return await _storage.read(key: _accessKey);
    } catch (e) {
      AppLogger.e('TokenStorage: SecureStorage read failed', e);
      // Fallback to background mirror if secure storage is transiently unavailable
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(bgAccessTokenKey);
    }
  }

  Future<String?> getRefreshToken() async {
    await _syncFromBackgroundMirror();
    try {
      return await _storage.read(key: _refreshKey);
    } catch (e) {
      AppLogger.e('TokenStorage: SecureStorage read failed', e);
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(bgRefreshTokenKey);
    }
  }

  /// Checks if the background tracking isolate has refreshed tokens in
  /// SharedPreferences and syncs them back to secure storage if they are newer.
  Future<void> _syncFromBackgroundMirror() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final bgAccess = prefs.getString(bgAccessTokenKey);
      final bgRefresh = prefs.getString(bgRefreshTokenKey);
      final bgTs = prefs.getInt(bgTokenTimestampKey) ?? 0;

      if (bgAccess == null || bgRefresh == null) return;

      // We don't have a timestamp for SecureStorage tokens, so we rely on 
      // the fact that background isolate only writes to SharedPreferences
      // when it successfully refreshes. 
      final currentAccess = await _storage.read(key: _accessKey);
      
      if (bgAccess != currentAccess) {
        AppLogger.i('TokenStorage: Syncing newer tokens from background mirror (TS: $bgTs)');
        await Future.wait([
          _storage.write(key: _accessKey, value: bgAccess),
          _storage.write(key: _refreshKey, value: bgRefresh),
        ]);
      }
    } catch (e) {
      // Non-critical sync failed
      AppLogger.w('TokenStorage: _syncFromBackgroundMirror failed: $e');
    }
  }

  /// Clears all tokens from both secure storage and the background-readable
  /// SharedPreferences mirror.
  Future<void> clearTokens() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        _storage.deleteAll(),
        prefs.remove(bgAccessTokenKey),
        prefs.remove(bgRefreshTokenKey),
        prefs.remove(bgTokenTimestampKey),
        prefs.remove(bgRefreshLockKey),
      ]);
      AppLogger.i('TokenStorage: All tokens cleared');
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to clear tokens', e);
    }
  }

  Future<bool> hasTokens() async {
    try {
      await _syncFromBackgroundMirror();
      final token = await _storage.read(key: _accessKey);
      return token != null && token.isNotEmpty;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(bgAccessTokenKey);
    }
  }

  /// Acquisition of a cross-isolate refresh lock.
  /// Returns true if lock acquired, false if another isolate is refreshing.
  Future<bool> acquireRefreshLock() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final lockTs = prefs.getInt(bgRefreshLockKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Lock is considered stale after 30 seconds
    if (lockTs > 0 && (now - lockTs) < 30000) {
      return false;
    }

    await prefs.setInt(bgRefreshLockKey, now);
    return true;
  }

  Future<void> releaseRefreshLock() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(bgRefreshLockKey);
  }
}
