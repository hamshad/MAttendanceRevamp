import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'dart:io';

import '../../punch/services/geofence_monitor.dart';
import '../../../core/utils/aggressive_oem.dart';

// ── Provider ──────────────────────────────────────────────────────────────────

/// Reactive toggle — backed by Hive via [GeofenceMonitorService.isEnabled].
/// Changes here are listened to in MainShell to start/stop the service.
final geofenceEnabledProvider = StateProvider<bool>(
  (ref) => GeofenceMonitor.isEnabled,
);

// ── Mandatory MIUI battery-restrictions gate ──────────────────────────────────
//
// Shared by the geofence settings toggle AND the home-screen toggle
// (main_shell) — both enable paths must enforce it.  MIUI-family devices
// kill background work (WorkManager, alarms, the keep-alive FGS) unless
// the user disables Auto-start + battery restrictions.  MIUI's per-app
// battery state is NOT programmatically readable, so the flow opens each
// MIUI page and the user confirms by hand — an honest, user-verified
// gate (documented in the dialog).
Future<bool> ensureMiRestrictionsOff(BuildContext context) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Xiaomi Battery Restrictions — Required'),
          content: const SingleChildScrollView(
            child: Text(
              'Xiaomi (MIUI) kills background work like auto-punch unless '
              'the app is exempted. Without this, punches will be missed '
              'or delayed.\n\n'
              'Please do all three, then come back:\n\n'
              '1. Tap "Open Auto-start" → enable MAttendance.\n'
              '2. Tap "Battery Saver" → choose "No restrictions".\n'
              '3. Tap "Battery Optimization" → allow.\n\n'
              'We can\u2019t read MIUI\u2019s per-app settings — this gate '
              'is your confirmation.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => AggressiveOem.openMiuiAutoStart(),
              child: const Text('Open Auto-start'),
            ),
            TextButton(
              onPressed: () => AggressiveOem.openMiuiBatterySaver(),
              child: const Text('Battery Saver'),
            ),
            TextButton(
              onPressed: () =>
                  AggressiveOem.requestIgnoreBatteryOptimizations(),
              child: const Text('Battery Optimization'),
            ),
            FilledButton(
              onPressed: () async {
                await AggressiveOem.setRestrictionsConfirmed(true);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Done — restrictions are off'),
            ),
          ],
        ),
      ) ??
      false;
}

// ── Screen ────────────────────────────────────────────────────────────────────

class GeofenceSettingsScreen extends ConsumerStatefulWidget {
  const GeofenceSettingsScreen({super.key});

  @override
  ConsumerState<GeofenceSettingsScreen> createState() =>
      _GeofenceSettingsScreenState();
}

class _GeofenceSettingsScreenState
    extends ConsumerState<GeofenceSettingsScreen>
    with WidgetsBindingObserver {
  LocationPermission _permission = LocationPermission.denied;
  bool _locationServiceEnabled = false;
  bool _isAggressiveOem = false;
  bool _miRestrictionsConfirmed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissionStatus();
    _refreshOemState();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permission when the user returns from device settings.
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatus();
      _refreshOemState();
    }
  }

  Future<void> _refreshOemState() async {
    final aggressive = await AggressiveOem.isAggressive();
    final confirmed = await AggressiveOem.restrictionsConfirmed();
    if (mounted && (aggressive != _isAggressiveOem ||
        confirmed != _miRestrictionsConfirmed)) {
      setState(() {
        _isAggressiveOem = aggressive;
        _miRestrictionsConfirmed = confirmed;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refreshPermissionStatus() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    final perm = await Geolocator.checkPermission();
    if (mounted) {
      setState(() {
        _locationServiceEnabled = enabled;
        _permission = perm;
      });
    }
  }

  Future<void> _requestAlwaysPermission() async {
    // 1. Request foreground permission first (While in use)
    var status = await ph.Permission.location.status;
    if (status.isDenied) {
      status = await ph.Permission.location.request();
    }

    if (status.isPermanentlyDenied) {
      await ph.openAppSettings();
      return;
    }

    if (!status.isGranted && !status.isLimited) {
      _showSnack('Location permission is required.');
      return;
    }

    // 2. Request background permission (Always)
    if (Platform.isAndroid) {
      var bgStatus = await ph.Permission.locationAlways.status;
      if (bgStatus.isGranted) {
        await _refreshPermissionStatus();
        return;
      }

      // Show rationale before sending to settings (Requirement for Android 11+)
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Background Location Required'),
          content: const Text(
            'To automatically punch you in/out when the app is closed, MAttendance needs '
            'permission to access your location "All the time".\n\n'
            'On the next screen:\n'
            '1. Tap "Permissions"\n'
            '2. Tap "Location"\n'
            '3. Select "Allow all the time"',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Go to Settings'),
            ),
          ],
        ),
      );

      if (proceed == true) {
        // This will open the specific location permission page on Android 11+
        // or the app settings on older versions.
        await ph.Permission.locationAlways.request();
      }
    } else {
      // iOS handling
      await ph.Permission.locationAlways.request();
    }
    
    await _refreshPermissionStatus();
  }

  Future<void> _requestNotificationPermission() async {
    // Android 13+: the OS requests notification permission on first notification.
    // iOS: permission is configured via DarwinInitializationSettings in
    // initLocalNotifications() (requestAlertPermission etc. set to true there).
    // No explicit call needed here.
  }

  Future<void> _onToggle(bool value) async {
    if (value) {
      // Ensure permission before enabling
      if (!_locationServiceEnabled) {
        _showSnack('Enable location services on your device first.');
        return;
      }
      if (_permission == LocationPermission.denied ||
          _permission == LocationPermission.deniedForever) {
        await _requestAlwaysPermission();
        await _refreshPermissionStatus();
        if (_permission == LocationPermission.denied ||
            _permission == LocationPermission.deniedForever) {
          _showSnack('Location permission required for auto-punch.');
          return;
        }
      }
      await _requestNotificationPermission();

      // MANDATORY gate (user decision 2026-08-17): MIUI-family devices kill
      // background work (WorkManager, alarms, the keep-alive FGS) unless
      // the user disables Auto-start + battery restrictions.  Auto-punch
      // cannot be enabled until the user confirms they're off.  MIUI's
      // per-app battery state is NOT programmatically readable, so the
      // user verifies by hand — the flow opens each MIUI page.
      if (await AggressiveOem.isAggressive() &&
          !(await AggressiveOem.restrictionsConfirmed())) {
        final confirmed = await ensureMiRestrictionsOff(context);
        if (!confirmed) {
          _showSnack('Xiaomi battery restrictions must be off for auto-punch.');
          return;
        }
      }
    }

    await GeofenceMonitor.setEnabled(value);
    ref.read(geofenceEnabledProvider.notifier).state = value;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = ref.watch(geofenceEnabledProvider);

    final permissionOk = _permission == LocationPermission.always ||
        _permission == LocationPermission.whileInUse;

    return Scaffold(
      appBar: AppBar(title: const Text('Geofence Auto-Punch')),
      body: ListView(
        children: [
          // ── Main toggle ───────────────────────────────────────────────────
          SwitchListTile(
            title: const Text('Enable Auto-Punch'),
            subtitle: Text(
              enabled
                  ? 'Automatically records your punch when you enter or exit an office zone.'
                  : 'Off — punch manually from the home screen.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
            value: enabled,
            onChanged: _onToggle,
            secondary: Icon(
              Icons.radar,
              color: enabled
                  ? theme.colorScheme.primary
                  : Colors.grey.shade400,
            ),
          ),

          const Divider(height: 1),

          // ── Battery warning ───────────────────────────────────────────────
          if (enabled)
            _WarningTile(
              icon: Icons.battery_alert_outlined,
              color: Colors.orange.shade700,
              title: 'Battery Impact',
              body: 'Continuous location monitoring increases battery usage. '
                  'Ensure Battery Optimization is disabled for MAttendance in '
                  'device settings for reliable background tracking.',
            ),

          // ── OEM auto-start warning ─────────────────────────────────────────
          // MI-family only (user decision 2026-08-17): Samsung / Nothing /
          // OnePlus are field-proven to work without restrictions — no gate,
          // no tile.  For MI users this doubles as the status + re-run entry
          // for the mandatory battery-restrictions flow.
          if (enabled && _isAggressiveOem)
            _WarningTile(
              icon: Icons.settings_power_outlined,
              color: _miRestrictionsConfirmed
                  ? Colors.green.shade700
                  : Colors.red.shade600,
              title: _miRestrictionsConfirmed
                  ? 'Xiaomi restrictions — off (confirmed)'
                  : 'Xiaomi battery restrictions — REQUIRED',
              body: _miRestrictionsConfirmed
                  ? 'Auto-start, battery saver and battery optimization are '
                      'confirmed off. Tap to re-open the setup flow.'
                  : 'Auto-punch cannot run reliably until Auto-start and '
                      'battery restrictions are disabled for MAttendance. '
                      'Tap to fix now.',
              onTap: _miRestrictionsConfirmed
                  ? null
                  : () async {
                      await ensureMiRestrictionsOff(context);
                      await _refreshOemState();
                    },
            ),

          // ── Permission status ─────────────────────────────────────────────
          _StatusTile(
            title: 'Location Services',
            ok: _locationServiceEnabled,
            okLabel: 'Enabled',
            failLabel: 'Disabled — turn on in device settings',
          ),
          _StatusTile(
            title: 'Location Permission',
            ok: permissionOk,
            okLabel: _permission == LocationPermission.always
                ? 'Always (recommended)'
                : 'While In Use — tap to grant Always',
            failLabel: 'Denied — tap to open settings',
            onTap: permissionOk ? null : _requestAlwaysPermission,
          ),

          const Divider(height: 1),

          // ── Info tiles ────────────────────────────────────────────────────
          const _InfoTile(
            icon: Icons.login,
            title: 'Enter zone → Punch In',
            body: 'Entering an office geofence automatically records a Punch In.',
          ),
          const _InfoTile(
            icon: Icons.logout,
            title: 'Exit zone → Punch Out',
            body: 'Leaving an office geofence automatically records a Punch Out.',
          ),
          const _InfoTile(
            icon: Icons.notifications_outlined,
            title: 'Notifications',
            body: 'A notification is shown each time an auto-punch is recorded.',
          ),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _WarningTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final VoidCallback? onTap;

  const _WarningTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(60)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: color,
                          fontSize: 13)),
                  const SizedBox(height: 3),
                  Text(body,
                      style: TextStyle(color: color, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusTile extends StatelessWidget {
  final String title;
  final bool ok;
  final String okLabel;
  final String failLabel;
  final VoidCallback? onTap;

  const _StatusTile({
    required this.title,
    required this.ok,
    required this.okLabel,
    required this.failLabel,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        ok ? okLabel : failLabel,
        style: TextStyle(
          fontSize: 12,
          color: ok ? Colors.green.shade700 : Colors.red.shade600,
        ),
      ),
      leading: Icon(
        ok ? Icons.check_circle_outline : Icons.cancel_outlined,
        color: ok ? Colors.green.shade600 : Colors.red.shade500,
        size: 22,
      ),
      trailing: (!ok && onTap != null)
          ? TextButton(onPressed: onTap, child: const Text('Fix'))
          : null,
      onTap: (!ok && onTap != null) ? onTap : null,
    );
  }
}

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _InfoTile(
      {required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, size: 20, color: Colors.grey.shade500),
      title: Text(title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      subtitle: Text(body,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
    );
  }
}
