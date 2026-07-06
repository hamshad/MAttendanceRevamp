import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_provider.dart';
import 'login_screen.dart';

class BiometricScreen extends ConsumerStatefulWidget {
  const BiometricScreen({super.key});

  @override
  ConsumerState<BiometricScreen> createState() => _BiometricScreenState();
}

class _BiometricScreenState extends ConsumerState<BiometricScreen> {
  bool _isAuthenticating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Auto-trigger on open
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  Future<void> _authenticate() async {
    setState(() {
      _isAuthenticating = true;
      _error = null;
    });

    final biometricService = ref.read(biometricServiceProvider);
    final success = await biometricService.authenticate(
      reason: 'Verify your identity to access MAttendance',
    );

    if (!mounted) return;
    setState(() => _isAuthenticating = false);

    if (success) {
      // Re-run build() which loads user from secure storage
      ref.invalidate(authNotifierProvider);
      // Navigation is handled by app.dart listening to authNotifierProvider
    } else {
      setState(() => _error = 'Biometric authentication failed');
    }
  }

  void _goToLogin() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),

              // Icon
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withAlpha(20),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.fingerprint,
                  size: 60,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),

              Text(
                'Welcome back',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Use your fingerprint or Face ID\nto continue',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
              ),
              const SizedBox(height: 40),

              // Authenticate button
              if (_isAuthenticating)
                const CircularProgressIndicator()
              else ...[
                if (_error != null) ...[
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                ],
                ElevatedButton.icon(
                  onPressed: _authenticate,
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('Authenticate'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(200, 48),
                  ),
                ),
              ],

              const Spacer(),

              // Use password instead
              TextButton(
                onPressed: _goToLogin,
                child: const Text('Use password instead'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
