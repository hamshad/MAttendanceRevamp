import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/theme/app_colors.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

final geofenceAutoEnabledProvider = StateProvider<bool>((ref) => false);

/// Read current value from SP (used by non-Riverpod code).
Future<bool> isGeofenceAutoEnabled() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool('geofence_auto_enabled') ?? false;
}

Future<void> setGeofenceAutoEnabled(bool value) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('geofence_auto_enabled', value);
}

// ── Screen ────────────────────────────────────────────────────────────────────

class GeofenceSettingsScreen extends ConsumerStatefulWidget {
  const GeofenceSettingsScreen({super.key});

  @override
  ConsumerState<GeofenceSettingsScreen> createState() => _GeofenceSettingsScreenState();
}

class _GeofenceSettingsScreenState extends ConsumerState<GeofenceSettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Sync provider from SharedPreferences
    _syncFromPrefs();
  }

  Future<void> _syncFromPrefs() async {
    final val = await isGeofenceAutoEnabled();
    if (mounted) {
      ref.read(geofenceAutoEnabledProvider.notifier).state = val;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(geofenceAutoEnabledProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Geofence Auto-Punch')),
      body: ListView(
        children: [
          // ── Toggle ─────────────────────────────────────────────────────────
          SwitchListTile(
            title: const Text('Enable Geofence Auto-Punch'),
            subtitle: const Text(
              'Automatically punches you IN/OUT when you enter or leave the office geofence area.',
              style: TextStyle(fontSize: 13),
            ),
            value: enabled,
            onChanged: (val) async {
              await setGeofenceAutoEnabled(val);
              ref.read(geofenceAutoEnabledProvider.notifier).state = val;
            },
            secondary: Icon(
              Icons.near_me_sharp,
              color: enabled ? AppColors.primary : AppColors.gray,
            ),
          ),

          const Divider(height: 1),

          // ── Info ──────────────────────────────────────────────────────────
          const _InfoTile(
            icon: Icons.map_outlined,
            title: 'How It Works',
            body: 'When you enter the office geofence area, the app automatically records an IN punch (GPS method). When you leave, it records an OUT punch.',
          ),
          const _InfoTile(
            icon: Icons.battery_charging_full_outlined,
            title: 'Battery Usage',
            body: 'Geofence monitoring shares the same location stream as field tracking. Minimal additional battery impact.',
          ),
          const _InfoTile(
            icon: Icons.notifications_active_outlined,
            title: 'Notifications',
            body: 'You will receive a local notification whenever an auto-punch is recorded via geofence.',
          ),
          const _InfoTile(
            icon: Icons.info_outline,
            title: 'Location Required',
            body: 'This feature requires "Always" location permission. The app will prompt if permission is not granted.',
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
