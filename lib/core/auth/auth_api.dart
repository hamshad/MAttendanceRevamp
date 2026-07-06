import 'package:dio/dio.dart';
import '../../models/auth_response.dart';
import '../api/api_endpoints.dart';
import '../api/api_exceptions.dart';

class AuthApi {
  final Dio _dio;

  AuthApi(this._dio);

  Future<AuthResponse> login(String email, String password) async {
    try {
      final response = await _dio.post(ApiEndpoints.login, data: {
        'email': email,
        'password': password,
      });
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      final err = e.error;
      if (err is ApiException) throw Exception(err.message);
      throw Exception(e.message ?? 'Login failed');
    }
  }

  Future<AuthResponse> loginWithGoogle(String idToken) async {
    try {
      final response = await _dio.post(ApiEndpoints.googleAuth, data: {
        'idToken': idToken,
      });
      return AuthResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      final err = e.error;
      if (err is ApiException) throw Exception(err.message);
      throw Exception(e.message ?? 'Google login failed');
    }
  }

  Future<void> forgotPassword(String email) async {
    await _dio.post(ApiEndpoints.forgotPassword, data: {'email': email});
  }

  Future<void> logout(String refreshToken) async {
    await _dio.post(ApiEndpoints.logout, data: {'refreshToken': refreshToken});
  }
}
