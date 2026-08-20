import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../../models/auth_response.dart';
import '../../models/user.dart';
import '../api/api_endpoints.dart';
import '../api/api_exceptions.dart';
import '../api/dio_client.dart';
import '../utils/constants.dart';
import 'auth_api.dart';
import 'token_storage.dart';
import 'biometric_service.dart';
import '../utils/app_logger.dart';
import '../services/office_data_service.dart';
import '../../features/punch/services/geofence_monitor.dart';
import '../../features/punch/services/geofence_scheduler.dart';
import '../offline/offline_sync_manager.dart';

// ── Providers ─────────────────────────────────────────────────────────────────

final tokenStorageProvider = Provider<TokenStorage>((ref) => TokenStorage());

final dioClientProvider = Provider<DioClient>((ref) {
  final client = DioClient(ref.read(tokenStorageProvider));
  // Wire session expiry: when the interceptor can't refresh, force-logout so
  // the router immediately navigates back to LoginScreen.
  client.onSessionExpired = () {
    ref.read(authNotifierProvider.notifier).forceLogout();
  };
  return client;
});

final authApiProvider = Provider<AuthApi>((ref) {
  return AuthApi(ref.read(dioClientProvider).dio);
});

final biometricServiceProvider = Provider<BiometricService>((ref) => BiometricService());

final officeDataServiceProvider = Provider<OfficeDataService>((ref) {
  return OfficeDataService(ref.read(dioClientProvider).dio);
});

final authNotifierProvider = AsyncNotifierProvider<AuthNotifier, AppUser?>(() => AuthNotifier());

// ── Auth state ────────────────────────────────────────────────────────────────

enum AuthStatus { loading, authenticated, unauthenticated, biometricRequired }

class AuthNotifier extends AsyncNotifier<AppUser?> {
  late TokenStorage _tokenStorage;
  late AuthApi _authApi;

  @override
  Future<AppUser?> build() async {
    _tokenStorage = ref.read(tokenStorageProvider);
    _authApi = ref.read(authApiProvider);

    final _bench = Stopwatch()..start();
    final user = await _tryAutoLogin();
    debugPrint('[BENCH] _tryAutoLogin total: ${_bench.elapsedMilliseconds}ms');
    if (user != null) {
      // Fetch and save offices on app open if user is already logged in
      _fetchAndSaveOffices();
    }
    return user;
  }

  Future<AppUser?> _tryAutoLogin() async {
    try {
      final _bench = Stopwatch()..start();
      final hasTokens = await _tokenStorage.hasTokens();
      debugPrint('[BENCH] hasTokens: ${_bench.elapsedMilliseconds}ms');
      if (!hasTokens) {
        AppLogger.d('AUTH: No tokens found for auto-login');
        // Clear any stale cached user so a later auto-login does not start
        // from a phantom logged-in state.
        await AppUser.clear();
        return null;
      }

      AppLogger.i('AUTH: Tokens found, attempting to load user data');

      // Fast path: return cached user immediately without server call.
      // Token validation happens lazily when other API calls are made;
      // the 401 interceptor handles refresh if needed.
      final _bench2 = Stopwatch()..start();
      final cachedUser = await AppUser.load();
      debugPrint('[BENCH] AppUser.load: ${_bench2.elapsedMilliseconds}ms');
      if (cachedUser != null) {
        AppLogger.i('AUTH: Auto-login successful (cached user)');
        return cachedUser;
      }

      // Tokens exist but user data is missing — try fetching from server
      // with retry for transient failures.
      AppLogger.w('AUTH: Tokens exist but AppUser data missing. Fetching profile.');
      for (int i = 0; i <= 2; i++) {
        try {
          final dio = ref.read(dioClientProvider).dio;
          final response = await dio.get(ApiEndpoints.me);
          final profile = response.data;
          if (profile != null) {
            final newUser = AppUser(
              empId: profile['empId'],
              fullName: profile['fullName'],
              email: profile['email'],
              role: profile['role'],
              orgId: profile['orgId'],
              orgName: profile['orgName'],
              profilePhoto: profile['profilePhoto'],
            );
            await newUser.save();
            AppLogger.i('AUTH: Profile fetched successfully');
            return newUser;
          }
        } catch (e) {
          // Only clear the session on DEFINITIVE token rejection — a genuine
          // 401 that survived the interceptor's refresh attempt. The
          // interceptor tags transient refresh failures (429 rate limit,
          // 5xx, network) with SessionRefreshFailedException; those must NOT
          // flush tokens, even though the request's raw statusCode is 401.
          final apiErr = e is DioException ? e.error : null;
          if (apiErr is ApiException && apiErr.statusCode == 401) {
            AppLogger.w('AUTH: Token rejected (401) — clearing stale session');
            await _tokenStorage.clearTokens();
            await AppUser.clear();
            return null;
          }
          final retryable = e is DioException && _isRetryableDioError(e);
          if (i < 2 && retryable) {
            AppLogger.w('AUTH: Profile fetch attempt $i failed (retryable) — retrying in 2s');
            await Future.delayed(const Duration(seconds: 2));
            continue;
          }
          AppLogger.e('AUTH: Failed to fetch profile during auto-login', e);
          break;
        }
      }

      // Fallback: tokens exist but server unreachable.
      // Return a minimal user — DO NOT force login screen.
      // Profile data loads lazily when network recovers.
      AppLogger.w('AUTH: Returning skeleton user (server unreachable, valid tokens cached)');
      final email = await _tokenStorage.getRefreshToken() ?? '';
      return AppUser(
        empId: 0,
        fullName: '',
        email: email,
        role: '',
        orgId: 0,
        orgName: '',
      );
    } catch (e) {
      AppLogger.e('AUTH: Auto-login error', e);
      return null;
    }
  }

  bool _isRetryableDioError(DioException e) {
    return e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout ||
        e.type == DioExceptionType.connectionError ||
        e.response == null ||
        (e.response?.statusCode ?? 0) >= 500;
  }

  Future<void> login(String email, String password) async {
    AppLogger.i('AUTH: Login attempt - $email');
    state = await AsyncValue.guard(() async {
      final response = await _authApi.login(email, password);
      AppLogger.i('AUTH: Login successful for $email');
      return _saveSession(response);
    });
    if (state.hasError) {
      AppLogger.e('AUTH: Login failed for $email', state.error);
    }
  }

  Future<void> loginWithGoogle() async {
    AppLogger.i('AUTH: Google login attempt');
    state = await AsyncValue.guard(() async {
      final googleSignIn = GoogleSignIn(
        serverClientId: AppConstants.googleClientId,
        scopes: ['email', 'profile'],
      );
      final googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        AppLogger.w('AUTH: Google login cancelled by user');
        throw Exception('Google sign-in was cancelled');
      }

      final googleAuth = await googleUser.authentication;
      if (googleAuth.idToken == null) throw Exception('Failed to get Google ID token');

      AppLogger.d('AUTH: Exchanging Google ID Token for session');
      final response = await _authApi.loginWithGoogle(googleAuth.idToken!);
      AppLogger.i('AUTH: Google login successful');
      return _saveSession(response);
    });
  }

  Future<AppUser> _saveSession(AuthResponse response) async {
    await _tokenStorage.saveTokens(response.accessToken, response.refreshToken);

    // Fetch and save offices on login
    _fetchAndSaveOffices();

    final user = AppUser(
      empId: response.empId,
      fullName: response.fullName,
      email: response.email,
      role: response.role,
      orgId: response.orgId,
      orgName: response.orgName,
      profilePhoto: response.profilePhoto,
    );
    await user.save();
    return user;
  }

  Future<void> uploadProfilePhoto(ImageSource source) async {
    AppLogger.i('AUTH: Starting profile photo update');
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 90, maxWidth: 1024);
    if (picked == null) {
      AppLogger.d('AUTH: No image picked');
      return;
    }

    AppLogger.v('AUTH: Opening image cropper');
    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Photo',
          toolbarColor: const Color(0xFF4F46E5),
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: const Color(0xFF4F46E5),
          cropStyle: CropStyle.circle,
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
        IOSUiSettings(
          title: 'Crop Photo',
          cropStyle: CropStyle.circle,
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
      ],
    );
    if (cropped == null) {
      AppLogger.d('AUTH: Cropping cancelled');
      return;
    }

    AppLogger.i('AUTH: Uploading cropped image: ${cropped.path}');
    final dio = ref.read(dioClientProvider).dio;
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(cropped.path, filename: 'photo.jpg'),
    });

    try {
      final response = await dio.put<Map<String, dynamic>>(
        ApiEndpoints.uploadMyPhoto,
        data: formData,
      );

      final photoPath = response.data?['profilePhoto'] as String?;
      if (photoPath == null) throw Exception('No photo path in response');

      final current = state.value;
      if (current == null) return;

      final updated = current.copyWith(profilePhoto: photoPath);
      await updated.save();
      state = AsyncData(updated);
      AppLogger.i('AUTH: Profile photo updated successfully');
    } catch (e) {
      AppLogger.e('AUTH: Photo upload failed', e);
      rethrow;
    }
  }

  Future<void> logout() async {
    AppLogger.i('AUTH: Logging out');
    final refreshToken = await _tokenStorage.getRefreshToken();
    if (refreshToken != null) {
      try {
        await _authApi.logout(refreshToken);
      } catch (e) {
        AppLogger.w('AUTH: Server-side logout failed (ignoring)', e);
      }
    }
    await GeofenceScheduler.cancel();
    await GeofenceScheduler.stopGeofenceService();
    // Unregister OS geofences so no events fire while logged out.
    await GeofenceMonitor.unregisterAll();
    // No queued punches to sync after logout — stop the background manager.
    await OfflineSyncManager.cancel();
    await _tokenStorage.clearTokens();
    await _tokenStorage.clearBackup();
    await AppUser.clear();
    ref.read(officeDataServiceProvider).reset();
    state = const AsyncData(null);
    AppLogger.i('AUTH: Logout complete');
  }

  Future<void> forceLogout() async {
    AppLogger.w('AUTH: forceLogout() called — clearing session and navigating to LoginScreen');
    await _tokenStorage.clearTokens();
    // Definitive logout: also destroy the Hive backup so a future
    // hasTokens() cannot restore the rejected/expired session.
    await _tokenStorage.clearBackup();
    await OfflineSyncManager.cancel();
    await AppUser.clear();
    ref.read(officeDataServiceProvider).reset();
    state = const AsyncData(null);
  }

  /// Internal helper to fetch office data and store it in SharedPreferences.
  Future<void> _fetchAndSaveOffices() async {
    try {
      await ref.read(officeDataServiceProvider).fetchAndSaveOffices();
      // Preload active client sites so the auto-geofence engine and the
      // Geofence Places screen can use them without a fresh round-trip.
      await ref.read(officeDataServiceProvider).fetchAndSaveClientSites();
    } catch (e) {
      AppLogger.e('AUTH: Failed to trigger office data fetch', e);
    }
  }
}

// ── Biometric enabled preference ─────────────────────────────────────────────

final biometricEnabledProvider = FutureProvider<bool>((ref) async {
  final storage = ref.read(tokenStorageProvider);
  // Re-use secure storage for this flag
  return (await storage.getAccessToken()) != null; // placeholder — real pref stored separately
});
