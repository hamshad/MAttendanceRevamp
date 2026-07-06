import 'package:local_auth/local_auth.dart';

class BiometricService {
  final _auth = LocalAuthentication();

  Future<bool> isAvailable() async {
    final canCheck = await _auth.canCheckBiometrics;
    final isSupported = await _auth.isDeviceSupported();
    return canCheck && isSupported;
  }

  Future<List<BiometricType>> getAvailableTypes() async {
    return _auth.getAvailableBiometrics();
  }

  Future<bool> authenticate({String reason = 'Authenticate to access MAttendance'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // Allow PIN fallback
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
