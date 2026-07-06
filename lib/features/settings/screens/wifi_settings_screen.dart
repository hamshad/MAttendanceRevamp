import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../punch/services/wifi_auto_punch_service.dart';
import '../../../core/theme/app_colors.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

final wifiAutoEnabledProvider = StateProvider<bool>(
  (ref) => WifiAutoPunchService.isEnabled,
);

// ── Screen ────────────────────────────────────────────────────────────────────

class WifiSettingsScreen extends ConsumerStatefulWidget {
  const WifiSettingsScreen({super.key});

  @override
  ConsumerState<WifiSettingsScreen> createState() => _WifiSettingsScreenState();
}

class _WifiSettingsScreenState extends ConsumerState<WifiSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = ref.watch(wifiAutoEnabledProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('WiFi Auto-Punch')),
      body: ListView(
        children: [
          // ── Toggle ─────────────────────────────────────────────────────────
          SwitchListTile(
            title: const Text('Enable WiFi Auto-Punch'),
            subtitle: const Text(
              'Automatically records your attendance when you connect to office WiFi.',
              style: TextStyle(fontSize: 13),
            ),
            value: enabled,
            onChanged: (val) async {
              await WifiAutoPunchService.setEnabled(val);
              ref.read(wifiAutoEnabledProvider.notifier).state = val;
            },
            secondary: Icon(
              Icons.wifi_sharp,
              color: enabled ? AppColors.primary : AppColors.gray,
            ),
          ),

          const Divider(height: 1),

          // ── Config Info ───────────────────────────────────────────────────
          const Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OFFICE WIFI MANAGEMENT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textSecondary,
                    letterSpacing: 1.1,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Authorized WiFi networks (SSID and MAC) are managed by your organization in the backend. The app will automatically sync these settings whenever you open it.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ── Info ──────────────────────────────────────────────────────────
          const _InfoTile(
            icon: Icons.sync_lock_outlined,
            title: 'Backend Verification',
            body: 'Attendance is marked as Present only if you are connected to a certified office router. Unrecognized networks will result in an Absent status.',
          ),
          const _InfoTile(
            icon: Icons.battery_charging_full_outlined,
            title: 'Battery Efficient',
            body: 'WiFi monitoring uses significantly less battery compared to continuous GPS tracking.',
          ),
          const _InfoTile(
            icon: Icons.notifications_active_outlined,
            title: 'Instant Feedback',
            body: 'You will receive a local notification whenever an auto-punch is recorded.',
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _InfoTile({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 22, color: AppColors.gray),
      title: Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
      subtitle: Text(body, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    );
  }
}
