import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ble_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../core/theme/app_colors.dart';

// ── State machine ─────────────────────────────────────────────────────────────

enum _ScanState {
  scanning,
  found,
  notFound,
  btOff,
  unsupported,
  submitting,
  error,
}

// ── Screen ────────────────────────────────────────────────────────────────────

class BleScanScreen extends ConsumerStatefulWidget {
  final String direction;

  const BleScanScreen({super.key, required this.direction});

  @override
  ConsumerState<BleScanScreen> createState() => _BleScanScreenState();
}

class _BleScanScreenState extends ConsumerState<BleScanScreen>
    with SingleTickerProviderStateMixin {
  late final BLEService _bleService;
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  _ScanState _state = _ScanState.scanning;
  List<DiscoveredBeacon> _beacons = [];
  DiscoveredBeacon? _selectedBeacon;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _bleService = BLEService();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startScan();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _bleService.stopScan(); // fire-and-forget: stop scan if screen is closed
    super.dispose();
  }

  Future<void> _startScan() async {
    if (!mounted) return;
    setState(() {
      _state = _ScanState.scanning;
      _beacons = [];
      _selectedBeacon = null;
      _errorMessage = null;
    });

    final readiness = await _bleService.checkReadiness();
    if (!mounted) return;

    if (readiness == BLEReadiness.unsupported) {
      setState(() => _state = _ScanState.unsupported);
      return;
    }
    if (readiness == BLEReadiness.off) {
      setState(() => _state = _ScanState.btOff);
      return;
    }

    try {
      final beacons = await _bleService.scan();
      if (!mounted) return;

      if (beacons.isEmpty) {
        setState(() => _state = _ScanState.notFound);
      } else {
        setState(() {
          _state = _ScanState.found;
          _beacons = beacons;
          _selectedBeacon = beacons.first; // auto-select strongest signal
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = _ScanState.error;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _submitPunch() async {
    final beacon = _selectedBeacon;
    if (beacon == null) return;

    setState(() => _state = _ScanState.submitting);

    final result = await ref.read(punchProvider.notifier).punch(
      'Bluetooth',
      extras: {
        'beaconUUID': beacon.uuid,
        'beaconMajor': beacon.major,
        'beaconMinor': beacon.minor,
        'direction': widget.direction,
      },
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            result.message ?? (result.success ? 'Punch recorded!' : 'Punch failed')),
        backgroundColor:
            result.success ? AppColors.success : AppColors.error,
      ),
    );

    if (result.success) {
      Navigator.pop(context);
    } else {
      setState(() {
        _state = _ScanState.found;
        _errorMessage = result.message;
      });
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isScanning = _state == _ScanState.scanning;

    return Scaffold(
      appBar: AppBar(
        title: Text('Bluetooth ${_dirLabel(widget.direction)}'),
        leading: const CloseButton(),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),

              // Icon
              Center(
                child: ScaleTransition(
                  scale: isScanning
                      ? _pulseAnim
                      : const AlwaysStoppedAnimation(1.0),
                  child: Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _iconColor(theme).withAlpha(25),
                    ),
                    child: _state == _ScanState.submitting
                        ? Padding(
                            padding: const EdgeInsets.all(28),
                            child: CircularProgressIndicator(
                              color: theme.colorScheme.primary,
                              strokeWidth: 3,
                            ),
                          )
                        : Icon(_stateIcon, size: 54, color: _iconColor(theme)),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              Text(
                _stateTitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _stateSubtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: AppColors.textSecondary),
              ),

              const SizedBox(height: 24),

              // Beacon list
              if (_state == _ScanState.found || _state == _ScanState.submitting)
                _BeaconList(
                  beacons: _beacons,
                  selectedId: _selectedBeacon?.deviceId,
                  onSelect: _state == _ScanState.submitting
                      ? null
                      : (b) => setState(() => _selectedBeacon = b),
                ),

              // Server-rejection message
              if (_errorMessage != null &&
                  (_state == _ScanState.found || _state == _ScanState.error))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: theme.colorScheme.error, fontSize: 13),
                  ),
                ),

              const Spacer(),

              ..._buildButtons(theme),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildButtons(ThemeData theme) {
    switch (_state) {
      case _ScanState.scanning:
        return [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ];

      case _ScanState.found:
        return [
          ElevatedButton.icon(
            onPressed: _selectedBeacon != null ? _submitPunch : null,
            icon: const Icon(Icons.bluetooth),
            label: Text(_punchLabel(widget.direction)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _dirColor(widget.direction),
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 48),
            ),
          ),
          const SizedBox(height: 10),
          TextButton.icon(
            onPressed: _startScan,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Scan Again'),
          ),
        ];

      case _ScanState.notFound:
      case _ScanState.error:
        return [
          OutlinedButton.icon(
            onPressed: _startScan,
            icon: const Icon(Icons.refresh),
            label: const Text('Scan Again'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48)),
          ),
        ];

      case _ScanState.btOff:
        return [
          OutlinedButton.icon(
            onPressed: _startScan,
            icon: const Icon(Icons.refresh),
            label: const Text('Try Again'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48)),
          ),
        ];

      default:
        return [];
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  IconData get _stateIcon => switch (_state) {
        _ScanState.scanning => Icons.bluetooth_searching,
        _ScanState.found => Icons.bluetooth_connected,
        _ScanState.submitting => Icons.bluetooth_connected,
        _ScanState.notFound => Icons.bluetooth_disabled,
        _ScanState.btOff => Icons.bluetooth_disabled,
        _ScanState.unsupported => Icons.bluetooth_disabled,
        _ScanState.error => Icons.warning_amber_rounded,
      };

  String get _stateTitle => switch (_state) {
        _ScanState.scanning => 'Scanning...',
        _ScanState.found =>
          '${_beacons.length} Beacon${_beacons.length == 1 ? '' : 's'} Found',
        _ScanState.submitting => 'Recording Punch...',
        _ScanState.notFound => 'No Beacons Found',
        _ScanState.btOff => 'Bluetooth is Off',
        _ScanState.unsupported => 'Not Supported',
        _ScanState.error => 'Scan Failed',
      };

  String get _stateSubtitle => switch (_state) {
        _ScanState.scanning => 'Looking for registered beacons nearby...',
        _ScanState.found => _beacons.length == 1
            ? 'Confirm to punch ${_dirLabel(widget.direction).toLowerCase()}'
            : 'Select the beacon to use',
        _ScanState.submitting => 'Verifying beacon with server...',
        _ScanState.notFound =>
          'No registered beacons detected. Make sure you are near an office beacon.',
        _ScanState.btOff =>
          'Enable Bluetooth and try again.',
        _ScanState.unsupported =>
          'Bluetooth is not available on this device.',
        _ScanState.error =>
          _errorMessage ?? 'An error occurred during scanning.',
      };

  Color _iconColor(ThemeData theme) => switch (_state) {
        _ScanState.notFound ||
        _ScanState.btOff ||
        _ScanState.unsupported =>
          AppColors.textSecondary,
        _ScanState.error => theme.colorScheme.error,
        _ScanState.found || _ScanState.submitting => AppColors.success,
        _ => theme.colorScheme.primary,
      };

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        'BreakStart' => 'Break Start',
        'BreakEnd' => 'Break End',
        _ => dir,
      };

  String _punchLabel(String dir) => switch (dir) {
        'In' => 'Punch In via Bluetooth',
        'Out' => 'Punch Out via Bluetooth',
        _ => 'Punch via Bluetooth',
      };

  Color _dirColor(String dir) => switch (dir) {
        'In' => AppColors.success,
        'Out' => AppColors.error,
        _ => AppColors.info,
      };
}

// ── Beacon list ───────────────────────────────────────────────────────────────

class _BeaconList extends StatelessWidget {
  final List<DiscoveredBeacon> beacons;
  final String? selectedId;
  final ValueChanged<DiscoveredBeacon>? onSelect;

  const _BeaconList({
    required this.beacons,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ...beacons.map(
          (b) => _BeaconTile(
            beacon: b,
            isSelected: selectedId == b.deviceId,
            onTap: onSelect != null ? () => onSelect!(b) : null,
          ),
        ),
        if (beacons.length > 1) ...[
          const SizedBox(height: 4),
          Text(
            'Tap a beacon to select it',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

// ── Beacon tile ───────────────────────────────────────────────────────────────

class _BeaconTile extends StatelessWidget {
  final DiscoveredBeacon beacon;
  final bool isSelected;
  final VoidCallback? onTap;

  const _BeaconTile({
    required this.beacon,
    required this.isSelected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final signalColor = beacon.rssi >= -70
        ? AppColors.success
        : beacon.rssi >= -85
            ? AppColors.warning
            : AppColors.error;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isSelected
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(Icons.bluetooth, color: theme.colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      beacon.displayName,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      beacon.uuid.length > 22
                          ? '${beacon.uuid.substring(0, 22)}…'
                          : beacon.uuid,
                      style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                          fontFamily: 'monospace'),
                    ),
                    if (beacon.major != null) ...[
                      const SizedBox(height: 1),
                      Text(
                        'Major: ${beacon.major}  ·  Minor: ${beacon.minor ?? '—'}',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: signalColor.withAlpha(25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      beacon.signalLabel,
                      style: TextStyle(
                        color: signalColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${beacon.rssi} dBm',
                    style:
                        TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
              if (isSelected) ...[
                const SizedBox(width: 8),
                Icon(Icons.check_circle,
                    color: theme.colorScheme.primary, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
