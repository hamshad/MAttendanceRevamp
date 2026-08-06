import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/location_precision.dart';
import '../../../core/utils/permission_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';

class PermissionBlockingScreen extends ConsumerStatefulWidget {
  final Widget child;

  const PermissionBlockingScreen({super.key, required this.child});

  @override
  ConsumerState<PermissionBlockingScreen> createState() => _PermissionBlockingScreenState();
}

class _PermissionBlockingScreenState extends ConsumerState<PermissionBlockingScreen> {
  bool _hasPermission = false;
  bool _hasPrecision = false;
  bool _isRequesting = false;
  bool? _needsBackground;
  bool _checkTriggered = false;

  Future<void> _checkPermission() async {
    final needsBg = _needsBackground!;
    setState(() => _isRequesting = true);

    final hasPerm = needsBg
        ? await PermissionService.instance.hasBackgroundLocation()
        : await PermissionService.instance.hasForegroundLocation();

    // Precise (fine) location is mandatory — approximate breaks GPS punch,
    // geofence, WiFi alignment and client-site verification.
    final hasPrecision = hasPerm && await LocationPrecision.isPreciseGranted();

    if (mounted) {
      setState(() {
        _hasPermission = hasPerm;
        _hasPrecision = hasPrecision;
        _isRequesting = false;
      });
    }
  }

  Future<void> _handleRequest() async {
    final needsBg = _needsBackground!;
    setState(() => _isRequesting = true);

    final success = needsBg
        ? await PermissionService.instance.requestBackgroundLocation()
        : await PermissionService.instance.requestForegroundLocation();

    if (success && mounted) {
      // Re-check precision after granting — some OEM dialogs (Xiaomi MIUI)
      // let the user pick "Approximate" directly, and requestPermission cannot
      // tell the difference.
      final hasPrecision = await LocationPrecision.isPreciseGranted();
      if (mounted) {
        setState(() {
          _hasPermission = true;
          _hasPrecision = hasPrecision;
          _isRequesting = false;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _hasPermission = success;
        _hasPrecision = false;
        _isRequesting = false;
      });
    }
  }

  Future<void> _openSettings() async {
    setState(() => _isRequesting = true);
    await openAppSettings();
    if (mounted) setState(() => _isRequesting = false);
    await _checkPermission();
  }

  @override
  Widget build(BuildContext context) {
    final permsAsync = ref.watch(accessPermissionsProvider);

    final needsBackground = permsAsync.when(
      data: (perms) => perms.allowFieldTracking || perms.allowGeofenceAuto,
      loading: () => null,
      error: (_, _) => false,
    );

    if (needsBackground == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_checkTriggered) {
      _checkTriggered = true;
      _needsBackground = needsBackground;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkPermission();
      });
    }

    if (_hasPermission && _hasPrecision) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final isBg = needsBackground;

    // Location granted but only approximate — cannot be fixed via the runtime
    // request dialog; user must flip "Precise" in app settings.
    final precisionMissing = _hasPermission && !_hasPrecision;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 24),

              Image.asset('assets/images/logo.png', width: 80, height: 80),
              const SizedBox(height: 16),

              Text(
                precisionMissing ? 'Precise Location Required' : 'Location Required',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),

              Text(
                isBg ? 'Background Permissions' : 'Location Permissions',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 48),

              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(
                        precisionMissing ? Icons.gps_not_fixed : Icons.location_on,
                        size: 48,
                        color: AppColors.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        precisionMissing
                            ? 'Approximate location is not enough. It reports your position up to 1 km away, which breaks GPS punch, geofence, WiFi alignment and client-site verification. Set location to "Precise".'
                            : isBg
                                ? 'To enable automatic attendance tracking and office geofencing, this app requires location access set to "Allow all the time".'
                                : 'To enable attendance tracking, this app requires location access.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: AppColors.textPrimary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),

              Column(
                children: [
                  _InstructionRow(
                    number: '1',
                    text: precisionMissing
                        ? 'Tap the button below to open Settings'
                        : 'Tap the button below',
                  ),
                  const SizedBox(height: 16),
                  _InstructionRow(
                    number: '2',
                    text: precisionMissing
                        ? 'Set Location to "Precise" and "Allow all the time"'
                        : isBg ? 'Select "Allow all the time"' : 'Select "Allow while using the app"',
                  ),
                ],
              ),
              const SizedBox(height: 48),

              if (precisionMissing)
                ElevatedButton.icon(
                  onPressed: _isRequesting ? null : _openSettings,
                  icon: _isRequesting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.settings),
                  label: Text(_isRequesting ? 'Opening Settings...' : 'Open Settings'),
                )
              else
                ElevatedButton(
                  onPressed: _isRequesting ? null : _handleRequest,
                  child: _isRequesting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(isBg ? 'Allow All The Time' : 'Allow Location Access'),
                ),
              const SizedBox(height: 16),

              TextButton(
                onPressed: _checkPermission,
                child: const Text('I have enabled it'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructionRow extends StatelessWidget {
  final String number;
  final String text;

  const _InstructionRow({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: AppColors.primarySubtle,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            number,
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
