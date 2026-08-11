import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// OEMs whose ROMs aggressively kill background work (background process
/// spawn, WorkManager, deferred alarms) without user exemptions.
///
/// MIUI/HyperOS is the canonical pain (kills WorkManager tasks and blocks
/// background app starts without Autostart + battery exemption), but the
/// same class of behavior exists on ColorOS/OxygenOS (Oppo/Realme/OnePlus),
/// Funtouch/OriginOS (Vivo) and MagicOS (Honor).  Solving MIUI robustly
/// covers the family.
class AggressiveOem {
  AggressiveOem._();

  static const String _prefKey = 'gf_aggressive_oem';

  static const _kChannel =
      MethodChannel('com.mattendance.mattendance_mobile/geofence_alarm');

  /// Brand strings (lowercased Build.BRAND / Build.MANUFACTURER) that need
  /// the keep-alive treatment.
  static const List<String> aggressiveBrands = [
    'xiaomi',
    'redmi',
    'poco',
    'honor',
    'oppo',
    'realme',
    'oneplus',
    'vivo',
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
}
