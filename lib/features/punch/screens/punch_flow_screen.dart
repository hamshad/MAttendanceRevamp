import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../dashboard/widgets/punch_button.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/attendance.dart';
import '../widgets/gps_verification_view.dart';
import '../widgets/wifi_verification_view.dart';
import '../widgets/selfie_verification_view.dart';
import '../widgets/client_site_verification_view.dart';
import '../widgets/fingerprint_verification_view.dart';
import '../services/camera_service.dart';

class PunchFlowScreen extends ConsumerStatefulWidget {
  const PunchFlowScreen({super.key});

  @override
  ConsumerState<PunchFlowScreen> createState() => _PunchFlowScreenState();
}

class _PunchFlowScreenState extends ConsumerState<PunchFlowScreen> {
  // Store verification data from views
  dynamic _verificationData;
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    final selectedMethod = ref.watch(selectedMethodProvider);
    final statusAsync = ref.watch(attendanceStatusProvider);
    final permissionsAsync = ref.watch(accessPermissionsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Punch Verification'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (status) => Column(
          children: [
            // Top Area: Dynamic Verification View
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _buildVerificationView(selectedMethod),
              ),
            ),

            // Bottom Area: Persistent Controls
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(20),
                    blurRadius: 10,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Method Selector
                  permissionsAsync.maybeWhen(
                    data: (perms) => MethodSelector(permissions: perms),
                    orElse: () => const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 24),

                  // Punch Button
                  PunchButton(
                    status: status,
                    isFlowMode: true,
                    onPunchPressed: () => _handlePunch(selectedMethod, status),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationView(String method) {
    switch (method) {
      case 'GPS':
      case 'GeofenceAuto':
        return const GPSVerificationView();
      case 'ClientSite':
        return ClientSiteVerificationView(
          onDataChanged: (data) => _verificationData = data,
        );
      case 'WiFi':
        return const WiFiVerificationView();
      case 'Selfie':
        return SelfieVerificationView(
          onCaptured: (base64, lat, lng, addr) {
            _verificationData = {
              'selfieBase64': base64,
              'latitude': lat,
              'longitude': lng,
              'address': addr,
            };
          },
          isSubmitting: _isProcessing,
        );
      case 'Fingerprint':
        return FingerprintVerificationView(
          isProcessing: _isProcessing,
          onVerified: (data) {
            _verificationData = data;
            _handlePunch(
              'Fingerprint',
              ref.read(attendanceStatusProvider).value,
            );
          },
        );
      default:
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.touch_app_outlined,
                size: 64,
                color: AppColors.gray,
              ),
              const SizedBox(height: 16),
              Text(
                'Verify via $method',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ready to punch',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        );
    }
  }

  Future<void> _handlePunch(String method, EmployeeStatus? status) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    final direction = _resolveDirection(status);
    final extras = <String, dynamic>{'direction': direction};

    // Gather data based on method
    if (method == 'GPS' || method == 'GeofenceAuto') {
      final loc = ref.read(gpsLocationProvider).valueOrNull;
      if (loc != null) {
        extras['latitude'] = loc.latitude;
        extras['longitude'] = loc.longitude;
      }
    } else if (method == 'WiFi') {
      final wifi = ref.read(wifiInfoProvider).valueOrNull;
      if (wifi != null) {
        extras['wifiSSID'] = wifi.ssid;
        extras['wifiMAC'] = wifi.bssid;
      }
    } else if (method == 'Selfie') {
      if (_verificationData != null) {
        extras.addAll(_verificationData as Map<String, dynamic>);
      }
    } else if (method == 'ClientSite') {
      if (_verificationData != null) {
        final data = _verificationData as Map<String, dynamic>;
        final cameraService = data['cameraService'] as CameraService?;
        if (cameraService != null) {
          try {
            final base64 = await cameraService.captureAndEncode();
            extras['selfieBase64'] = base64;
          } catch (_) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Selfie capture failed'),
                backgroundColor: AppColors.error,
              ),
            );
            setState(() => _isProcessing = false);
            return;
          }
        }
        extras['clientSiteId'] = data['clientSiteId'];
        extras['latitude'] = data['latitude'];
        extras['longitude'] = data['longitude'];
      }
    } else if (method == 'Fingerprint') {
      if (_verificationData != null) {
        final data = _verificationData as Map<String, dynamic>;
        extras['deviceId'] = data['deviceId'];
      }
    }

    final result = await ref
        .read(punchProvider.notifier)
        .punch(method, extras: extras);

    if (!mounted) return;
    setState(() => _isProcessing = false);

    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message ?? 'Punch Success'),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message ?? 'Punch Failed'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  String _resolveDirection(EmployeeStatus? status) {
    if (status?.isOnBreak ?? false) return 'BreakEnd';
    if (status?.isPunchedIn ?? false) return 'Out';
    return 'In';
  }
}
