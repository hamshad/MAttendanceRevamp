import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// OEMs whose ROMs aggressively kill background work (background process
/// spawn, WorkManager, deferred alarms) without user exemptions.
///
/// MIUI/HyperOS is the canonical pain (kills WorkManager tasks and blocks
/// background app starts without Autostart + battery exemption).
///
/// 2026-08-17 user decision: narrowed to the MI family ONLY.  Samsung,
/// Nothing and OnePlus are field-proven to work WITHOUT battery
/// restrictions (and OnePlus too) — exact alarms / special handling for
/// them was unnecessary.  MI users get the mandatory battery-restrictions
/// gate ([restrictionsConfirmed]).
class AggressiveOem {
  AggressiveOem._();

  static const String _prefKey = 'gf_aggressive_oem';

  static const String restrictionsConfirmedKey = 'gf_oem_restrictions_confirmed';

  static const _kChannel =
      MethodChannel('com.mattendance.mattendance_mobile/geofence_alarm');

  /// Brand strings (lowercased Build.BRAND / Build.MANUFACTURER) that need
  /// the keep-alive treatment.  MI family only (user decision 2026-08-17).
  static const List<String> aggressiveBrands = [
    'xiaomi',
    'redmi',
    'poco',
  ];

  /// Pure matcher — unit-testable.
  static bool isAggressiveBrand(String brand) {
    final b = brand.toLowerCase();
    return aggressiveBrands.any(b.contains);
  }

  /// Native truth (Build.BRAND / Build.MANUFACTURER) — main isolate only.
  /// Fails open to false (never blocks normal paths on a probe failure).
  static Future<bool> refreshFromNative() async {
    if (!Platform.isAndroid) return false;
    try {
      final isAggressive =
          await _kChannel.invokeMethod<bool>('isAggressiveOem') ?? false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, isAggressive);
      return isAggressive;
    } catch (e) {
      debugPrint('[AGGRESSIVE_OEM] native probe failed: $e');
      return false;
    }
  }

  /// Cached value, readable from ANY isolate (headless workers included).
  /// The cache is written by [refreshFromNative] on app start.
  static Future<bool> isAggressive() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKey) ?? false;
  }

  /// True once the user confirmed (on an aggressive-OEM device) that the
  /// battery restrictions / autostart exemptions are disabled.  Mandatory
  /// gate: MIUI battery state can't be read programmatically, so the user
  /// verifies by hand — honest limitation, documented in the settings UI.
  static Future<bool> restrictionsConfirmed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(restrictionsConfirmedKey) ?? false;
  }

  static Future<void> setRestrictionsConfirmed(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(restrictionsConfirmedKey, value);
  }

  /// Open the MIUI Auto-start management page (falls back to app details).
  static Future<void> openMiuiAutoStart() async {
    if (!Platform.isAndroid) return;
    try {
      await _kChannel.invokeMethod('openMiuiAutoStart');
    } catch (e) {
      debugPrint('[AGGRESSIVE_OEM] openMiuiAutoStart failed: $e');
    }
  }

  /// Open the MIUI per-app Battery saver page (falls back to app details).
  static Future<void> openMiuiBatterySaver() async {
    if (!Platform.isAndroid) return;
    try {
      await _kChannel.invokeMethod('openMiuiBatterySaver');
    } catch (e) {
      debugPrint('[AGGRESSIVE_OEM] openMiuiBatterySaver failed: $e');
    }
  }

  /// Request the standard "ignore battery optimizations" exemption dialog.
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;
    try {
      await _kChannel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('[AGGRESSIVE_OEM] battery-optimization request failed: $e');
    }
  }
}
