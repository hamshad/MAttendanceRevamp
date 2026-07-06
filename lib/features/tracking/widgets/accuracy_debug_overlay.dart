import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/config/dev_flags.dart';
import '../../tracking/services/field_tracking_service.dart';
import '../models/location_result.dart';

/// Floating accuracy overlay — visible only when [DevFlags.kDevMode] is true.
/// Shows real-time GPS accuracy, fix count, and pipeline state.
class AccuracyDebugOverlay extends ConsumerStatefulWidget {
  const AccuracyDebugOverlay({super.key});

  @override
  ConsumerState<AccuracyDebugOverlay> createState() => _AccuracyDebugOverlayState();
}

class _AccuracyDebugOverlayState extends ConsumerState<AccuracyDebugOverlay> {
  LocationResult? _lastFix;
  int _fixCount = 0;
  String _trackingState = 'UNKNOWN';
  double? _gfDistM;
  double? _gfRadiusM;
  String? _gfName;

  // WiFi debug state
  bool _wifiEnabled = false;
  String? _wifiBssid;
  String? _wifiMatchedName;
  String? _wifiLastPunchType;

  @override
  void initState() {
    super.initState();
    _listenToDebugStream();
    _listenToWifiDebug();
  }

  void _listenToWifiDebug() {
    FieldTrackingService.wifiDebugStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _wifiEnabled = event['enabled'] as bool? ?? false;
        _wifiBssid = event['bssid'] as String?;
        _wifiMatchedName = event['matchedName'] as String?;
        _wifiLastPunchType = event['lastPunchType'] as String?;
      });
    });
  }

  void _listenToDebugStream() {
    FieldTrackingService.debugStream.listen((event) {
      if (!mounted) return;
      final eventType = event['event'] as String?;
      if (eventType == 'filtered' || eventType == 'raw' || eventType == 'rejected') {
        setState(() {
          _fixCount++;
          _lastFix = event['lat'] != null && event['lng'] != null
              ? LocationResult(
                  latitude: (event['lat'] as num).toDouble(),
                  longitude: (event['lng'] as num).toDouble(),
                  accuracy: (event['accuracy'] as num?)?.toDouble() ?? 0,
                  speed: (event['speed'] as num?)?.toDouble() ?? 0,
                  timestamp: DateTime.now(),
                )
              : null;
          _trackingState = event['state'] as String? ?? 'UNKNOWN';
          _gfDistM = (event['geofenceDistM'] as num?)?.toDouble();
          _gfRadiusM = (event['geofenceRadiusM'] as num?)?.toDouble();
          _gfName = event['geofenceName'] as String?;
        });
      } else if (eventType == 'state_change') {
        setState(() {
          _trackingState = event['reason'] as String? ?? 'STATE_CHANGE';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!DevFlags.kDevMode) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final acc = _lastFix?.accuracy ?? 0;
    final color = _accuracyColor(acc);

    return Positioned(
      right: 12,
      top: 100,
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(230),
        child: Container(
          padding: const EdgeInsets.all(12),
          constraints: const BoxConstraints(minWidth: 220),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.gps_fixed, color: color, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'GPS Debug',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
                ],
              ),
              const Divider(height: 12),
              _row('Accuracy', '${acc.toStringAsFixed(1)}m', color),
              _row('State', _trackingState),
              _row('Fixes', '$_fixCount'),
              if (_lastFix != null) ...[
                _row('Lat', _lastFix!.latitude.toStringAsFixed(6)),
                _row('Lng', _lastFix!.longitude.toStringAsFixed(6)),
                _row('Speed', '${_lastFix!.speed.toStringAsFixed(1)} m/s'),
              ],
              if (_gfDistM != null && _gfRadiusM != null) ...[
                const Divider(height: 12),
                _row('Geofence', _gfName ?? '—'),
                _row('Distance', '${_gfDistM!.toStringAsFixed(1)}m / ${_gfRadiusM!.toStringAsFixed(0)}m',
                    _gfDistM! <= _gfRadiusM! ? Colors.green : Colors.orange),
              ],
              const Divider(height: 12),
              _row('WiFi', _wifiEnabled ? 'ON' : 'OFF',
                  _wifiEnabled ? Colors.green : Colors.red),
              _row('BSSID', _wifiBssid ?? '—'),
              _row('Match', _wifiMatchedName ?? '—',
                  _wifiMatchedName != null ? Colors.green : Colors.orange),
              _row('Last Punch', _wifiLastPunchType ?? '—'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value, [Color? valueColor]) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Text(value, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: valueColor)),
        ],
      ),
    );
  }

  Color _accuracyColor(double acc) {
    if (acc <= 20) return Colors.green;
    if (acc <= 50) return Colors.lightGreen;
    if (acc <= 100) return Colors.orange;
    return Colors.red;
  }
}