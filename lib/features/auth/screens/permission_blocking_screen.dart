import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
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
  bool _isRequesting = false;
  bool? _needsBackground;
  bool _checkTriggered = false;

  Future<void> _checkPermission() async {
    final needsBg = _needsBackground!;
    setState(() => _isRequesting = true);

    final hasPerm = needsBg
        ? await PermissionService.instance.hasBackgroundLocation()
        : await PermissionService.instance.hasForegroundLocation();

    if (mounted) {
      setState(() {
        _hasPermission = hasPerm;
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

    if (mounted) {
      setState(() {
        _hasPermission = success;
        _isRequesting = false;
      });
    }
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

    if (_hasPermission) {
      return widget.child;
    }

    final theme = Theme.of(context);
    final isBg = needsBackground;

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
                'Location Required',
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
                      const Icon(
                        Icons.location_on,
                        size: 48,
                        color: AppColors.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        isBg
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
                    text: 'Tap the button below',
                  ),
                  const SizedBox(height: 16),
                  _InstructionRow(
                    number: '2',
                    text: isBg ? 'Select "Allow all the time"' : 'Select "Allow while using the app"',
                  ),
                ],
              ),
              const SizedBox(height: 48),

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
