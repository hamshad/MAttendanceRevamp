import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/attendance.dart';
import '../providers/dashboard_providers.dart';
import '../../punch/screens/gps_punch_screen.dart';
import '../../punch/screens/wifi_punch_screen.dart';
import '../../punch/screens/selfie_punch_screen.dart';
import '../../punch/screens/fingerprint_punch_screen.dart';
import '../../punch/screens/ble_scan_screen.dart';
import '../../punch/screens/nfc_tap_screen.dart';
import '../../punch/screens/client_site_screen.dart';
import '../../punch/screens/break_screen.dart';

class PunchButton extends ConsumerStatefulWidget {
  final EmployeeStatus? status;
  final bool isFlowMode;
  final VoidCallback? onPunchPressed;
  final bool isLoading;

  const PunchButton({
    super.key,
    required this.status,
    this.isFlowMode = false,
    this.onPunchPressed,
    this.isLoading = false,
  });

  @override
  ConsumerState<PunchButton> createState() => _PunchButtonState();
}

class _PunchButtonState extends ConsumerState<PunchButton>
    with TickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _scaleAnim;
  late AnimationController _shakeController;
  late Animation<double> _shakeAnim;
  bool _isPunching = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _scaleAnim = Tween<double>(begin: 1.0, end: 0.93).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10.0, end: -10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 0.0), weight: 1),
    ]).animate(_shakeController);
  }

  @override
  void dispose() {
    _animController.dispose();
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _onTap() async {
    if (_isPunching) return;

    await _animController.forward();
    await _animController.reverse();

    // When on break the button always opens the break management screen
    if (widget.status?.isOnBreak == true) {
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BreakScreen()),
      );
      return;
    }

    if (widget.isFlowMode && widget.onPunchPressed != null) {
      widget.onPunchPressed!();
      return;
    }

    final method = ref.read(selectedMethodProvider);
    final direction = _resolveDirection();

    await _navigateToMethodScreen(method, direction);
  }

  /// Determine direction from current attendance state
  String _resolveDirection() {
    final status = widget.status;
    if (status?.isOnBreak ?? false) return 'BreakEnd';
    if (status?.isPunchedIn ?? false) return 'Out';
    return 'In';
  }

  /// Route to method-specific screen or punch directly for simple methods
  Future<void> _navigateToMethodScreen(String method, String direction) async {
    switch (method) {
      case 'GPS':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GPSPunchScreen(direction: direction),
          ),
        );
        break;
      case 'GeofenceAuto':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GPSPunchScreen(
              direction: direction,
              method: 'GeofenceAuto',
            ),
          ),
        );
        break;
      case 'WiFi':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => WiFiPunchScreen(direction: direction),
          ),
        );
        break;
      case 'Selfie':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SelfiePunchScreen(direction: direction),
          ),
        );
        break;
      case 'Fingerprint':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => FingerprintPunchScreen(direction: direction),
          ),
        );
        break;
      case 'Bluetooth':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => BleScanScreen(direction: direction),
          ),
        );
        break;
      case 'NFC':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NfcTapScreen(direction: direction),
          ),
        );
        break;
      case 'ClientSite':
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ClientSiteScreen(direction: direction),
          ),
        );
        break;
      default:
        // For methods not yet implemented, punch directly
        setState(() => _isPunching = true);
        final result = await ref.read(punchProvider.notifier).punch(method);
        if (!mounted) return;
        setState(() => _isPunching = false);
        if (!result.success) {
          HapticFeedback.vibrate();
          _shakeController.forward(from: 0);
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message ?? (result.success ? 'Punch recorded' : 'Punch failed')),
            backgroundColor: result.success ? AppColors.success : AppColors.error,
            duration: const Duration(seconds: 2),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final isOnBreak = status?.isOnBreak ?? false;
    final isPunchedIn = status?.isPunchedIn ?? false;

    final Color buttonColor;
    final String label;
    final IconData icon;

    if (isOnBreak) {
      buttonColor = AppColors.warning;
      label = 'END\nBREAK';
      icon = Icons.coffee_outlined;
    } else if (isPunchedIn) {
      buttonColor = AppColors.error;
      label = 'PUNCH\nOUT';
      icon = Icons.logout;
    } else {
      buttonColor = AppColors.success;
      label = 'PUNCH\nIN';
      icon = Icons.fingerprint;
    }

    return AnimatedBuilder(
      animation: _shakeAnim,
      builder: (_, child) => Transform.translate(
        offset: Offset(_shakeAnim.value, 0),
        child: child,
      ),
      child: ScaleTransition(
      scale: _scaleAnim,
      child: GestureDetector(
        onTap: _onTap,
        child: Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: buttonColor,
            boxShadow: [
              BoxShadow(
                color: buttonColor.withAlpha(100),
                blurRadius: 24,
                spreadRadius: 4,
              ),
            ],
          ),
          child: (widget.isLoading || _isPunching)
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 40, color: Colors.white),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
        ),
      ),
      ),
    );
  }
}

// ── Method selector chips ──────────────────────────────────────────────────────

class MethodSelector extends ConsumerWidget {
  final AccessPermissions? permissions;

  const MethodSelector({super.key, required this.permissions});

  static const _methodMeta = {
    'GPS': (label: 'GPS', icon: Icons.gps_fixed),
    'WiFi': (label: 'WiFi', icon: Icons.wifi),
    'Selfie': (label: 'Selfie', icon: Icons.photo_camera),
    'Fingerprint': (label: 'Print', icon: Icons.fingerprint),
    'Bluetooth': (label: 'BLE', icon: Icons.bluetooth),
    'NFC': (label: 'NFC', icon: Icons.nfc),
    'GeofenceAuto': (label: 'Geo', icon: Icons.radar),
    'Voice': (label: 'Voice', icon: Icons.mic),
    'ClientSite': (label: 'Site', icon: Icons.business),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed = permissions?.allowedMethods ?? [];
    final selected = ref.watch(selectedMethodProvider);
    final theme = Theme.of(context);

    if (allowed.isEmpty) return const SizedBox.shrink();

    // If the selected method is not in the allowed list (e.g. default 'GPS' but employee
    // only has Selfie), switch to the first allowed method after the current frame.
    if (!allowed.contains(selected)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(selectedMethodProvider.notifier).state = allowed.first;
      });
    }

    // Show first 4, rest in "More" — simple horizontal scroll
    return Column(
      children: [
        SizedBox(
          height: 36,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            itemCount: allowed.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final method = allowed[i];
              final meta = _methodMeta[method];
              if (meta == null) return const SizedBox.shrink();

              final isSelected = selected == method;
              return ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(meta.icon, size: 14,
                        color: isSelected ? Colors.white : theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text(meta.label,
                        style: TextStyle(
                            color: isSelected ? Colors.white : theme.colorScheme.primary,
                            fontSize: 12)),
                  ],
                ),
                selected: isSelected,
                onSelected: (_) => ref.read(selectedMethodProvider.notifier).state = method,
                selectedColor: theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.primary.withAlpha(15),
                side: BorderSide(color: theme.colorScheme.primary.withAlpha(60)),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            },
          ),
        ),
      ],
    );
  }
}
