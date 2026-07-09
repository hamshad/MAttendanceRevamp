import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/wifi_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/app_logger.dart';

final wifiInfoProvider = FutureProvider.autoDispose<WifiInfo>((ref) async {
  return await WifiService().getCurrentWifi();
});

class WiFiVerificationView extends ConsumerWidget {
  const WiFiVerificationView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wifiAsync = ref.watch(wifiInfoProvider);
    final theme = Theme.of(context);

    return wifiAsync.when(
      loading: () => const _DetectingView(),
      error: (e, _) => _ErrorView(
        message: _errorMessage(e),
        onRetry: () => ref.invalidate(wifiInfoProvider),
      ),
      data: (wifi) => _ConnectedView(wifi: wifi),
    );
  }

  String _errorMessage(Object e) {
    if (e is WifiNotConnectedException) return e.message;
    if (e is WifiPermissionException) return e.message;
    return 'Could not read WiFi information.';
  }
}

class _ConnectedView extends StatelessWidget {
  final WifiInfo wifi;
  const _ConnectedView({required this.wifi});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(20),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.wifi, size: 40, color: AppColors.info),
          ),
          const SizedBox(height: 24),
          Text(
            wifi.ssid == 'Unknown Network' ? 'Connected to WiFi' : 'Connected to',
            style: theme.textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Text(
            wifi.ssid,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            wifi.bssid,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textSecondary,
              fontFamily: 'monospace',
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 40),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.info.withAlpha(12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.info.withAlpha(50)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 18, color: AppColors.info),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'The server will verify this network against registered office routers.',
                    style: theme.textTheme.bodySmall?.copyWith(color: AppColors.info),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetectingView extends StatelessWidget {
  const _DetectingView();
  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Detecting WiFi network...'),
      ],
    ),
  );
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.wifi_off, size: 48, color: AppColors.textSecondary),
        const SizedBox(height: 16),
        Text(message, textAlign: TextAlign.center),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
