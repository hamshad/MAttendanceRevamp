import 'dart:io';

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Detects whether the OS location permission is set to PRECISE (fine
/// granularity) vs APPROXIMATE (coarse).
///
/// Android 12+ (and MIUI 12/13 on Android 10/11) lets users grant "approximate
/// location". The OS then serves coarse network/cell-tower fixes that can be
/// 500m–2km off — silently breaking GPS punch, geofence auto-punch, WiFi
/// alignment and client-site verification, while `checkPermission()` still
/// reports the permission as granted.
///
/// The native side (MainActivity) reports granularity via
/// `LocationManager#getLocationGranularity()` (API 31+) or the
/// `OP_FINE_LOCATION` AppOps mode (API 29+).
class LocationPrecision {
  LocationPrecision._();

  static const _channel =
      MethodChannel('com.mattendance.mattendance_mobile/location_precision');

  /// True when precise (fine) location is granted.
  ///
  /// Non-Android platforms always return true (no approximate concept).
  /// Fail-open on channel errors: a broken channel must not lock users out —
  /// the permission-blocking screen and LocationService are the enforcement
  /// points, and they degrade to previous behavior if this check itself fails.
  static Future<bool> isPreciseGranted() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _channel.invokeMethod<bool>('isPreciseGranted');
      return result ?? true;
    } catch (e) {
      AppLogger.e('LOC_PRECISION: check failed — fail-open', e);
      return true;
    }
  }
}
