import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import '../services/device_info_service.dart';
import '../../../core/theme/app_colors.dart';

enum _FingerprintStatus { idle, authenticating, success, failed }

class FingerprintVerificationView extends ConsumerStatefulWidget {
  final Function(Map<String, dynamic> data) onVerified;
  final bool isProcessing;

  const FingerprintVerificationView({
    super.key,
    required this.onVerified,
    required this.isProcessing,
  });

  @override
  ConsumerState<FingerprintVerificationView> createState() => _FingerprintVerificationViewState();
}

class _FingerprintVerificationViewState extends ConsumerState<FingerprintVerificationView>
    with SingleTickerProviderStateMixin {
  final _localAuth = LocalAuthentication();
  final _deviceInfo = DeviceInfoService();

  _FingerprintStatus _status = _FingerprintStatus.idle;
  String? _errorMessage;
  bool _biometricAvailable = false;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _checkAndAuthenticate();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _checkAndAuthenticate() async {
    final canCheck = await _localAuth.canCheckBiometrics;
    final isSupported = await _localAuth.isDeviceSupported();

    if (!canCheck || !isSupported) {
      if (mounted) {
        setState(() {
          _status = _FingerprintStatus.failed;
          _errorMessage = 'Biometric authentication is not supported on this device.';
        });
      }
      return;
    }

    if (mounted) setState(() => _biometricAvailable = true);
    await _authenticate();
  }

  Future<void> _authenticate() async {
    setState(() {
      _status = _FingerprintStatus.authenticating;
      _errorMessage = null;
    });

    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Verify your identity to record attendance',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );

      if (!mounted) return;

      if (authenticated) {
        setState(() => _status = _FingerprintStatus.success);
        final deviceId = await _deviceInfo.getDeviceId();
        widget.onVerified({'deviceId': deviceId});
      } else {
        setState(() {
          _status = _FingerprintStatus.failed;
          _errorMessage = 'Authentication was not successful.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _status = _FingerprintStatus.failed;
          _errorMessage = 'Error: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Animated fingerprint icon
          ScaleTransition(
            scale: _status == _FingerprintStatus.authenticating
                ? _pulseAnim
                : const AlwaysStoppedAnimation(1.0),
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _iconColor.withAlpha(25),
              ),
              child: widget.isProcessing
                  ? const Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(strokeWidth: 3),
                    )
                  : Icon(
                      Icons.fingerprint,
                      size: 64,
                      color: _iconColor,
                    ),
            ),
          ),
          const SizedBox(height: 32),

          Text(
            _statusTitle,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),

          Text(
            _errorMessage ?? _statusSubtitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: _status == _FingerprintStatus.failed ? theme.colorScheme.error : AppColors.textSecondary,
            ),
          ),

          if (_status == _FingerprintStatus.failed && _biometricAvailable) ...[
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _authenticate,
              icon: const Icon(Icons.fingerprint),
              label: const Text('Try Again'),
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color get _iconColor => switch (_status) {
        _FingerprintStatus.failed => AppColors.error,
        _FingerprintStatus.success => AppColors.success,
        _ => AppColors.primary,
      };

  String get _statusTitle => switch (_status) {
        _FingerprintStatus.idle => 'Ready',
        _FingerprintStatus.authenticating => 'Touch the sensor',
        _FingerprintStatus.success => 'Verified',
        _FingerprintStatus.failed => 'Authentication Failed',
      };

  String get _statusSubtitle => switch (_status) {
        _FingerprintStatus.idle => 'Preparing biometric authentication',
        _FingerprintStatus.authenticating => 'Place your finger on the sensor or use Face ID',
        _FingerprintStatus.success => 'Identity confirmed — recording punch',
        _FingerprintStatus.failed => '',
      };
}
