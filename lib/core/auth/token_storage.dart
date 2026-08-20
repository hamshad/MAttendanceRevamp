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
  static const bgRefreshLockOwnerKey = 'bg_refresh_lock_owner';

  // Session-generation marker.  Written on every successful token save
  // (login + refresh), removed on logout/clear.  Background workers capture
  // it at the start of a refresh and verify it is unchanged before writing
  // refreshed tokens — prevents cross-session resurrection and stale writes.
  static const authSessionIdKey = 'auth_session_id';

  // Hive-side timestamp of the last full save.  Used by
  // _syncFromBackgroundMirror to only sync the SP mirror down when it is
  // actually NEWER than what secure storage already holds.
  static const _savedAtKey = 'token_saved_at';

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  Box get _hive => Hive.box(AppConstants.tokenBackupBox);

  static int _sessionIdCounter = 0;

  /// Unique per save-generation marker.  Regenerating on every save means
  /// an in-flight background refresh detects "tokens changed under me" by
  /// comparing its captured id against the current one.
  static String _newSessionId() {
    _sessionIdCounter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_sessionIdCounter';
  }

  /// Saves tokens to encrypted secure storage, SharedPreferences mirror, and
  /// Hive backup.  Hive backup is NEVER touched by [clearTokens] — it survives
  /// accidental token clearing and acts as a recovery source.
  Future<void> saveTokens(String access, String refresh) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessionId = _newSessionId();
    try {
      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        _storage.write(key: _accessKey, value: access),
        _storage.write(key: _refreshKey, value: refresh),
        prefs.setString(bgAccessTokenKey, access),
        prefs.setString(bgRefreshTokenKey, refresh),
        prefs.setInt(bgTokenTimestampKey, now),
        prefs.setString(authSessionIdKey, sessionId),
        _hive.put(_accessKey, access),
        _hive.put(_refreshKey, refresh),
        _hive.put(_savedAtKey, now),
      ]);
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to save tokens', e);
      // Fallback: persist to SP + Hive only (secure storage may be
      // unavailable).  Never rethrow — a partial save is better than a
      // failed login, and the mirror sync repairs secure storage later.
      try {
        final prefs = await SharedPreferences.getInstance();
        await Future.wait([
          prefs.setString(bgAccessTokenKey, access),
          prefs.setString(bgRefreshTokenKey, refresh),
          prefs.setInt(bgTokenTimestampKey, now),
          prefs.setString(authSessionIdKey, sessionId),
          _hive.put(_accessKey, access),
          _hive.put(_refreshKey, refresh),
          _hive.put(_savedAtKey, now),
        ]);
      } catch (e2) {
        AppLogger.e('TokenStorage: Fallback token save also failed', e2);
      }
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
  ///
  /// Two guards prevent clobbering:
  /// 1. Session marker must still exist (skip after logout / resurrection).
  /// 2. SP mirror timestamp must be NEWER than the last full save.
  Future<void> _syncFromBackgroundMirror() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // Guard 1: no active session → never sync (prevents resurrecting
      // tokens after logout).
      if (!prefs.containsKey(authSessionIdKey)) return;

      final bgAccess = prefs.getString(bgAccessTokenKey);
      final bgRefresh = prefs.getString(bgRefreshTokenKey);
      final bgTs = prefs.getInt(bgTokenTimestampKey) ?? 0;

      if (bgAccess == null || bgRefresh == null || bgTs == 0) return;

      // Guard 2: only sync if the mirror is newer than the last full save.
      // Without this, a background isolate that finished refreshing AFTER the
      // main isolate could write a stale pair and clobber fresh tokens.
      final savedAt = _hive.get(_savedAtKey) as int? ?? 0;
      if (bgTs <= savedAt) return;

      final currentAccess = await _storage.read(key: _accessKey);
      if (bgAccess == currentAccess) return;

      AppLogger.i('TokenStorage: Syncing newer tokens from background mirror (TS: $bgTs > saved: $savedAt)');
      await Future.wait([
        _storage.write(key: _accessKey, value: bgAccess),
        _storage.write(key: _refreshKey, value: bgRefresh),
        _hive.put(_accessKey, bgAccess),
        _hive.put(_refreshKey, bgRefresh),
        _hive.put(_savedAtKey, bgTs),
      ]);
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
        prefs.remove(bgRefreshLockOwnerKey),
        prefs.remove(authSessionIdKey),
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
      if (access == null || access.isEmpty || refresh == null || refresh.isEmpty) {
        return false;
      }
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
      await _hive.delete(_savedAtKey);
      AppLogger.i('TokenStorage: Hive backup cleared');
    } catch (e) {
      AppLogger.e('TokenStorage: Failed to clear backup', e);
    }
  }

  Future<bool> hasTokens() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      // Session-generation marker must exist.  Prevents auto-login with
      // tokens resurrected by a background isolate after logout.
      if (!prefs.containsKey(authSessionIdKey)) {
        // Hive backup may still hold a valid session that was accidentally
        // cleared (restore path repopulates the marker).
        final hiveAccess = _hive.get(_accessKey) as String?;
        if (hiveAccess == null || hiveAccess.isEmpty) return false;
        // Found Hive tokens but no session marker — restore them.
        return tryRestoreFromBackup();
      }

      await _syncFromBackgroundMirror();
      final token = await _storage.read(key: _accessKey);
      if (token != null && token.isNotEmpty) return true;
    } catch (_) {}
    // Fallback to SharedPreferences (background mirror)
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(bgAccessTokenKey) &&
        prefs.containsKey(authSessionIdKey);
  }

  /// Acquisition of a cross-isolate refresh lock.
  ///
  /// Claims the lock by writing a unique owner token, then re-reads and
  /// verifies ownership.  If another isolate wrote after us, we lost the
  /// claim and back off.  Returns true only if we hold the lock.
  Future<bool> acquireRefreshLock() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final lockTs = prefs.getInt(bgRefreshLockKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Lock is considered stale after 30 seconds
    if (lockTs > 0 && (now - lockTs) < 30000) {
      return false;
    }

    // Claim the lock with a unique owner token
    final owner = '$now-${_newSessionId()}';
    await prefs.setInt(bgRefreshLockKey, now);
    await prefs.setString(bgRefreshLockOwnerKey, owner);

    // Verify we won the claim — if another isolate wrote after us, back off.
    await prefs.reload();
    final persistedOwner = prefs.getString(bgRefreshLockOwnerKey);
    final persistedTs = prefs.getInt(bgRefreshLockKey) ?? 0;
    if (persistedOwner != owner || persistedTs != now) {
      AppLogger.w('TokenStorage: Lost refresh-lock race to another isolate');
      return false;
    }
    return true;
  }

  Future<void> releaseRefreshLock() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.remove(bgRefreshLockKey),
      prefs.remove(bgRefreshLockOwnerKey),
    ]);
  }
}
