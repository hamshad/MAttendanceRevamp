import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/wifi_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_logger.dart';


// ── WiFi detection provider ───────────────────────────────────────────────────

final _wifiInfoProvider = FutureProvider.autoDispose<WifiInfo>((ref) async {
  AppLogger.d('WIFI_PUNCH: Requesting current WiFi info');
  final wifi = await WifiService().getCurrentWifi();
  AppLogger.i('WIFI_PUNCH: Connected to SSID: ${wifi.ssid}, BSSID: ${wifi.bssid}');
  return wifi;
});


// ── Screen ────────────────────────────────────────────────────────────────────

class WiFiPunchScreen extends ConsumerWidget {
  final String direction;

  const WiFiPunchScreen({super.key, required this.direction});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wifiAsync = ref.watch(_wifiInfoProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('WiFi Punch ${_dirLabel(direction)}'),
        leading: const CloseButton(),
      ),
      body: wifiAsync.when(
        loading: () {
          AppLogger.d('WIFI_PUNCH: Detecting network...');
          return const _DetectingView();
        },
        error: (e, _) {
          AppLogger.e('WIFI_PUNCH: Network detection failed', e);
          return _ErrorView(
            message: _errorMessage(e),
            onRetry: () {
              AppLogger.d('WIFI_PUNCH: Retrying network detection');
              ref.invalidate(_wifiInfoProvider);
            },
          );
        },
        data: (wifi) => _ConnectedView(wifi: wifi, direction: direction),
      ),

    );
  }

  String _errorMessage(Object e) {
    if (e is WifiNotConnectedException) return e.message;
    if (e is WifiPermissionException) return e.message;
    return 'Could not read WiFi information. Please try again.';
  }

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        'BreakStart' => 'Break Start',
        'BreakEnd' => 'Break End',
        _ => dir,
      };
}

// ── Connected view ────────────────────────────────────────────────────────────

class _ConnectedView extends ConsumerStatefulWidget {
  final WifiInfo wifi;
  final String direction;

  const _ConnectedView({required this.wifi, required this.direction});

  @override
  ConsumerState<_ConnectedView> createState() => _ConnectedViewState();
}

class _ConnectedViewState extends ConsumerState<_ConnectedView> {
  bool _isPunching = false;

  @override
  void initState() {
    super.initState();
    AppLogger.d('WIFI_PUNCH: Connected view initialized for ${widget.direction}');
    AppLogger.activity('Opened WiFi Punch Screen', data: {
      'direction': widget.direction,
      'ssid': widget.wifi.ssid,
    });
  }


  Future<void> _punch() async {
    AppLogger.activity('User initiated WiFi Punch ${widget.direction}', data: {
      'ssid': widget.wifi.ssid,
      'bssid': widget.wifi.bssid,
      'direction': widget.direction,
    });
    setState(() => _isPunching = true);

    final result = await ref.read(punchProvider.notifier).punch(
      'WiFi',
      extras: {
        'wifiSSID': widget.wifi.ssid,
        'wifiMAC': widget.wifi.bssid,
        'direction': widget.direction,
      },
    );

    if (!mounted) return;
    setState(() => _isPunching = false);

    if (result.success) {
      AppLogger.i('WIFI_PUNCH: Success - ${result.message}');
      AppLogger.activity('WiFi Punch Success', data: {'direction': widget.direction, 'ssid': widget.wifi.ssid});
    } else {
      AppLogger.w('WIFI_PUNCH: Failed - ${result.message}');
      AppLogger.activity('WiFi Punch Failed', data: {
        'direction': widget.direction,
        'error': result.message,
        'ssid': widget.wifi.ssid,
      });
    }


    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message ?? (result.success ? 'Punch recorded!' : 'Punch failed')),
        backgroundColor: result.success ? AppColors.success : AppColors.error,
      ),
    );

    if (result.success) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // WiFi icon
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.wifi, size: 48, color: AppColors.info),
          ),
          const SizedBox(height: 24),

          Text(
            'Connected to',
            style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),

          // SSID
          Text(
            widget.wifi.ssid,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),

          // BSSID (MAC)
          Text(
            widget.wifi.bssid,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 32),

          // Info card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.info.withAlpha(50)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18, color: AppColors.info),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The server will verify this network against registered office routers.',
                    style: theme.textTheme.bodySmall?.copyWith(color: AppColors.info),
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),

          // Punch button
          ElevatedButton.icon(
            onPressed: _isPunching ? null : _punch,
            icon: _isPunching
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.wifi),
            label: Text(
              _isPunching ? 'Recording...' : _dirLabel(widget.direction),
              style: const TextStyle(fontSize: 16),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _dirColor(widget.direction),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In via WiFi',
        'Out' => 'Punch Out via WiFi',
        _ => 'Punch via WiFi',
      };

  Color _dirColor(String dir) => switch (dir) {
        'In' => AppColors.success,
        'Out' => AppColors.error,
        _ => AppColors.info,
      };
}

// ── Detecting / Error ─────────────────────────────────────────────────────────

class _DetectingView extends StatelessWidget {
  const _DetectingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Detecting WiFi network...'),
          SizedBox(height: 6),
          Text(
            'Ensure you are connected to office WiFi',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.wifi_off, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}
