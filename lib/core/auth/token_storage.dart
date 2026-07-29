import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/app_logger.dart';
import '../utils/constants.dart';

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

  Box get _hive => Hive.box(AppConstants.tokenBackupBox);

  /// Saves tokens to encrypted secure storage, SharedPreferences mirror, and
  /// Hive backup.  Hive backup is NEVER touched by [clearTokens] — it survives
  /// accidental token clearing and acts as a recovery source.
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
        _hive.put(_accessKey, access),
        _hive.put(_refreshKey, refresh),
      ]);
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to save tokens', e);
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        prefs.setString(bgAccessTokenKey, access),
        prefs.setString(bgRefreshTokenKey, refresh),
        _hive.put(_accessKey, access),
        _hive.put(_refreshKey, refresh),
      ]);
    }
  }

  Future<String?> getAccessToken() async {
    await _syncFromBackgroundMirror();
    try {
      final token = await _storage.read(key: _accessKey);
      if (token != null && token.isNotEmpty) return token;
    } catch (e) {
      AppLogger.e('TokenStorage: SecureStorage read failed', e);
    }
    return _fallbackAccessToken();
  }

  Future<String?> getRefreshToken() async {
    await _syncFromBackgroundMirror();
    try {
      final token = await _storage.read(key: _refreshKey);
      if (token != null && token.isNotEmpty) return token;
    } catch (e) {
      AppLogger.e('TokenStorage: SecureStorage read failed', e);
    }
    return _fallbackRefreshToken();
  }

  /// Fallback chain: SharedPreferences → Hive backup
  Future<String?> _fallbackAccessToken() async {
    final prefs = await SharedPreferences.getInstance();
    final bg = prefs.getString(bgAccessTokenKey);
    if (bg != null && bg.isNotEmpty) return bg;
    return _hive.get(_accessKey) as String?;
  }

  Future<String?> _fallbackRefreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    final bg = prefs.getString(bgRefreshTokenKey);
    if (bg != null && bg.isNotEmpty) return bg;
    return _hive.get(_refreshKey) as String?;
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

      final currentAccess = await _storage.read(key: _accessKey);

      if (bgAccess != currentAccess) {
        AppLogger.i('TokenStorage: Syncing newer tokens from background mirror (TS: $bgTs)');
        await Future.wait([
          _storage.write(key: _accessKey, value: bgAccess),
          _storage.write(key: _refreshKey, value: bgRefresh),
          _hive.put(_accessKey, bgAccess),
          _hive.put(_refreshKey, bgRefresh),
        ]);
      }
    } catch (e) {
      AppLogger.w('TokenStorage: _syncFromBackgroundMirror failed: $e');
    }
  }

  /// Clears tokens from secure storage and SharedPreferences.
  /// Hive backup is intentionally preserved — it survives accidental clears.
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
      AppLogger.i('TokenStorage: Secure tokens cleared (Hive backup preserved)');
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to clear tokens', e);
    }
  }

  /// Restores tokens from Hive backup back into secure storage.
  /// Returns true if tokens were found and restored.
  Future<bool> tryRestoreFromBackup() async {
    try {
      final access = _hive.get(_accessKey) as String?;
      final refresh = _hive.get(_refreshKey) as String?;
      if (access == null || refresh == null) return false;
      AppLogger.i('TokenStorage: Restoring tokens from Hive backup');
      await saveTokens(access, refresh);
      return true;
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to restore from backup', e);
      return false;
    }
  }

  /// Permanently clears the Hive backup.  Only called on explicit user logout.
  Future<void> clearBackup() async {
    try {
      await _hive.delete(_accessKey);
      await _hive.delete(_refreshKey);
      AppLogger.i('TokenStorage: Hive backup cleared');
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to clear backup', e);
    }
  }

  Future<bool> hasTokens() async {
    try {
      await _syncFromBackgroundMirror();
      final token = await _storage.read(key: _accessKey);
      if (token != null && token.isNotEmpty) return true;
    } catch (_) {}
    // Fallback to SharedPreferences (background mirror)
    // Hive backup is NOT checked here — it is a reactive fallback for
    // getAccessToken() mid-session, not an auto-login source.
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(bgAccessTokenKey);
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
