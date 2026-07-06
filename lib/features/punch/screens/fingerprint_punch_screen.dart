import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import '../services/device_info_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../core/theme/app_colors.dart';

enum _FingerprintState { idle, authenticating, submitting, failed }

class FingerprintPunchScreen extends ConsumerStatefulWidget {
  final String direction;

  const FingerprintPunchScreen({super.key, required this.direction});

  @override
  ConsumerState<FingerprintPunchScreen> createState() =>
      _FingerprintPunchScreenState();
}

class _FingerprintPunchScreenState extends ConsumerState<FingerprintPunchScreen>
    with SingleTickerProviderStateMixin {
  final _localAuth = LocalAuthentication();
  final _deviceInfo = DeviceInfoService();

  _FingerprintState _state = _FingerprintState.idle;
  String? _failureReason;
  bool _biometricAvailable = false;

  // Pulse animation for the fingerprint icon
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
          _state = _FingerprintState.failed;
          _failureReason =
              'This device does not support biometric authentication.';
        });
      }
      return;
    }

    if (mounted) setState(() => _biometricAvailable = true);
    await _authenticate();
  }

  Future<void> _authenticate() async {
    setState(() {
      _state = _FingerprintState.authenticating;
      _failureReason = null;
    });

    bool authenticated = false;
    try {
      authenticated = await _localAuth.authenticate(
        localizedReason: 'Verify your identity to punch ${_dirLabel(widget.direction)}',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _FingerprintState.failed;
          _failureReason = 'Authentication error: ${e.toString()}';
        });
      }
      return;
    }

    if (!mounted) return;

    if (!authenticated) {
      setState(() {
        _state = _FingerprintState.failed;
        _failureReason = 'Authentication was not successful. Please try again.';
      });
      return;
    }

    // Biometric passed — submit punch
    await _submitPunch();
  }

  Future<void> _submitPunch() async {
    setState(() => _state = _FingerprintState.submitting);

    final deviceId = await _deviceInfo.getDeviceId();

    final result = await ref.read(punchProvider.notifier).punch(
      'Fingerprint',
      extras: {
        'deviceId': deviceId,
        'direction': widget.direction,
      },
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message ?? (result.success ? 'Punch recorded!' : 'Punch failed')),
        backgroundColor: result.success ? AppColors.success : AppColors.error,
      ),
    );

    if (result.success) {
      Navigator.pop(context);
    } else {
      setState(() {
        _state = _FingerprintState.failed;
        _failureReason = result.message ?? 'Punch failed. Device may not be registered.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('Fingerprint ${_dirLabel(widget.direction)}'),
        leading: const CloseButton(),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),

              // Animated fingerprint icon
              ScaleTransition(
                scale: _state == _FingerprintState.authenticating
                    ? _pulseAnim
                    : const AlwaysStoppedAnimation(1.0),
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _iconBgColor(theme).withAlpha(25),
                  ),
                  child: _state == _FingerprintState.submitting
                      ? Padding(
                          padding: const EdgeInsets.all(32),
                          child: CircularProgressIndicator(
                            color: theme.colorScheme.primary,
                            strokeWidth: 3,
                          ),
                        )
                      : Icon(
                          _stateIcon,
                          size: 64,
                          color: _iconBgColor(theme),
                        ),
                ),
              ),
              const SizedBox(height: 28),

              // Title
              Text(
                _stateTitle,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),

              // Subtitle / error
              Text(
                _failureReason ?? _stateSubtitle,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _state == _FingerprintState.failed
                      ? theme.colorScheme.error
                      : AppColors.textSecondary,
                ),
              ),

              const Spacer(),

              // Retry or dismiss buttons
              if (_state == _FingerprintState.failed) ...[
                if (_biometricAvailable)
                  ElevatedButton.icon(
                    onPressed: _authenticate,
                    icon: const Icon(Icons.fingerprint),
                    label: const Text('Try Again'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ],

              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        'BreakStart' => 'Break Start',
        'BreakEnd' => 'Break End',
        _ => dir,
      };

  IconData get _stateIcon => switch (_state) {
        _FingerprintState.idle => Icons.fingerprint,
        _FingerprintState.authenticating => Icons.fingerprint,
        _FingerprintState.submitting => Icons.fingerprint,
        _FingerprintState.failed => Icons.fingerprint,
      };

  String get _stateTitle => switch (_state) {
        _FingerprintState.idle => 'Ready',
        _FingerprintState.authenticating => 'Touch the sensor',
        _FingerprintState.submitting => 'Recording punch...',
        _FingerprintState.failed => 'Authentication Failed',
      };

  String get _stateSubtitle => switch (_state) {
        _FingerprintState.idle => 'Preparing biometric authentication',
        _FingerprintState.authenticating =>
          'Place your finger on the fingerprint sensor\nor use Face ID',
        _FingerprintState.submitting =>
          'Biometric verified — submitting punch',
        _FingerprintState.failed => '',
      };

  Color _iconBgColor(ThemeData theme) => switch (_state) {
        _FingerprintState.failed => theme.colorScheme.error,
        _FingerprintState.submitting => AppColors.success,
        _ => theme.colorScheme.primary,
      };
}
