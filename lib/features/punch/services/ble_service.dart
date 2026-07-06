import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// ── Model ────────────────────────────────────────────────────────────────────

/// A BLE beacon discovered during a scan.
class DiscoveredBeacon {
  final String deviceId;    // MAC (Android) or internal UUID (iOS)
  final String? deviceName;
  final String uuid;        // iBeacon proximity UUID or service UUID
  final int? major;
  final int? minor;
  final int rssi;

  const DiscoveredBeacon({
    required this.deviceId,
    this.deviceName,
    required this.uuid,
    this.major,
    this.minor,
    required this.rssi,
  });

  String get displayName =>
      (deviceName?.isNotEmpty ?? false) ? deviceName! : 'Unknown Beacon';

  String get signalLabel {
    if (rssi >= -70) return 'Strong';
    if (rssi >= -85) return 'Medium';
    return 'Weak';
  }
}

enum BLEReadiness { ready, unsupported, off }

// ── Service ──────────────────────────────────────────────────────────────────

/// BLE beacon scanner wrapping flutter_blue_plus.
///
/// Platform setup required:
///   Android — AndroidManifest.xml:
///     <uses-permission android:name="android.permission.BLUETOOTH_SCAN"
///         android:usesPermissionFlags="neverForLocation" />
///     <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
///     <!-- Android < 12 -->
///     <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
///
///   iOS — Info.plist:
///     NSBluetoothAlwaysUsageDescription
class BLEService {
  static const Duration _scanDuration = Duration(seconds: 5);

  /// Check whether BLE hardware is available and turned on.
  Future<BLEReadiness> checkReadiness() async {
    final supported = await FlutterBluePlus.isSupported;
    if (!supported) return BLEReadiness.unsupported;

    // Wait briefly for a stable adapter state (handles cold start).
    BluetoothAdapterState state;
    try {
      state = await FlutterBluePlus.adapterState
          .firstWhere((s) =>
              s == BluetoothAdapterState.on ||
              s == BluetoothAdapterState.off ||
              s == BluetoothAdapterState.unavailable)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      state = BluetoothAdapterState.off;
    }

    return state == BluetoothAdapterState.on
        ? BLEReadiness.ready
        : BLEReadiness.off;
  }

  /// Scan for [_scanDuration] and return all discovered beacons, strongest first.
  Future<List<DiscoveredBeacon>> scan() async {
    final beacons = <String, DiscoveredBeacon>{}; // keyed by deviceId
    StreamSubscription<List<ScanResult>>? resultSub;
    StreamSubscription<bool>? scanStateSub;
    final completer = Completer<void>();

    try {
      resultSub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final beacon = _parseBeacon(r);
          if (beacon != null) {
            beacons[beacon.deviceId] = beacon; // overwrite keeps freshest RSSI
          }
        }
      });

      // Watch isScanning: wait for scan to start, then for it to stop.
      bool started = false;
      scanStateSub = FlutterBluePlus.isScanning.listen((scanning) {
        if (scanning) {
          started = true;
        } else if (started && !completer.isCompleted) {
          completer.complete();
        }
      });

      await FlutterBluePlus.startScan(timeout: _scanDuration);

      await completer.future.timeout(
        _scanDuration + const Duration(seconds: 3),
        onTimeout: () {/* proceed with what we have */},
      );
    } catch (e) {
      debugPrint('[BLEService] scan error: $e');
    } finally {
      await scanStateSub?.cancel();
      await resultSub?.cancel();
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
    }

    return beacons.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
  }

  /// Stop any ongoing scan (safe to call when not scanning).
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  // ── Beacon parsing ───────────────────────────────────────────────────────────

  DiscoveredBeacon? _parseBeacon(ScanResult result) {
    final deviceId = result.device.remoteId.str;
    final name = result.device.platformName.isNotEmpty
        ? result.device.platformName
        : null;

    // iBeacon: Apple manufacturer data (company ID 0x004C = 76)
    // Format: [0x02, 0x15, <16-byte UUID>, <2-byte major>, <2-byte minor>, <TX power>]
    final apple = result.advertisementData.manufacturerData[0x004C];
    if (apple != null &&
        apple.length >= 23 &&
        apple[0] == 0x02 &&
        apple[1] == 0x15) {
      return DiscoveredBeacon(
        deviceId: deviceId,
        deviceName: name,
        uuid: _bytesToUuid(apple.sublist(2, 18)).toUpperCase(),
        major: (apple[18] << 8) | apple[19],
        minor: (apple[20] << 8) | apple[21],
        rssi: result.rssi,
      );
    }

    // Eddystone / generic: fall back to first service UUID
    final serviceUuids = result.advertisementData.serviceUuids;
    if (serviceUuids.isNotEmpty) {
      return DiscoveredBeacon(
        deviceId: deviceId,
        deviceName: name,
        uuid: serviceUuids.first.toString().toUpperCase(),
        rssi: result.rssi,
      );
    }

    return null; // not a recognisable beacon
  }

  /// Convert 16 raw bytes to standard UUID string (8-4-4-4-12).
  String _bytesToUuid(List<int> bytes) {
    final hex =
        bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}
